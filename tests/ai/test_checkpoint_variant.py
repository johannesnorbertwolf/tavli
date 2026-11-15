import os
import tempfile
import unittest
from pathlib import Path

import torch

from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import (
    VariantMismatchError, load_agent_from_checkpoint, load_state_dict, save_checkpoint,
)
from config.config_loader import ConfigLoader
from domain.plakoto_rules import PlakotoRules

ROOT = Path(__file__).resolve().parents[2]
TEST_CONFIG = str(ROOT / "config-test.yml")
GOLD = ROOT / "models" / "gold_v11.pth"


class TestCheckpointVariant(unittest.TestCase):
    def setUp(self):
        self.config = ConfigLoader(TEST_CONFIG)
        self.tmpdir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmpdir.cleanup()

    def _path(self, name):
        return os.path.join(self.tmpdir.name, name)

    def _other_variant_config(self):
        path = self._path("other.yml")
        with open(TEST_CONFIG) as src, open(path, "w") as dst:
            dst.write(src.read().replace("variant: plakoto", "variant: portes"))
        cfg = ConfigLoader(path)
        self.assertEqual(cfg.get_variant(), "portes")
        return cfg

    def test_save_load_round_trip_records_variant(self):
        encoder = self.config.get_ruleset().make_encoder(self.config)
        ev = BoardEvaluator(encoder.input_size, hidden_sizes=[8])
        path = self._path("m.pth")
        save_checkpoint(path, ev, self.config)
        raw = torch.load(path, weights_only=True)
        self.assertEqual(raw["variant"], "plakoto")
        self.assertEqual(raw["encoder_version"], "unary_v3")
        _, meta = load_state_dict(path)
        self.assertEqual(meta["variant"], "plakoto")
        agent, meta = load_agent_from_checkpoint(path, self.config)
        self.assertIsInstance(agent.ruleset, PlakotoRules)
        self.assertEqual(agent.board_encoder.version, "unary_v3")

    def test_checkpoint_without_variant_is_plakoto(self):
        encoder = self.config.get_ruleset().make_encoder(self.config)
        ev = BoardEvaluator(encoder.input_size, hidden_sizes=[8])
        path = self._path("legacy.pth")
        save_checkpoint(path, ev, self.config)
        raw = torch.load(path, weights_only=True)
        del raw["variant"]
        torch.save(raw, path)
        _, meta = load_state_dict(path)
        self.assertEqual(meta["variant"], "plakoto")
        # Plain legacy state_dict (no metadata at all) too.
        plain = self._path("plain.pth")
        torch.save(ev.state_dict(), plain)
        self.assertEqual(load_state_dict(plain)[1]["variant"], "plakoto")

    @unittest.skipUnless(GOLD.exists(), "gold_v11 checkpoint not present")
    def test_existing_gold_loads_as_plakoto(self):
        agent, meta = load_agent_from_checkpoint(str(GOLD), self.config)
        self.assertEqual(meta["variant"], "plakoto")
        self.assertIsInstance(agent.ruleset, PlakotoRules)

    def test_variant_mismatch_raises(self):
        encoder = self.config.get_ruleset().make_encoder(self.config)
        ev = BoardEvaluator(encoder.input_size, hidden_sizes=[8])
        path = self._path("m.pth")
        save_checkpoint(path, ev, self.config)
        with self.assertRaises(VariantMismatchError) as cm:
            load_agent_from_checkpoint(path, self._other_variant_config())
        msg = str(cm.exception)
        self.assertIn("plakoto", msg)
        self.assertIn("portes", msg)

    def test_checkpoint_of_other_variant_rejected_by_plakoto_config(self):
        encoder = self.config.get_ruleset().make_encoder(self.config)
        ev = BoardEvaluator(encoder.input_size, hidden_sizes=[8])
        path = self._path("portes.pth")
        save_checkpoint(path, ev, self.config)
        raw = torch.load(path, weights_only=True)
        raw["variant"] = "portes"
        torch.save(raw, path)
        with self.assertRaises(VariantMismatchError):
            load_agent_from_checkpoint(path, self.config)


if __name__ == "__main__":
    unittest.main()
