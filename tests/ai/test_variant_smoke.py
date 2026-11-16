"""End-to-end smoke for the new variants (#137 follow-up): the PARALLEL self-play
worker path, terminal values in trajectories, and a tiny real `plateau` driver run,
for portes, fevga and plakoto_standard."""

import json
import os
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
import yaml

from ai.agent import Agent
from ai.board_evaluator import BoardEvaluator
from ai.self_play_worker import play_one_game_record
from ai.td_lambda_training import TdLambdaTraining
from config.config_loader import ConfigLoader
from domain.constants import WHITE

REPO = Path(__file__).resolve().parents[2]
VARIANT_CONFIGS = {
    "portes": REPO / "config" / "config-portes.yml",
    "fevga": REPO / "config" / "config-fevga.yml",
    "plakoto_standard": REPO / "config" / "config-plakoto-standard.yml",
}


def tiny_config(variant, d, **extra):
    """The variant's real config with tiny sizes and every output path inside `d`."""
    with open(VARIANT_CONFIGS[variant]) as fh:
        cfg = yaml.safe_load(fh)
    cfg.update({
        "hidden_sizes": [8], "num_self_play_workers": 2, "num_epochs": 1, "games_per_epoch": 4,
        "eval_every_epochs": 1000, "eval_against_gold": False, "eval_against_random": False,
        "replay_buffer_capacity": 500, "min_buffer_to_train": 0, "minibatch_size": 8,
        "updates_per_game": 1, "lr_warmup_steps": 0,
        "model_save_path": os.path.join(d, "m.pth"),
        "training_state_path": os.path.join(d, "ts.json"),
        "training_log_path": os.path.join(d, "train.log"),
        "last_game_log_path": os.path.join(d, "last_game.txt"),
        "gold_eval_log_path": os.path.join(d, "gold.log"),
        "gold_model_path": os.path.join(d, "no_gold.pth"),
    })
    cfg.update(extra)
    path = os.path.join(d, f"{variant}.yml")
    with open(path, "w") as fh:
        yaml.safe_dump(cfg, fh)
    return path


class TestVariantParallelTraining(unittest.TestCase):
    def test_two_worker_epoch_each_variant(self):
        for variant in VARIANT_CONFIGS:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as d:
                config = ConfigLoader(tiny_config(variant, d))
                rules = config.get_ruleset()
                enc = rules.make_encoder(config)
                ev = BoardEvaluator(enc.input_size, hidden_sizes=config.get_hidden_sizes())
                trainer = TdLambdaTraining(ev, enc, config, ruleset=rules)
                self.assertEqual(trainer.num_self_play_workers, 2)
                trainer.run_training_loop()               # >1 worker -> parallel path
                self.assertEqual(trainer.global_game_num, 4)
                self.assertGreater(len(trainer.replay), 4)
                self.assertTrue(os.path.exists(os.path.join(d, "m.pth")))


class TestVariantTerminalValues(unittest.TestCase):
    def test_trajectory_terminal_values(self):
        seen = {}
        for variant in VARIANT_CONFIGS:
            with tempfile.TemporaryDirectory() as d:
                config = ConfigLoader(tiny_config(variant, d))
            rules = config.get_ruleset()
            enc = rules.make_encoder(config)
            agent = Agent(BoardEvaluator(enc.input_size, hidden_sizes=[8]), enc, ruleset=rules)
            random.seed(11); np.random.seed(11)
            values = set()
            for _ in range(12):
                tr = play_one_game_record(agent, enc, config, 0.0, 1.0)
                tv = tr["terminal_value_white"]
                pts = tr["result_points"]
                if pts == 0:
                    self.assertEqual(tv, 0.5)                        # draw
                else:
                    sign = 1 if tr["terminal_winner_white"] else -1
                    self.assertEqual(tv, 0.5 + sign * pts / 4.0, variant)
                self.assertIn(tv, (0.0, 0.25, 0.5, 0.75, 1.0))
                values.add(tv)
            seen[variant] = values
            self.assertTrue(values - {0.5}, variant)
        for variant, values in seen.items():
            print(f"{variant}: terminal values seen {sorted(values)}")


@unittest.skipUnless(os.environ.get("TAVLI_SLOW_TESTS"),
                     "~70s of real train/eval subprocesses; set TAVLI_SLOW_TESTS=1")
class TestVariantPlateauSmoke(unittest.TestCase):
    """Real subprocesses: 2 rounds (bootstrap promotes v1, then a forced plateau)."""

    def test_plateau_each_variant(self):
        for variant in VARIANT_CONFIGS:
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as d:
                cfg_path = tiny_config(variant, d, num_self_play_workers=2, plateau={
                    "round_games": 4, "eval_pairs": 2, "random_eval_pairs": 2,
                    "final_random_eval_pairs": 2, "random_promote_winrate": 0.0,
                    "promote_z": 99.0, "patience": 1, "min_edge": 10.0, "eval_workers": 2,
                    "ladder_dir": os.path.join(d, "models"),
                    "state_path": os.path.join(d, "state.json"),
                    "log_path": os.path.join(d, "plateau.log"),
                    "work_dir": os.path.join(d, "work"),
                    "stages": [{"name": "depth1", "overrides": {"bootstrap_depth": 1}}],
                })
                proc = subprocess.run([sys.executable, str(REPO / "main.py"), "--config", cfg_path,
                                       "plateau"], cwd=d, capture_output=True, text=True,
                                      timeout=300)
                self.assertEqual(proc.returncode, 0, proc.stdout[-3000:] + proc.stderr[-3000:])
                with open(os.path.join(d, "state.json")) as fh:
                    st = json.load(fh)
                self.assertEqual(st["status"], "finished")
                self.assertEqual(st["round"], 2)
                self.assertEqual(st["games_played"], 8)
                self.assertTrue(os.path.exists(os.path.join(d, "models", f"{variant}_gold_v1.pth")))
                r2 = st["rounds"][1]
                self.assertEqual(r2["metric"], "points")
                self.assertIsNotNone(r2["ppg"])
                self.assertIsNotNone(st["final_vs_random"]["ppg"])
                status = subprocess.run([sys.executable, str(REPO / "main.py"), "--config",
                                         cfg_path, "plateau-status"], cwd=d,
                                        capture_output=True, text=True)
                self.assertIn("FINISHED", status.stdout)
                self.assertIn("normalized points", status.stdout)


if __name__ == "__main__":
    unittest.main()
