import unittest
import torch
from pathlib import Path

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from config.config_loader import ConfigLoader
from domain.board import GameBoard
from domain.color import Color
from domain.dice import Dice, Die
from domain.point import Point
from domain.possible_moves import PossibleMoves


class DummyEvaluator(torch.nn.Module):
    def __init__(self, target_encoding, target_value=0.0, default_value=0.5):
        super().__init__()
        self.register_buffer("target_encoding", torch.from_numpy(target_encoding).float().unsqueeze(0))
        # Placeholder param so Agent._model_device() can locate the device.
        self._device_anchor = torch.nn.Parameter(torch.zeros(1), requires_grad=False)
        self.target_value = float(target_value)
        self.default_value = float(default_value)

    def forward(self, x):
        # Per-row comparison so a batched call still works.
        out = torch.full((x.shape[0], 1), self.default_value, dtype=x.dtype, device=x.device)
        target = self.target_encoding[0]
        for row in range(x.shape[0]):
            if torch.allclose(x[row], target):
                out[row, 0] = self.target_value
        return out


class ConstantEvaluator(torch.nn.Module):
    def __init__(self, value=0.3):
        super().__init__()
        self._device_anchor = torch.nn.Parameter(torch.zeros(1), requires_grad=False)
        self.value = float(value)

    def forward(self, x):
        return torch.full((x.shape[0], 1), self.value, dtype=x.dtype, device=x.device)


class TestAgentEvaluateMoves(unittest.TestCase):
    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))
        self.board = GameBoard(self.config)
        self.encoder = BoardEncoder(self.config)

    def test_winning_capture_move_scores_highest(self):
        # Set up a position where a capture of black's starting point is winning.
        board_size = self.board.board_size
        for i in range(0, board_size + 2):
            self.board.points[i] = Point(i)

        # White can capture at 24 with die=1
        self.board.points[23] = Point(23, Color.WHITE, 1)
        self.board.points[24] = Point(24, Color.BLACK, 1)

        # Another legal move exists (non-winning)
        self.board.points[5] = Point(5, Color.WHITE, 2)

        dice = Dice(self.config.get_die_sides())
        dice.die1 = Die(self.config.get_die_sides(), 1)
        dice.die2 = Die(self.config.get_die_sides(), 2)

        possible_moves = PossibleMoves(self.board, Color.WHITE, dice).find_moves()

        # Identify one winning move and compute its after-state encoding (opponent's turn).
        winning_move = None
        winning_encoded = None
        for move in possible_moves:
            self.board.apply(move)
            if self.board.has_won(Color.WHITE):
                winning_move = move
                winning_encoded = self.encoder.encode_board(self.board, is_whites_turn=False)
                self.board.undo(move)
                break
            self.board.undo(move)

        self.assertIsNotNone(winning_move, "Expected at least one winning move")

        dummy_eval = DummyEvaluator(winning_encoded, target_value=0.0, default_value=0.5)
        agent = Agent(dummy_eval, self.encoder)

        scores = agent.evaluate_moves(self.board, possible_moves, Color.WHITE)

        # Winning move should get the highest score
        winning_index = possible_moves.index(winning_move)
        self.assertEqual(scores[winning_index], max(scores))
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)

    def _setup_white_bears_off_last_piece(self):
        """Set up: 14 white pieces in white's bear-off (slot 25), 1 white piece at slot 23.
        White rolls (2, _) so that 23 -> 25 bears off the last piece and white wins."""
        board_size = self.board.board_size
        for i in range(0, board_size + 2):
            self.board.points[i] = Point(i)

        # 14 already borne off, 1 left to bear off at slot 23.
        self.board.points[board_size + 1] = Point(board_size + 1, Color.WHITE, 14)
        self.board.points[23] = Point(23, Color.WHITE, 1)
        # Park black far away from a win so the game isn't already over.
        self.board.points[1] = Point(1, Color.BLACK, 5)

        dice = Dice(self.config.get_die_sides())
        dice.die1 = Die(self.config.get_die_sides(), 2)
        dice.die2 = Die(self.config.get_die_sides(), 5)
        possible_moves = PossibleMoves(self.board, Color.WHITE, dice).find_moves()

        # Find the winning bear-off move.
        winning_index = None
        for idx, move in enumerate(possible_moves):
            self.board.apply(move)
            if self.board.has_won(Color.WHITE):
                winning_index = idx
                self.board.undo(move)
                break
            self.board.undo(move)
        self.assertIsNotNone(winning_index, "Expected at least one winning bear-off move")
        return possible_moves, winning_index

    def test_bear_off_last_piece_scores_1_at_1ply(self):
        """Bug fix: the move that bears off the 15th piece must score exactly 1.0,
        regardless of what the network's untrained terminal-state output happens to be."""
        possible_moves, winning_index = self._setup_white_bears_off_last_piece()

        # Network returns 0.3 for every state — without the short-circuit, the winning
        # move would score 1 - 0.3 = 0.7, matching the user-observed miscalibration.
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        scores = agent.evaluate_moves(self.board, possible_moves, Color.WHITE, lookahead_plies=1)
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)

    def test_bear_off_last_piece_scores_1_at_2ply(self):
        """Same as above but exercises the 2-ply expectimax path used by interactive play.
        Without the fix this returned ~0.70 (the user-reported '70.17%' bug)."""
        possible_moves, winning_index = self._setup_white_bears_off_last_piece()

        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        scores = agent.evaluate_moves(self.board, possible_moves, Color.WHITE, lookahead_plies=2)
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)

    def test_opponent_terminal_win_short_circuited_at_2ply(self):
        """Symmetric to `test_bear_off_last_piece_scores_1_at_1ply`, but for the opponent's
        side of the 2-ply tree. If opponent can win outright with their response, the scorer
        must treat that response's value as 0 (we lose) instead of using the network's raw
        output. Without the short-circuit, a constant 0.5 network masks the loss and
        candidate scores stay at ~0.5; with it, almost every dice outcome contains a
        terminal-loss response and candidate scores collapse toward 0."""
        board_size = self.board.board_size
        for i in range(0, board_size + 2):
            self.board.points[i] = Point(i)

        # Black: 14 borne off + 1 piece at slot 2. Black bears off the last piece with
        # any die >= 2 (only piece left, so overshoots are legal).
        self.board.points[0] = Point(0, Color.BLACK, 14)
        self.board.points[2] = Point(2, Color.BLACK, 1)
        # White: all 15 packed deep in white's home — far from a winning bear-off this turn.
        self.board.points[19] = Point(19, Color.WHITE, 15)

        dice = Dice(self.config.get_die_sides())
        dice.die1 = Die(self.config.get_die_sides(), 3)
        dice.die2 = Die(self.config.get_die_sides(), 5)
        possible_moves = PossibleMoves(self.board, Color.WHITE, dice).find_moves()
        self.assertTrue(len(possible_moves) > 0)

        # ConstantEvaluator(0.5): every non-terminal V is 0.5. Without the short-circuit, every
        # opp response (including the winning bear-off) is scored 0.5 and the 2-ply score for
        # any candidate is exactly 0.5. With the short-circuit, every dice outcome where black
        # has at least one bear-off response is driven to 0 (mover loses), so the candidate
        # score is strictly less than 0.5.
        agent = Agent(ConstantEvaluator(value=0.5), self.encoder)
        scores = agent.evaluate_moves(self.board, possible_moves, Color.WHITE, lookahead_plies=2)
        self.assertLess(
            max(scores), 0.45,
            f"Expected 2-ply scores below 0.5 after opp-terminal short-circuit; got {max(scores)}",
        )


if __name__ == "__main__":
    unittest.main()

