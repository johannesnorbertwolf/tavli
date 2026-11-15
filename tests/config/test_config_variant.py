import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from config.config_loader import ConfigLoader, resolve_config_path, DEFAULT_CONFIG_PATH
from domain.plakoto_rules import PlakotoRules
from game.game import Game

ROOT = Path(__file__).resolve().parents[2]


def _write_config(text):
    fh = tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False)
    fh.write(text)
    fh.close()
    return fh.name


class TestConfigVariant(unittest.TestCase):
    def tearDown(self):
        for p in getattr(self, "_tmp", []):
            os.unlink(p)

    def _cfg(self, text):
        path = _write_config(text)
        self._tmp = getattr(self, "_tmp", []) + [path]
        return ConfigLoader(path)

    def test_repo_configs_select_plakoto(self):
        for name in ("config/config.yml", "config-test.yml"):
            cfg = ConfigLoader(str(ROOT / name))
            self.assertEqual(cfg.get_variant(), "plakoto")
            self.assertIsInstance(cfg.get_ruleset(), PlakotoRules)

    def test_variant_defaults_to_plakoto_when_absent(self):
        cfg = self._cfg("board_size: 24\n")
        self.assertEqual(cfg.get_variant(), "plakoto")
        self.assertIsInstance(cfg.get_ruleset(), PlakotoRules)

    def test_unknown_variant_raises_on_ruleset(self):
        cfg = self._cfg("variant: nonsense\n")
        self.assertEqual(cfg.get_variant(), "nonsense")
        with self.assertRaises(ValueError):
            cfg.get_ruleset()

    def test_game_uses_config_ruleset(self):
        game = Game(ConfigLoader(str(ROOT / "config-test.yml")))
        self.assertIsInstance(game.ruleset, PlakotoRules)
        game.dice.set(6, 5)
        self.assertEqual(game.legal_moves(),
                         game.ruleset.legal_moves(game.board, game.player, game.dice))

    def test_per_run_paths_default_and_override(self):
        cfg = self._cfg("board_size: 24\n")
        self.assertEqual(cfg.get_model_save_path(), "trained_model.pth")
        self.assertEqual(cfg.get_gold_eval_log_path(),
                         os.path.join("training_runs", "eval_gold_history.log"))
        self.assertEqual(cfg.get_training_log_path(), "training_log_td.txt")
        self.assertEqual(cfg.get_last_game_log_path(), "last_game_log.txt")
        cfg = self._cfg("model_save_path: m.pth\ngold_eval_log_path: g.log\n"
                        "training_log_path: t.txt\nlast_game_log_path: l.txt\n")
        self.assertEqual((cfg.get_model_save_path(), cfg.get_gold_eval_log_path(),
                          cfg.get_training_log_path(), cfg.get_last_game_log_path()),
                         ("m.pth", "g.log", "t.txt", "l.txt"))


class TestResolveConfigPath(unittest.TestCase):
    def test_default(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TAVLI_CONFIG", None)
            argv = ["main.py", "train", "3"]
            self.assertEqual(resolve_config_path(argv), DEFAULT_CONFIG_PATH)
            self.assertEqual(argv, ["main.py", "train", "3"])

    def test_env_var(self):
        with mock.patch.dict(os.environ, {"TAVLI_CONFIG": "config/env.yml"}):
            self.assertEqual(resolve_config_path(["main.py", "train"]), "config/env.yml")

    def test_flag_beats_env_and_is_stripped(self):
        with mock.patch.dict(os.environ, {"TAVLI_CONFIG": "config/env.yml"}):
            argv = ["main.py", "train", "--config", "config/flag.yml", "3"]
            self.assertEqual(resolve_config_path(argv), "config/flag.yml")
            self.assertEqual(argv, ["main.py", "train", "3"])
            argv = ["main.py", "--config=config/eq.yml", "play"]
            self.assertEqual(resolve_config_path(argv), "config/eq.yml")
            self.assertEqual(argv, ["main.py", "play"])


if __name__ == "__main__":
    unittest.main()
