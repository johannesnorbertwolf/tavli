import math
import unittest

import torch

from config.config_loader import ConfigLoader
from ai.checkpoint_io import load_agent_from_checkpoint
from ai.agent import _DICE_OUTCOMES, _DIE_SIDES
from ai.self_play_worker import play_one_game_record
from domain.board import Board
from domain.dice import Dice
from domain.move_generation import legal_moves
from domain.constants import WHITE


class TestBootstrapDepth(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader("config-test.yml")  # use_bearoff_db: false
        cls.agent, _ = load_agent_from_checkpoint(
            "models/gold_v1.pth", cls.config, device=torch.device("cpu"))
        cls.encoder = cls.agent.board_encoder

    def test_position_value_matches_dice_weighted_best_move(self):
        # On the opening board every dice has at least one legal move, so the depth-2
        # value is exactly the dice-weighted average of the best 1-ply move value.
        board = Board.initial(self.config)
        dice = Dice(_DIE_SIDES)
        expected = 0.0
        for (i, j, w) in _DICE_OUTCOMES:
            dice.set(i, j)
            moves = legal_moves(board, WHITE, dice)
            self.assertTrue(moves)
            expected += w * max(self.agent.evaluate_moves(board, moves, WHITE, lookahead_plies=1))
        got = self.agent.position_value_lookahead(board, WHITE)
        self.assertAlmostEqual(got, expected, places=5)
        self.assertTrue(0.0 < got < 1.0)

    def test_trajectory_carries_bootstrap_values_when_on(self):
        traj = play_one_game_record(self.agent, self.encoder, self.config, epsilon=0.0,
                                    exploration_temperature=1.0, bootstrap_depth=2)
        boot = traj["bootstrap_values"]
        self.assertEqual(len(boot), len(traj["states"]))
        self.assertTrue(math.isnan(boot[-1]))                  # terminal state → NaN
        finite = [b for b in boot[:-1] if not math.isnan(b)]
        self.assertGreaterEqual(len(finite), 1)
        for b in finite:
            self.assertTrue(0.0 <= b <= 1.0)

    def test_off_by_default_all_nan(self):
        traj = play_one_game_record(self.agent, self.encoder, self.config, epsilon=0.0,
                                    exploration_temperature=1.0, bootstrap_depth=1)
        self.assertTrue(all(math.isnan(b) for b in traj["bootstrap_values"]))


if __name__ == "__main__":
    unittest.main()
