import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

from ai.paired_eval import summarize
from ai.plateau_driver import (
    DEFAULTS, PlateauDriver, decide, decision_stats, format_status, load_settings,
    plateau_check, pool_results, should_promote,
)

REPO = Path(__file__).resolve().parents[2]


def _json(path):
    with open(path) as fh:
        return json.load(fh)


def _yaml(path):
    with open(path) as fh:
        return yaml.safe_load(fh)


def _bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def R(rate, z, n=1000, std=0.5):
    """Synthetic paired summary with mean_d consistent with rate."""
    return {"num_pairs": n, "mean_d": 2 * (rate - 0.5), "std_d": std, "z": z, "rate": rate,
            "num_games": 2 * n}


SETTINGS = dict(DEFAULTS, stages=[{"name": "a"}])


class TestDecisionLogic(unittest.TestCase):
    def test_pool_matches_concatenated_sample(self):
        a = [1, 0, 0, -1, 1, 1]
        b = [0, 0, -1, 1]

        def summ(d):
            n = len(d); m = sum(d) / n
            v = sum((x - m) ** 2 for x in d) / (n - 1)
            return {"num_pairs": n, "mean_d": m, "std_d": v ** 0.5}
        p = pool_results([summ(a), summ(b)])
        full = summ(a + b)
        self.assertEqual(p["num_pairs"], 10)
        self.assertAlmostEqual(p["mean_d"], full["mean_d"])
        self.assertAlmostEqual(p["std_d"], full["std_d"])
        self.assertAlmostEqual(p["edge"], full["mean_d"] / 2)

    def test_promotion_needs_both_z_and_rate(self):
        self.assertTrue(should_promote(R(0.53, 2.5), 2.0, 0.52))
        self.assertFalse(should_promote(R(0.53, 1.9), 2.0, 0.52))   # not significant
        self.assertFalse(should_promote(R(0.515, 3.0), 2.0, 0.52))  # significant but tiny

    def test_bootstrap_promotes_vs_random_at_threshold(self):
        self.assertTrue(decide(False, R(0.91, 30), [], 1, SETTINGS)["promote"])
        d = decide(False, R(0.80, 20), [], 1, SETTINGS)
        self.assertFalse(d["promote"])
        self.assertIsNone(d["stage_end"])

    def test_plateau_requires_patience(self):
        flat = [R(0.50, 0.0, n=5000, std=0.4)] * 2
        self.assertFalse(plateau_check(flat, SETTINGS)[0])          # 2 < patience 4
        self.assertTrue(plateau_check(flat * 2, SETTINGS)[0])

    def test_plateau_requires_power(self):
        # Same flat point estimate but tiny samples -> UCB too wide -> keep going.
        weak = [R(0.50, 0.0, n=50, std=0.7)] * 4
        ok, pooled = plateau_check(weak, SETTINGS)
        self.assertFalse(ok)
        self.assertGreater(pooled["edge_ucb"], SETTINGS["min_edge"])

    def test_no_plateau_while_still_improving(self):
        # +1.5pp each round, not individually promotable (z<2) but pooled UCB > min_edge.
        rising = [R(0.515, 1.8, n=2000, std=0.5)] * 6
        self.assertFalse(plateau_check(rising, SETTINGS)[0])

    def test_below_fifty_counts_as_plateau(self):
        worse = [R(0.48, -3.0, n=2000, std=0.5)] * 4
        self.assertTrue(plateau_check(worse, SETTINGS)[0])

    def test_decide_plateau_and_max_rounds(self):
        streak = [R(0.50, 0.0, n=5000, std=0.4)] * 3
        d = decide(True, R(0.50, 0.0, n=5000, std=0.4), streak, 4, SETTINGS)
        self.assertEqual(d["stage_end"], "plateau")
        d = decide(True, R(0.51, 1.0, n=10, std=0.7), [], SETTINGS["max_rounds"], SETTINGS)
        self.assertEqual(d["stage_end"], "max_rounds")
        d = decide(True, R(0.56, 4.0), streak, 4, SETTINGS)
        self.assertTrue(d["promote"])
        self.assertIsNone(d["stage_end"])


