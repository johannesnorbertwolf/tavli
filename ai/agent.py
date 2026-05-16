import torch
import random
import numpy as np
from typing import List, Optional, Tuple
from domain.board import GameBoard
from domain.color import Color
from domain.move import Move
from domain.dice import Dice
from domain.possible_moves import PossibleMoves
from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder


_DIE_SIDES = 6


def _build_dice_outcomes() -> List[Tuple[int, int, float]]:
    outcomes = []
    n = _DIE_SIDES
    for i in range(1, n + 1):
        for j in range(i, n + 1):
            weight = (1.0 / (n * n)) if i == j else (2.0 / (n * n))
            outcomes.append((i, j, weight))
    return outcomes


_DICE_OUTCOMES = _build_dice_outcomes()


class Agent:
    def __init__(self, board_evaluator: BoardEvaluator, board_encoder: BoardEncoder):
        self.board_evaluator = board_evaluator
        self.board_encoder = board_encoder

    def _model_device(self):
        return next(self.board_evaluator.parameters()).device

    def _evaluate_moves_batch(self, board: GameBoard, possible_moves: List[Move], color: Color) -> List[float]:
        device = self._model_device()
        is_whites_turn_next = not color.is_white()
        scores: List[float] = [0.0] * len(possible_moves)
        encoded_afterstates = []
        encode_indices: List[int] = []

        for idx, move in enumerate(possible_moves):
            board.apply(move)
            if board.has_won(color):
                # Game is over after this move — deterministic win regardless of opponent.
                scores[idx] = 1.0
            else:
                encoded_afterstates.append(self.board_encoder.encode_board(board, is_whites_turn=is_whites_turn_next))
                encode_indices.append(idx)
            board.undo(move)

        if encoded_afterstates:
            board_batch = torch.from_numpy(np.stack(encoded_afterstates)).float().to(device)
            with torch.no_grad():
                opponent_values = self.board_evaluator(board_batch).squeeze(1).detach().cpu().numpy()
            for j, idx in enumerate(encode_indices):
                scores[idx] = 1.0 - float(opponent_values[j])
        return scores

    def _evaluate_moves_2ply_batch(self, board: GameBoard, possible_moves: List[Move], color: Color) -> List[float]:
        """Expectimax over the 21 distinct dice outcomes. For each candidate move, opponent picks
        the response that maximizes their own value; we average across dice weighted by probability."""
        device = self._model_device()
        opponent_color = Color.BLACK if color.is_white() else Color.WHITE
        is_our_turn = color.is_white()
        is_opp_turn = not is_our_turn

        dice = Dice(_DIE_SIDES)

        all_encoded: List[np.ndarray] = []
        # plans[i] is None when candidate i is a deterministic win (score = 1.0); otherwise
        # it is the list of (start, end, weight, kind) tuples for the dice-outcome rollout.
        plans: List[Optional[List[Tuple[int, int, float, str]]]] = []

        for m_c in possible_moves:
            board.apply(m_c)
            if board.has_won(color):
                # Candidate move ends the game with a win; opponent never gets to respond.
                plans.append(None)
                board.undo(m_c)
                continue
            cand_plan: List[Tuple[int, int, float, str]] = []
            for (i, j, weight) in _DICE_OUTCOMES:
                dice.die1.value = i
                dice.die2.value = j
                opp_moves = PossibleMoves(board, opponent_color, dice).find_moves()
                start = len(all_encoded)
                if not opp_moves:
                    # Opponent must pass; our turn next on the same board.
                    all_encoded.append(self.board_encoder.encode_board(board, is_whites_turn=is_our_turn))
                    end = len(all_encoded)
                    cand_plan.append((start, end, weight, "pass"))
                else:
                    for m_o in opp_moves:
                        board.apply(m_o)
                        all_encoded.append(self.board_encoder.encode_board(board, is_whites_turn=is_opp_turn))
                        board.undo(m_o)
                    end = len(all_encoded)
                    cand_plan.append((start, end, weight, "opp_max"))
            plans.append(cand_plan)
            board.undo(m_c)

        if all_encoded:
            board_batch = torch.from_numpy(np.stack(all_encoded)).float().to(device)
            with torch.no_grad():
                values = self.board_evaluator(board_batch).squeeze(1).detach().cpu().numpy()
        else:
            values = np.zeros(0, dtype=np.float32)

        scores: List[float] = []
        for cand_plan in plans:
            if cand_plan is None:
                scores.append(1.0)
                continue
            expected = 0.0
            for (start, end, weight, kind) in cand_plan:
                if kind == "pass":
                    val_d = float(values[start])
                else:
                    val_d = 1.0 - float(values[start:end].max())
                expected += weight * val_d
            scores.append(expected)
        return scores

    def get_best_move(self, board: GameBoard, possible_moves: List[Move], color: Color, lookahead_plies: int = 1) -> Tuple[Move, float]:
        if not possible_moves:
            return None, 0.0

        if lookahead_plies >= 2:
            move_scores = self._evaluate_moves_2ply_batch(board, possible_moves, color)
        else:
            move_scores = self._evaluate_moves_batch(board, possible_moves, color)
        best_idx = int(max(range(len(move_scores)), key=lambda i: move_scores[i]))
        return possible_moves[best_idx], move_scores[best_idx]

    def evaluate_moves(self, board: GameBoard, possible_moves: List[Move], color: Color, lookahead_plies: int = 1) -> List[float]:
        if not possible_moves:
            return []
        if lookahead_plies >= 2:
            return self._evaluate_moves_2ply_batch(board, possible_moves, color)
        return self._evaluate_moves_batch(board, possible_moves, color)

class RandomAgent:
    """An agent that chooses a move randomly from the possible moves."""
    def get_move(self, possible_moves: List[Move]) -> Move:
        return random.choice(possible_moves)
