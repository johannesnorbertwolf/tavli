"""Game-outcome seam (#137 Part A) and a Portes training smoke test."""

import os
import random
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch
import yaml

from ai.board_evaluator import BoardEvaluator
from ai.self_play_worker import play_one_game_record
from ai.agent import Agent
from ai.td_lambda_training import TdLambdaTraining, compute_lambda_returns
from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.portes_board import PortesBoard
from domain.ruleset import get_ruleset, score_for

ROOT = Path(__file__).resolve().parents[2]


class TestOutcomeSeam(unittest.TestCase):
    def test_plakoto_defaults_unchanged(self):
        rules = get_ruleset("plakoto")
        self.assertEqual(rules.max_points, 1)
        self.assertFalse(rules.random_starting_player)
        b = Board()
        b.borne_off[WHITE] = 15
        self.assertTrue(rules.is_over(b))
        self.assertEqual(rules.outcome(b), (WHITE, 1))
        self.assertEqual(rules.terminal_value(b, WHITE), 1.0)
        self.assertEqual(rules.terminal_value(b, BLACK), 0.0)

    def test_fixed_starter_never_touches_rng(self):
        rules = get_ruleset("plakoto")
        state = random.getstate()
        self.assertEqual(rules.starting_player(BLACK), BLACK)
        self.assertEqual(random.getstate(), state)

    def test_random_starter_is_seeded_and_mixed(self):
        rules = get_ruleset("portes")
        rng = random.Random(1)
        starters = [rules.starting_player(WHITE, rng) for _ in range(200)]
        self.assertTrue(40 < starters.count(WHITE) < 160)
        rng2 = random.Random(1)
        self.assertEqual(starters, [rules.starting_player(WHITE, rng2) for _ in range(200)])

    def test_score_for(self):
        self.assertEqual(score_for((WHITE, 2), WHITE), (1.0, 2))
        self.assertEqual(score_for((WHITE, 2), BLACK), (0.0, -2))
        self.assertEqual(score_for((None, 0), BLACK), (0.5, 0))

    def test_lambda_returns_terminal_value(self):
        values = np.array([0.6, 0.4, 0.99], dtype=np.float32)
        movers = np.array([True, False], dtype=bool)
        legacy = compute_lambda_returns(values, movers, False, 0.5)
        same = compute_lambda_returns(values, movers, False, 0.5, terminal_value_white=0.0)
        np.testing.assert_array_equal(legacy, same)
        # Black wins a single game (Portes): terminal 0.25 for White, 0.75 for Black.
        t = compute_lambda_returns(values, movers, False, 0.5, terminal_value_white=0.25)
        np.testing.assert_allclose(t, [0.5 * 0.6 + 0.5 * 0.25, 0.75, 0.25], atol=1e-6)

    def test_agent_scores_gammon_win_higher(self):
        """1-ply search scores an immediate win by its terminal value (points)."""
        config = ConfigLoader(str(ROOT / "config" / "config-portes.yml"))
        rules = config.get_ruleset()
        enc = rules.make_encoder(config)
        agent = Agent(BoardEvaluator(enc.input_size, hidden_sizes=[8]), enc, ruleset=rules)
        from domain.dice import Dice
        dice = Dice()
        dice.set(6, 5)
        single = PortesBoard.from_counts({24: 1}, {1: 14}, white_off=14, black_off=1)
        moves = rules.legal_moves(single, WHITE, dice)
        self.assertEqual(agent.evaluate_moves(single, moves, WHITE), [0.75])
        gammon = PortesBoard.from_counts({24: 1}, {1: 15}, white_off=14)
        moves = rules.legal_moves(gammon, WHITE, dice)
        self.assertEqual(agent.evaluate_moves(gammon, moves, WHITE), [1.0])
        self.assertEqual(agent.evaluate_moves(gammon, moves, WHITE, lookahead_plies=2), [1.0])


class TestPortesTrainingSmoke(unittest.TestCase):
    def setUp(self):
        self._orig_cwd = os.getcwd()
        self._tmpdir = tempfile.TemporaryDirectory()
        with open(ROOT / "config-test.yml") as fh:
            cfg = yaml.safe_load(fh)
        cfg.update({
            "variant": "portes", "hidden_sizes": [16, 8],
            "num_epochs": 1, "games_per_epoch": 1, "num_self_play_workers": 1,
            "eval_every_epochs": 1, "eval_games_per_color": 1,
            "eval_against_random": True, "eval_against_gold": True,
            "gold_model_path": "models/portes_gold_v0.pth",   # absent: must be skipped
            "model_save_path": "m.pth", "training_state_path": "s.json",
            "gold_eval_log_path": "gold.log", "last_game_log_path": "last.txt",
        })
        path = os.path.join(self._tmpdir.name, "config-portes-test.yml")
        with open(path, "w") as fh:
            yaml.safe_dump(cfg, fh)
        os.chdir(self._tmpdir.name)
        self.config = ConfigLoader(path)

    def tearDown(self):
        os.chdir(self._orig_cwd)
        self._tmpdir.cleanup()

    def test_one_epoch(self):
        rules = self.config.get_ruleset()
        enc = rules.make_encoder(self.config)
        ev = BoardEvaluator(enc.input_size, hidden_sizes=self.config.get_hidden_sizes())
        trainer = TdLambdaTraining(ev, enc, self.config, ruleset=rules)
        self.assertIsNone(trainer.gold_agent)
        trainer.run_training_loop()
        self.assertTrue(os.path.exists("m.pth"))
        from ai.checkpoint_io import load_state_dict
        _, meta = load_state_dict("m.pth")
        self.assertEqual((meta["variant"], meta["encoder_version"]), ("portes", "portes_v1"))
        self.assertIsNotNone(trainer.last_eval_points)

    def test_trajectory_terminal_value(self):
        rules = self.config.get_ruleset()
        enc = rules.make_encoder(self.config)
        agent = Agent(BoardEvaluator(enc.input_size, hidden_sizes=[16, 8]), enc, ruleset=rules)
        random.seed(3); np.random.seed(3)
        for _ in range(3):
            traj = play_one_game_record(agent, enc, self.config, 0.0, 1.0)
            tv = traj["terminal_value_white"]
            pts = traj["result_points"]
            self.assertIn(pts, (1, 2))
            expected = 0.5 + (pts if traj["terminal_winner_white"] else -pts) / 4.0
            self.assertEqual(tv, expected)
            self.assertEqual(len(traj["states"]), traj["plies"] + 1)


if __name__ == "__main__":
    unittest.main()