class TestPointsStatistic(unittest.TestCase):
    """max_points > 1 variants decide on normalized points; max_points == 1 unchanged."""

    def test_summarize_points_equal_wins_for_one_point_games(self):
        # (d_k, a_wins_k, a_points_k) with a draw: points 0, half a win.
        res = [(1, 2, 2), (0, 1, 0), (-1, 0, -2), (0.5, 1.5, 1), (0, 1, 0)]
        s = summarize(res, max_points=1)
        for k in ("mean_d", "std_d", "z", "rate"):
            self.assertAlmostEqual(s["pts_" + k], s[k], msg=k)

    def test_summarize_points_two_point_games(self):
        # A wins both games of each pair, but by gammons (2+2) vs singles (1+1).
        res = [(1, 2, 4), (1, 2, 2), (1, 2, 4), (1, 2, 2)]
        s = summarize(res, max_points=2)
        self.assertEqual(s["rate"], 1.0)
        self.assertAlmostEqual(s["pts_mean_d"], (1 + 0.5 + 1 + 0.5) / 4)
        self.assertAlmostEqual(s["pts_rate"], 0.5 + 0.75 / 2)
        self.assertAlmostEqual(s["points_per_game"], 12 / 8)

    def test_decision_stats(self):
        s = summarize([(1, 2, 4), (-1, 0, -2), (0, 1, 1), (0, 1, 2)], max_points=2)
        wins = decision_stats(s, 1)
        self.assertEqual((wins["metric"], wins["z"], wins["rate"]), ("wins", s["z"], s["rate"]))
        pts = decision_stats(s, 2)
        self.assertEqual((pts["metric"], pts["z"], pts["rate"]), ("points", s["pts_z"], s["pts_rate"]))
        self.assertEqual(pts["win_rate"], s["rate"])
        self.assertEqual(pts["ppg"], s["points_per_game"])

    def test_bootstrap_gate_uses_win_rate(self):
        r = dict(R(0.80, 20), win_rate=0.95)        # equity 0.80, wins 95%
        self.assertTrue(decide(False, r, [], 1, SETTINGS)["promote"])

    def test_settings_max_points(self):
        self.assertEqual(load_settings({"variant": "plakoto"})["max_points"], 1)
        for v in ("portes", "fevga", "plakoto_standard"):
            self.assertEqual(load_settings({"variant": v})["max_points"], 2)


class _Fakes:
    """In-process stand-ins for the train/eval subprocesses."""

    def __init__(self, model_path, rates, fail_train=0, crash_eval_at=None):
        self.model_path = model_path
        self.rates = list(rates)
        self.fail_train = fail_train
        self.crash_eval_at = crash_eval_at
        self.train_calls = []
        self.eval_calls = []

    def train(self, cfg_path, epochs, log):
        self.train_calls.append(_yaml(cfg_path))
        if self.fail_train > 0:
            self.fail_train -= 1
            return 3
        with open(self.model_path, "wb") as fh:
            fh.write(f"model-{len(self.train_calls)}".encode())
        return 0

    def eval(self, cfg_path, a, opp, pairs, seed, workers, out_json, log):
        self.eval_calls.append(opp)
        if self.crash_eval_at is not None and len(self.eval_calls) == self.crash_eval_at:
            raise KeyboardInterrupt  # simulates the driver being killed mid-eval
        rate = self.rates.pop(0)
        z = 10.0 if rate > 0.6 else 0.0
        return 0, dict(R(rate, z, n=5000, std=0.4), num_pairs=pairs, num_games=2 * pairs)


