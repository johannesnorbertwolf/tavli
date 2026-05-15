import unittest
from pathlib import Path

import numpy as np
import torch

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from config.config_loader import ConfigLoader
from domain.board import GameBoard
from domain.color import Color
from domain.dice import Dice, Die
from domain.possible_moves import PossibleMoves


class ConstantEvaluator(torch.nn.Module):
    def __init__(self, value=0.5):
        super().__init__()
        self._device_anchor = torch.nn.Parameter(torch.zeros(1), requires_grad=False)
        self.value = float(value)

    def forward(self, x):
        return torch.full((x.shape[0], 1), self.value, dtype=x.dtype, device=x.device)


class RandomDeterministicEvaluator(torch.nn.Module):
    """Hash-based deterministic evaluator: same input → same output, but values
    vary across inputs so max/min over move sets isn't trivially uniform."""
    def __init__(self):
        super().__init__()
        self._device_anchor = torch.nn.Parameter(torch.zeros(1), requires_grad=False)

    def forward(self, x):
        # Sigmoid over a fixed linear projection of the input — stable and varied.
        weights = torch.linspace(-0.01, 0.01, x.shape[1], device=x.device, dtype=x.dtype)
        return torch.sigmoid((x * weights).sum(dim=1, keepdim=True))


class TestTdLeafTarget(unittest.TestCase):
    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))
        self.encoder = BoardEncoder(self.config)

    def _initial_board(self):
        board = GameBoard(self.config)
        board.initialize_board()
        return board

    def test_returns_value_in_range(self):
        board = self._initial_board()
        agent = Agent(RandomDeterministicEvaluator(), self.encoder)
        v = agent.value_with_lookahead(board, Color.WHITE, depth=1)
        self.assertIsInstance(v, float)
        self.assertGreaterEqual(v, 0.0)
        self.assertLessEqual(v, 1.0)

    def test_constant_evaluator_on_initial_board(self):
        """With a ConstantEvaluator(0.5) and no winning moves available, every
        per-move 1-ply score is 1 - 0.5 = 0.5, so max = 0.5 and the dice-weighted
        average is also 0.5."""
        board = self._initial_board()
        agent = Agent(ConstantEvaluator(value=0.5), self.encoder)
        v = agent.value_with_lookahead(board, Color.WHITE, depth=1)
        self.assertAlmostEqual(v, 0.5, places=6)

    def test_depth_zero_returns_raw_value(self):
        board = self._initial_board()
        agent = Agent(ConstantEvaluator(value=0.42), self.encoder)
        v = agent.value_with_lookahead(board, Color.WHITE, depth=0)
        self.assertAlmostEqual(v, 0.42, places=6)

    def test_constant_asymmetric_value(self):
        """ConstantEvaluator(0.3): every per-move 1-ply score is 1 - 0.3 = 0.7
        and pass-fallback contributes (1 - 0.3) = 0.7 as well, so the dice-
        weighted average is exactly 0.7 regardless of dice outcomes."""
        board = self._initial_board()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        v = agent.value_with_lookahead(board, Color.WHITE, depth=1)
        self.assertAlmostEqual(v, 0.7, places=6)

    def test_dice_weights_sum_to_one(self):
        """If the per-outcome value is identical (constant evaluator), the
        weighted average must equal that value — verifies the 21 dice weights
        sum to 1.0 inside the helper."""
        board = self._initial_board()
        agent = Agent(ConstantEvaluator(value=0.123), self.encoder)
        v = agent.value_with_lookahead(board, Color.WHITE, depth=1)
        self.assertAlmostEqual(v, 1.0 - 0.123, places=6)

    def test_equivalent_to_2ply_score_after_alignment(self):
        """`_evaluate_moves_2ply_batch(B, [M], mover)[0]` is the mover's expected
        win rate after playing M and opp responding optimally. That equals
        `1 - value_with_lookahead(s_after_M, opp, depth=1)` by definition.

        Both paths now share the same perspective convention (encode from
        next-to-move's perspective), so the equality should hold exactly."""
        board = self._initial_board()
        agent = Agent(RandomDeterministicEvaluator(), self.encoder)

        dice = Dice(self.config.get_die_sides())
        dice.die1 = Die(self.config.get_die_sides(), 3)
        dice.die2 = Die(self.config.get_die_sides(), 5)
        moves = PossibleMoves(board, Color.WHITE, dice).find_moves()
        self.assertTrue(len(moves) > 0)
        move = moves[0]

        scores_2ply = agent._evaluate_moves_2ply_batch(board, [move], Color.WHITE)
        score_M = scores_2ply[0]

        board.apply(move)
        v_search = agent.value_with_lookahead(board, Color.BLACK, depth=1)
        board.undo(move)

        self.assertAlmostEqual(1.0 - v_search, score_M, places=5)


if __name__ == "__main__":
    unittest.main()
