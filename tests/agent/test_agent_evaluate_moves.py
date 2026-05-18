import unittest
import torch
from pathlib import Path

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice, Die
from domain.move_generation import legal_moves


class DummyEvaluator(torch.nn.Module):
    def __init__(self, target_encoding, target_value=0.0, default_value=0.5):
        super().__init__()
        self.register_buffer("target_encoding", torch.from_numpy(target_encoding).float().unsqueeze(0))
        self._device_anchor = torch.nn.Parameter(torch.zeros(1), requires_grad=False)
        self.target_value = float(target_value)
        self.default_value = float(default_value)

    def forward(self, x):
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
        self.board = Board.from_config(self.config)
        self.encoder = BoardEncoder(self.config)

    def test_winning_capture_move_scores_highest(self):
        # White at 23, black singleton at 24 (white can pin/capture to win), plus another legal move.
        self.board.set_point(23, WHITE, 1)
        self.board.set_point(24, BLACK, 1)
        self.board.set_point(5, WHITE, 2)

        dice = Dice(self.config.get_die_sides())
        dice.set(1, 2)

        possible_moves = legal_moves(self.board, WHITE, dice)

        winning_move = None
        winning_encoded = None
        for move in possible_moves:
            token = self.board.apply(move, WHITE)
            if self.board.has_won(WHITE):
                winning_move = move
                winning_encoded = self.encoder.encode_board(self.board, is_whites_turn=False)
                self.board.undo(token)
                break
            self.board.undo(token)

        self.assertIsNotNone(winning_move, "Expected at least one winning move")

        dummy_eval = DummyEvaluator(winning_encoded, target_value=0.0, default_value=0.5)
        agent = Agent(dummy_eval, self.encoder)

        scores = agent.evaluate_moves(self.board, possible_moves, WHITE)

        winning_index = possible_moves.index(winning_move)
        self.assertEqual(scores[winning_index], max(scores))
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)

    def _setup_white_bears_off_last_piece(self):
        """14 white pieces borne off, 1 white at slot 23. White rolls (2, _) to win."""
        board_size = self.config.get_board_size()
        self.board.set_point(board_size + 1, WHITE, 14)
        self.board.borne_off[WHITE] = 14
        self.board.set_point(23, WHITE, 1)
        self.board.set_point(1, BLACK, 5)

        dice = Dice(self.config.get_die_sides())
        dice.set(2, 5)
        possible_moves = legal_moves(self.board, WHITE, dice)

        winning_index = None
        for idx, move in enumerate(possible_moves):
            token = self.board.apply(move, WHITE)
            if self.board.has_won(WHITE):
                winning_index = idx
                self.board.undo(token)
                break
            self.board.undo(token)
        self.assertIsNotNone(winning_index, "Expected at least one winning bear-off move")
        return possible_moves, winning_index

    def test_bear_off_last_piece_scores_1_at_1ply(self):
        possible_moves, winning_index = self._setup_white_bears_off_last_piece()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        scores = agent.evaluate_moves(self.board, possible_moves, WHITE, lookahead_plies=1)
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)

    def test_bear_off_last_piece_scores_1_at_2ply(self):
        possible_moves, winning_index = self._setup_white_bears_off_last_piece()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        scores = agent.evaluate_moves(self.board, possible_moves, WHITE, lookahead_plies=2)
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)


if __name__ == "__main__":
    unittest.main()