class TestDriverStateMachine(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = self.tmp.name
        self.model = os.path.join(self.d, "m.pth")
        self.cfg = {
            "variant": "plakoto", "games_per_epoch": 10, "learning_rate": 1e-4,
            "model_save_path": self.model,
            "training_state_path": os.path.join(self.d, "ts.json"),
            "training_log_path": os.path.join(self.d, "train.log"),
            "plateau": {
                "round_games": 25, "eval_pairs": 5000, "patience": 2,
                "random_eval_pairs": 10, "final_random_eval_pairs": 10,
                "ladder_dir": os.path.join(self.d, "models"),
                "state_path": os.path.join(self.d, "state.json"),
                "log_path": os.path.join(self.d, "plateau.log"),
                "work_dir": os.path.join(self.d, "work"),
                "stages": [{"name": "s1", "overrides": {"bootstrap_depth": 1}},
                           {"name": "s2", "overrides": {"learning_rate": 3e-5}}],
            },
        }
        self.cfg_path = os.path.join(self.d, "cfg.yml")
        with open(self.cfg_path, "w") as fh:
            yaml.safe_dump(self.cfg, fh)

    def tearDown(self):
        self.tmp.cleanup()

    def _driver(self, fakes):
        return PlateauDriver(self.cfg_path, train_runner=fakes.train,
                             eval_runner=fakes.eval, out=lambda *_: None)

    # rates: r1 vs random 0.95 -> v1; r2 0.5; r3 0.5 -> plateau s1;
    #        r4 0.7 -> v2; r5 0.5; r6 0.5 -> plateau s2 -> final vs random 0.97
    RATES = [0.95, 0.5, 0.5, 0.7, 0.5, 0.5, 0.97]

    def test_full_run_stages_and_ladder(self):
        f = _Fakes(self.model, self.RATES)
        self.assertEqual(self._driver(f).run(), 0)
        st = _json(self.cfg["plateau"]["state_path"])
        self.assertEqual(st["status"], "finished")
        self.assertEqual(st["round"], 6)
        self.assertEqual([os.path.basename(p) for p in st["ladder"]],
                         ["plakoto_gold_v1.pth", "plakoto_gold_v2.pth"])
        self.assertEqual([r["reason"] for r in st["stage_results"]], ["plateau", "plateau"])
        self.assertEqual(st["final_vs_random"]["rate"], 0.97)
        self.assertEqual(st["rounds"][0]["vs_random"], 0.95)
        # Opponents: random, then v1, v1, v1 (stage 2 starts vs v1), v2, v2, final random.
        self.assertEqual([os.path.basename(o) for o in f.eval_calls],
                         ["random", "plakoto_gold_v1.pth", "plakoto_gold_v1.pth",
                          "plakoto_gold_v1.pth", "plakoto_gold_v2.pth",
                          "plakoto_gold_v2.pth", "random"])
        # Stage overrides + gold pointer land in the derived config, never the user's yml.
        self.assertEqual(f.train_calls[0]["bootstrap_depth"], 1)
        self.assertFalse(f.train_calls[0]["eval_against_gold"])
        self.assertEqual(f.train_calls[3]["learning_rate"], 3e-5)
        self.assertTrue(f.train_calls[3]["gold_model_path"].endswith("plakoto_gold_v1.pth"))
        self.assertEqual(_yaml(self.cfg_path), self.cfg)
        # Snapshots are copies of the model at promotion time.
        self.assertEqual(_bytes(st["ladder"][0]), b"model-1")
        self.assertEqual(_bytes(st["ladder"][1]), b"model-4")
        status = format_status(self.cfg_path)
        self.assertIn("FINISHED", status)
        self.assertIn("plakoto_gold_v2", status)
        with open(self.cfg["plateau"]["log_path"]) as fh:
            log = fh.read()
        self.assertIn("PLATEAU", log)
        # Rerunning a finished run is a no-op.
        f2 = _Fakes(self.model, [])
        self.assertEqual(self._driver(f2).run(), 0)
        self.assertEqual(f2.train_calls, [])

    def test_resume_after_kill_matches_uninterrupted(self):
        f = _Fakes(self.model, self.RATES, crash_eval_at=3)
        with self.assertRaises(KeyboardInterrupt):
            self._driver(f).run()
        st = _json(self.cfg["plateau"]["state_path"])
        self.assertEqual((st["round"], st["phase"]), (2, "eval"))   # killed during round 3 eval
        f2 = _Fakes(self.model, self.RATES[2:])
        self.assertEqual(self._driver(f2).run(), 0)
        self.assertEqual(len(f2.train_calls), 3)                   # round 3 not retrained
        st = _json(self.cfg["plateau"]["state_path"])
        self.assertEqual(st["round"], 6)
        self.assertEqual(len(st["ladder"]), 2)

    def test_existing_snapshot_never_overwritten(self):
        ladder = self.cfg["plateau"]["ladder_dir"]
        os.makedirs(ladder)
        with open(os.path.join(ladder, "plakoto_gold_v1.pth"), "wb") as fh:
            fh.write(b"precious")
        f = _Fakes(self.model, [0.7, 0.5, 0.5, 0.5, 0.5, 0.97])
        self._driver(f).run()
        self.assertEqual(_bytes(os.path.join(ladder, "plakoto_gold_v1.pth")), b"precious")
        self.assertEqual(_bytes(os.path.join(ladder, "plakoto_gold_v2.pth")), b"model-1")
        self.assertTrue(f.eval_calls[0].endswith("plakoto_gold_v1.pth"))  # adopted, no bootstrap

    def test_retry_once_then_failed(self):
        f = _Fakes(self.model, self.RATES, fail_train=1)
        self.assertEqual(self._driver(f).run(), 0)                  # one failure is retried
        self.tearDown(); self.setUp()
        f = _Fakes(self.model, self.RATES, fail_train=2)
        self.assertEqual(self._driver(f).run(), 1)
        st = _json(self.cfg["plateau"]["state_path"])
        self.assertEqual(st["status"], "failed")
        self.assertIn("training", st["error"])
        self.assertIn("FAILED", format_status(self.cfg_path))

    def test_points_variant_promotes_on_points(self):
        """Portes: wins are flat (z=0) but A wins bigger -> promoted on the points z."""
        self.cfg["variant"] = "portes"
        with open(self.cfg_path, "w") as fh:
            yaml.safe_dump(self.cfg, fh)
        calls = []

        def ev(cfg_path, a, opp, pairs, seed, workers, out_json, log):
            calls.append(opp)
            if opp == "random":
                base = dict(R(0.95, 30, n=pairs), pts_mean_d=0.8, pts_std_d=0.3, pts_z=30.0,
                            pts_rate=0.9, points_per_game=1.6)
            elif len(calls) == 2:
                base = dict(R(0.50, 0.0, n=pairs), pts_mean_d=0.1, pts_std_d=0.4, pts_z=8.0,
                            pts_rate=0.55, points_per_game=0.2)
            else:
                base = dict(R(0.50, 0.0, n=pairs, std=0.4), pts_mean_d=0.0, pts_std_d=0.4,
                            pts_z=0.0, pts_rate=0.5, points_per_game=0.0)
            return 0, dict(base, num_games=2 * pairs)

        f = _Fakes(self.model, [])
        drv = PlateauDriver(self.cfg_path, train_runner=f.train, eval_runner=ev, out=lambda *_: None)
        self.assertEqual(drv.run(), 0)
        st = _json(self.cfg["plateau"]["state_path"])
        self.assertEqual([os.path.basename(p) for p in st["ladder"]][:2],
                         ["portes_gold_v1.pth", "portes_gold_v2.pth"])
        r2 = st["rounds"][1]
        self.assertTrue(r2["promoted"])
        self.assertEqual((r2["metric"], r2["rate"], r2["win_rate"], r2["ppg"]),
                         ("points", 0.55, 0.5, 0.2))
        self.assertEqual(st["rounds"][0]["vs_random"], 0.95)
        status = format_status(self.cfg_path)
        self.assertIn("normalized points", status)
        self.assertIn("+0.200", status)

    def test_settings_defaults(self):
        s = load_settings({"variant": "fevga"})
        self.assertEqual(s["state_path"], "plateau_state_fevga.json")
        self.assertEqual(len(s["stages"]), 1)
        self.assertEqual(s["patience"], 4)


class TestPlateauSmokeEndToEnd(unittest.TestCase):
    """Real subprocesses (train + paired eval) on a tiny plakoto config."""

    def test_end_to_end_tiny(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = _yaml(REPO / "config-test.yml")
            cfg.update({
                "hidden_sizes": [8], "num_self_play_workers": 1, "eval_every_epochs": 1000,
                "eval_against_gold": False, "model_save_path": os.path.join(d, "m.pth"),
                "training_state_path": os.path.join(d, "ts.json"),
                "training_log_path": os.path.join(d, "train.log"),
                "last_game_log_path": os.path.join(d, "last_game.txt"),
                "gold_eval_log_path": os.path.join(d, "gold.log"),
                "plateau": {
                    "round_games": 1, "eval_pairs": 2, "random_eval_pairs": 1,
                    "final_random_eval_pairs": 1, "random_promote_winrate": 0.0,
                    "promote_z": 99.0, "patience": 1, "min_edge": 10.0, "eval_workers": 1,
                    "ladder_dir": os.path.join(d, "models"),
                    "state_path": os.path.join(d, "state.json"),
                    "log_path": os.path.join(d, "plateau.log"),
                    "work_dir": os.path.join(d, "work"),
                },
            })
            cfg_path = os.path.join(d, "cfg.yml")
            with open(cfg_path, "w") as fh:
                yaml.safe_dump(cfg, fh)
            proc = subprocess.run([sys.executable, str(REPO / "main.py"), "--config", cfg_path,
                                   "plateau"], cwd=d, capture_output=True, text=True, timeout=120)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            st = _json(os.path.join(d, "state.json"))
            self.assertEqual(st["status"], "finished")
            self.assertEqual(st["round"], 2)                       # bootstrap -> v1, then plateau
            self.assertTrue(os.path.exists(os.path.join(d, "models", "plakoto_gold_v1.pth")))
            self.assertEqual(st["games_played"], 2)
            self.assertIsNotNone(st["final_vs_random"])
            status = subprocess.run([sys.executable, str(REPO / "main.py"), "--config", cfg_path,
                                     "plateau-status"], cwd=d, capture_output=True, text=True)
            self.assertIn("FINISHED", status.stdout)


if __name__ == "__main__":
    unittest.main()
