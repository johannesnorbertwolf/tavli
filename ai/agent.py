import time
import torch
import random
import numpy as np
from typing import List, Optional, Tuple
from domain.board import Board
from domain.move import Move
from domain.dice import Dice
from domain.move_generation import legal_moves
from domain.constants import WHITE, BLACK
from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder
from ai.bearoff import exact_value_on_roll


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


class _TimeoutError(Exception):
    pass


class Agent:
    def __init__(self, board_evaluator: BoardEvaluator, board_encoder: BoardEncoder,
                 bearoff=None):
        self.board_evaluator = board_evaluator
        self.board_encoder = board_encoder
        # Optional ai.bearoff.BearoffDB: exact-race positions bypass the net and
        # get exact equity at every leaf-evaluation site.
        self.bearoff = bearoff
        # Depth actually reached by the most recent get_best_move call (search instrumentation).
        self.last_search_depth = 1

    def _exact_value(self, board: Board, persp_is_white: bool) -> Optional[float]:
        """Exact win prob of the perspective player on roll, or None outside
        exact races. Mirrors the net's output semantics exactly."""
        return exact_value_on_roll(board, persp_is_white, self.bearoff)

    def _model_device(self):
        return next(self.board_evaluator.parameters()).device

    @staticmethod
    def _prune_branches(
        moves: List[Move],
        scores: List[float],
        beam_threshold: float,
        relative_cutoff: Optional[float],
        max_branch: Optional[int],
    ) -> List[int]:
        """Return the indices of moves to expand, best-first.

        When ``relative_cutoff`` is set, keep moves whose score is within a *relative*
        fraction of the best (``score >= best * (1 - relative_cutoff)``); otherwise fall
        back to the absolute ``beam_threshold`` (``score >= best - beam_threshold``).
        The survivors are then sorted by score (desc) and capped to ``max_branch``.
        Always keeps at least one move.
        """
        if not scores:
            return []
        best = max(scores)
        if relative_cutoff is not None:
            keep = best * (1.0 - relative_cutoff)
        else:
            keep = best - beam_threshold
        order = sorted(range(len(scores)), key=lambda i: scores[i], reverse=True)
        survivors = [i for i in order if scores[i] >= keep]
        if not survivors:
            survivors = [order[0]]
        if max_branch is not None and len(survivors) > max_branch:
            survivors = survivors[:max_branch]
        return survivors

    def _evaluate_moves_batch(self, board: Board, possible_moves: List[Move], color: int) -> List[float]:
        device = self._model_device()
        is_whites_turn_next = color != WHITE
        scores: List[float] = [0.0] * len(possible_moves)
        encoded_afterstates = []
        encode_indices: List[int] = []

        for idx, move in enumerate(possible_moves):
            token = board.apply(move, color)
            if board.has_won(color):
                scores[idx] = 1.0
            else:
                exact = self._exact_value(board, is_whites_turn_next)
                if exact is not None:
                    scores[idx] = 1.0 - exact
                else:
                    encoded_afterstates.append(self.board_encoder.encode_board(board, is_whites_turn=is_whites_turn_next))
                    encode_indices.append(idx)
            board.undo(token)

        if encoded_afterstates:
            board_batch = torch.from_numpy(np.stack(encoded_afterstates)).float().to(device)
            with torch.no_grad():
                opponent_values = self.board_evaluator(board_batch).squeeze(1).detach().cpu().numpy()
            for j, idx in enumerate(encode_indices):
                scores[idx] = 1.0 - float(opponent_values[j])
        return scores

    def _evaluate_moves_2ply_batch(self, board: Board, possible_moves: List[Move], color: int) -> List[float]:
        """Expectimax over the 21 distinct dice outcomes. For each candidate move, opponent picks
        the response that maximizes their own value; we average across dice weighted by probability."""
        device = self._model_device()
        opponent_color = -color
        is_our_turn = color == WHITE
        is_opp_turn = not is_our_turn

        dice = Dice(_DIE_SIDES)

        # Leaf values are gathered into one flat array; exact-race leaves are
        # resolved immediately via the bear-off DB, the rest in one net batch.
        leaf_values: List[float] = []
        pending_encoded: List[np.ndarray] = []
        pending_slots: List[int] = []
        plans: List[Optional[List[Tuple[int, int, float, str]]]] = []

        def add_leaf(persp_is_white: bool) -> None:
            exact = self._exact_value(board, persp_is_white)
            if exact is not None:
                leaf_values.append(exact)
            else:
                leaf_values.append(0.0)  # placeholder, filled from the net batch
                pending_slots.append(len(leaf_values) - 1)
                pending_encoded.append(
                    self.board_encoder.encode_board(board, is_whites_turn=persp_is_white))

        for m_c in possible_moves:
            token_c = board.apply(m_c, color)
            if board.has_won(color):
                plans.append(None)
                board.undo(token_c)
                continue
            cand_plan: List[Tuple[int, int, float, str]] = []
            for (i, j, weight) in _DICE_OUTCOMES:
                dice.set(i, j)
                opp_moves = legal_moves(board, opponent_color, dice)
                start = len(leaf_values)
                if not opp_moves:
                    add_leaf(is_our_turn)
                    end = len(leaf_values)
                    cand_plan.append((start, end, weight, "pass"))
                else:
                    for m_o in opp_moves:
                        token_o = board.apply(m_o, opponent_color)
                        add_leaf(is_opp_turn)
                        board.undo(token_o)
                    end = len(leaf_values)
                    cand_plan.append((start, end, weight, "opp_max"))
            plans.append(cand_plan)
            board.undo(token_c)

        if pending_encoded:
            board_batch = torch.from_numpy(np.stack(pending_encoded)).float().to(device)
            with torch.no_grad():
                net_values = self.board_evaluator(board_batch).squeeze(1).detach().cpu().numpy()
            for slot, val in zip(pending_slots, net_values):
                leaf_values[slot] = float(val)
        values = np.asarray(leaf_values, dtype=np.float32)

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

    def _evaluate_moves_nply(
        self,
        board: Board,
        possible_moves: List[Move],
        color: int,
        depth: int,
        beam_threshold: float,
        deadline: Optional[float] = None,
        relative_cutoff: Optional[float] = None,
        max_branch: Optional[int] = None,
    ) -> List[float]:
        """Recursive expectimax with beam pruning at opponent branches.

        depth=1 delegates to _evaluate_moves_batch.
        depth>1: for each candidate, iterates all 21 dice outcomes; pre-screens opponent
        moves with 1-ply and prunes them via _prune_branches (relative_cutoff + max_branch,
        falling back to beam_threshold); recurses on survivors. Raises _TimeoutError if
        deadline is exceeded mid-computation.
        """
        if depth <= 1:
            return self._evaluate_moves_batch(board, possible_moves, color)

        device = self._model_device()
        opponent_color = -color
        is_our_turn = color == WHITE
        dice = Dice(_DIE_SIDES)
        scores: List[float] = []

        for m_c in possible_moves:
            token_c = board.apply(m_c, color)
            # try/finally guarantees token_c is undone even if a deadline (_TimeoutError)
            # unwinds the recursion from a deeper frame mid-iteration.
            try:
                if board.has_won(color):
                    scores.append(1.0)
                    continue

                expected = 0.0
                # Collect pass-positions (no opp moves) for a single deferred batch resolve
                pass_encoded: List[np.ndarray] = []
                pass_weights: List[float] = []

                for (d1, d2, weight) in _DICE_OUTCOMES:
                    if deadline is not None and time.monotonic() > deadline:
                        raise _TimeoutError()

                    dice.set(d1, d2)
                    opp_moves = legal_moves(board, opponent_color, dice)

                    if not opp_moves:
                        exact = self._exact_value(board, is_our_turn)
                        if exact is not None:
                            expected += weight * exact
                        else:
                            pass_encoded.append(self.board_encoder.encode_board(board, is_whites_turn=is_our_turn))
                            pass_weights.append(weight)
                        continue

                    # 1-ply pre-screen to prune unpromising opponent replies
                    opp_1ply = self._evaluate_moves_batch(board, opp_moves, opponent_color)
                    surviving_idx = self._prune_branches(
                        opp_moves, opp_1ply, beam_threshold, relative_cutoff, max_branch
                    )
                    surviving = [opp_moves[i] for i in surviving_idx]

                    opp_deep = self._evaluate_moves_nply(
                        board, surviving, opponent_color, depth - 1, beam_threshold, deadline,
                        relative_cutoff, max_branch,
                    )
                    expected += weight * (1.0 - max(opp_deep))

                # Resolve all pass-positions in one batch
                if pass_encoded:
                    batch = torch.from_numpy(np.stack(pass_encoded)).float().to(device)
                    with torch.no_grad():
                        vals = self.board_evaluator(batch).squeeze(1).detach().cpu().numpy()
                    for val, w in zip(vals, pass_weights):
                        expected += w * float(val)

                scores.append(expected)
            finally:
                board.undo(token_c)

        return scores

    def get_best_move(
        self,
        board: Board,
        possible_moves: List[Move],
        color: int,
        lookahead_plies: int = 1,
        time_budget_s: Optional[float] = None,
        beam_threshold: float = 0.08,
        relative_cutoff: Optional[float] = None,
        max_branch: Optional[int] = None,
        max_depth: Optional[int] = None,
    ) -> Tuple[Optional[Move], float]:
        if not possible_moves:
            self.last_search_depth = 0
            return None, 0.0

        if len(possible_moves) == 1:
            self.last_search_depth = 1
            return possible_moves[0], 0.0

        # Non-time-budget path: existing fixed-depth behavior
        if time_budget_s is None:
            if lookahead_plies >= 2:
                move_scores = self._evaluate_moves_2ply_batch(board, possible_moves, color)
                self.last_search_depth = 2
            else:
                move_scores = self._evaluate_moves_batch(board, possible_moves, color)
                self.last_search_depth = 1
            best_idx = int(max(range(len(move_scores)), key=lambda i: move_scores[i]))
            return possible_moves[best_idx], move_scores[best_idx]

        # Iterative deepening with beam pruning
        deadline = time.monotonic() + time_budget_s

        # Depth 1: score all root moves unconditionally
        best_scores = self._evaluate_moves_batch(board, possible_moves, color)
        best_idx = int(max(range(len(best_scores)), key=lambda i: best_scores[i]))
        self.last_search_depth = 1

        depth = 2
        while time.monotonic() < deadline:
            if max_depth is not None and depth > max_depth:
                break  # don't attempt depths we won't realistically complete
            candidate_indices = self._prune_branches(
                possible_moves, best_scores, beam_threshold, relative_cutoff, max_branch
            )
            candidate_moves = [possible_moves[i] for i in candidate_indices]

            try:
                partial = self._evaluate_moves_nply(
                    board, candidate_moves, color, depth, beam_threshold, deadline,
                    relative_cutoff, max_branch,
                )
            except _TimeoutError:
                break  # discard partial results, keep previous depth's best

            new_scores = list(best_scores)
            for j, i in enumerate(candidate_indices):
                new_scores[i] = partial[j]
            best_scores = new_scores
            best_idx = int(max(range(len(best_scores)), key=lambda i: best_scores[i]))
            self.last_search_depth = depth
            depth += 1

        return possible_moves[best_idx], best_scores[best_idx]

    def evaluate_moves(self, board: Board, possible_moves: List[Move], color: int, lookahead_plies: int = 1) -> List[float]:
        if not possible_moves:
            return []
        if lookahead_plies >= 2:
            return self._evaluate_moves_2ply_batch(board, possible_moves, color)
        return self._evaluate_moves_batch(board, possible_moves, color)

    def position_value_lookahead(self, board: Board, color: int) -> float:
        """Pre-roll depth-2 expectimax value for `color` to move: average over the 21 weighted
        dice outcomes of `color`'s best 1-ply move value (net / bear-off at the leaves). This is
        a one-ply Bellman backup of the raw net eval — a strictly better bootstrap target than
        net(position), used by the depth-2 TD-target experiment (E14). Returns a win-prob for
        `color`, matching the perspective of the net's own bootstrap values."""
        dice = Dice(_DIE_SIDES)
        opp_is_white = (color != WHITE)
        device = self._model_device()
        expected = 0.0
        for (i, j, weight) in _DICE_OUTCOMES:
            dice.set(i, j)
            moves = legal_moves(board, color, dice)
            if not moves:
                # `color` has no legal move and passes; value for `color` is 1 - opponent's static value.
                exact = self._exact_value(board, opp_is_white)
                if exact is not None:
                    v = exact
                else:
                    enc = self.board_encoder.encode_board(board, is_whites_turn=opp_is_white)
                    with torch.no_grad():
                        v = float(self.board_evaluator(
                            torch.from_numpy(enc).float().unsqueeze(0).to(device)).squeeze())
                expected += weight * (1.0 - v)
            else:
                expected += weight * max(self._evaluate_moves_batch(board, moves, color))
        return float(expected)

class RandomAgent:
    """An agent that chooses a move randomly from the possible moves."""
    def get_move(self, possible_moves: List[Move]) -> Move:
        return random.choice(possible_moves)
