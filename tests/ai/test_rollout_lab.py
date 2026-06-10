import unittest

import numpy as np
import torch

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import ENCODER_VERSION_CURRENT
from ai.rollout_lab import (
    MinedPosition,
    fine_tune,
    mine_games,
    rollout_value,
    state_net_value,
    state_search_value,
)
from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK


def _make_agent(config):
    encoder = BoardEncoder(config, version=ENCODER_VERSION_CURRENT)
    evaluator = BoardEvaluator(encoder.input_size, hidden_sizes=[16, 8])
    evaluator.eval()
    return Agent(evaluator, encoder, bearoff=None)


class TestRolloutLab(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader("config-test.yml")
        torch.manual_seed(0)
        cls.agent = _make_agent(cls.config)

    def test_state_values_in_unit_interval(self):
        board = Board.initial(self.config)
        v_net = state_net_value(self.agent, board, mover_is_white=True)
        v_search = state_search_value(self.agent, board, WHITE)
        self.assertTrue(0.0 <= v_net <= 1.0)
        self.assertTrue(0.0 <= v_search <= 1.0)

    def test_residual_property(self):
        pos = MinedPosition(board=None, mover_color=WHITE,
                            encoded=np.zeros(1, dtype=np.float32),
                            v_net=0.4, v_search=0.55)
        self.assertAlmostEqual(pos.residual, 0.15, places=6)

    def test_rollout_value_dominated_position(self):
        # White: 14 borne off, one checker at distance 1 (needs a 1, E≈3.3 rolls).
        # Black: 15 checkers at distance 23 (≈20+ rolls). White ~always wins.
        board = Board()
        board.set_point(24, WHITE, 1)
        board.set_point(23, BLACK, 15)
        board.borne_off[WHITE] = 14
        rng = np.random.default_rng(7)
        values = [rollout_value(self.agent, board, WHITE, rng) for _ in range(10)]
        self.assertGreaterEqual(np.mean(values), 0.9)
        for v in values:
            self.assertTrue(0.0 <= v <= 1.0)
        # The original board is untouched (rollouts play on a clone).
        self.assertEqual(board.borne_off[WHITE], 14)
        self.assertEqual(board.movable_count(24, WHITE), 1)

    def test_mine_games_smoke(self):
        rng = np.random.default_rng(3)
        mined = mine_games(self.agent, self.config, num_games=1, sample_every=10, rng=rng)
        self.assertGreater(len(mined), 0)
        for pos in mined:
            self.assertIn(pos.mover_color, (WHITE, BLACK))
            self.assertEqual(pos.encoded.shape, (self.agent.board_encoder.input_size,))
            self.assertGreaterEqual(pos.residual, 0.0)
            self.assertTrue(0.0 <= pos.v_net <= 1.0)
            self.assertTrue(0.0 <= pos.v_search <= 1.0)

    def test_fine_tune_moves_predictions_toward_labels(self):
        torch.manual_seed(1)
        evaluator = BoardEvaluator(32, hidden_sizes=[16])
        rng = np.random.default_rng(5)
        states = rng.standard_normal((64, 32)).astype(np.float32)
        labels = np.where(rng.random(64) < 0.5, 0.05, 0.95).astype(np.float32)

        x = torch.from_numpy(states).float()
        with torch.no_grad():
            before = evaluator(x).squeeze(1).numpy()
        err_before = np.abs(before - labels).mean()

        fine_tune(evaluator, states, labels,
                  anchor_states=np.empty((0, 32), np.float32),
                  anchor_targets=np.empty((0,), np.float32),
                  lr=5e-3, steps=300, batch_size=32, seed=0)

        with torch.no_grad():
            after = evaluator(x).squeeze(1).numpy()
        err_after = np.abs(after - labels).mean()
        self.assertLess(err_after, err_before)
        self.assertFalse(evaluator.training)  # eval mode restored

    def test_fine_tune_anchors_limit_drift(self):
        # With anchors pinned to the pre-fine-tune outputs, anchor predictions
        # should stay close to where they started.
        torch.manual_seed(2)
        evaluator = BoardEvaluator(32, hidden_sizes=[16])
        rng = np.random.default_rng(9)
        labeled = rng.standard_normal((32, 32)).astype(np.float32)
        labels = np.full(32, 0.9, dtype=np.float32)
        anchors = rng.standard_normal((64, 32)).astype(np.float32)
        ax = torch.from_numpy(anchors).float()
        with torch.no_grad():
            anchor_targets = evaluator(ax).squeeze(1).numpy().astype(np.float32)

        fine_tune(evaluator, labeled, labels, anchors, anchor_targets,
                  lr=5e-3, steps=300, batch_size=32, seed=0)

        with torch.no_grad():
            after = evaluator(ax).squeeze(1).numpy()
        self.assertLess(np.abs(after - anchor_targets).mean(), 0.1)


if __name__ == "__main__":
    unittest.main()
