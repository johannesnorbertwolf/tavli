import os
import tempfile
import unittest

import torch

from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import load_agent_from_checkpoint, save_checkpoint
from ai.net2net import expand_checkpoint, widen_evaluator
from config.config_loader import ConfigLoader


class TestNet2Net(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader("config-test.yml")
        torch.manual_seed(0)

    def test_widen_preserves_function_exactly_without_noise(self):
        old = BoardEvaluator(20, hidden_sizes=[16, 8])
        old.eval()
        new = widen_evaluator(old, [32, 16], noise_std=0.0)
        x = torch.rand(256, 20)
        with torch.no_grad():
            dev = (old(x) - new(x)).abs().max()
        self.assertLess(float(dev), 1e-6)
        self.assertEqual(list(new.hidden_sizes), [32, 16])

    def test_widen_with_noise_stays_close(self):
        old = BoardEvaluator(20, hidden_sizes=[16, 8])
        old.eval()
        new = widen_evaluator(old, [64, 32], noise_std=1e-3)
        x = torch.rand(256, 20)
        with torch.no_grad():
            dev = (old(x) - new(x)).abs().max()
        self.assertLess(float(dev), 0.05)

    def test_widen_rejects_bad_shapes(self):
        old = BoardEvaluator(20, hidden_sizes=[16, 8])
        with self.assertRaises(ValueError):
            widen_evaluator(old, [32], noise_std=0.0)
        with self.assertRaises(ValueError):
            widen_evaluator(old, [8, 8], noise_std=0.0)

    def test_expand_checkpoint_round_trip(self):
        from ai.board_encoder import BoardEncoder
        from ai.checkpoint_io import ENCODER_VERSION_CURRENT

        encoder = BoardEncoder(self.config, version=ENCODER_VERSION_CURRENT)
        old = BoardEvaluator(encoder.input_size, hidden_sizes=[16, 8])
        old.eval()
        with tempfile.TemporaryDirectory() as tmp:
            in_path = os.path.join(tmp, "small.pth")
            out_path = os.path.join(tmp, "wide.pth")
            save_checkpoint(in_path, old, self.config)
            expand_checkpoint(in_path, out_path, [32, 16], self.config, noise_std=0.0)
            agent, meta = load_agent_from_checkpoint(out_path, self.config)
            self.assertEqual(list(meta["hidden_sizes"]), [32, 16])
            x = torch.rand(64, encoder.input_size)
            with torch.no_grad():
                dev = (old(x) - agent.board_evaluator(x)).abs().max()
            self.assertLess(float(dev), 1e-6)
