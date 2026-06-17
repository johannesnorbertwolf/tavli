import os
import unittest

import torch

from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import ENCODER_VERSION_CURRENT, load_state_dict
from ai.td_lambda_training import TdLambdaTraining
from config.config_loader import ConfigLoader


def _build_trainer(ema_decay):
    cfg = ConfigLoader("config-test.yml")
    if ema_decay is not None:
        cfg.config["ema_decay"] = ema_decay
    encoder = BoardEncoder(cfg, version=ENCODER_VERSION_CURRENT)
    ev = BoardEvaluator(encoder.input_size, hidden_sizes=[16, 8])
    return TdLambdaTraining(ev, encoder, cfg), ev


class TestEma(unittest.TestCase):
    def tearDown(self):
        for p in ("test_trained_model.pth", "test_trained_model_ema.pth"):
            if os.path.exists(p):
                os.remove(p)

    def test_off_by_default(self):
        trainer, _ = _build_trainer(ema_decay=None)
        self.assertEqual(trainer.ema_decay, 0.0)
        self.assertIsNone(trainer.ema_params)
        trainer._update_ema()  # must be a no-op, not a crash

    def test_ema_initialized_to_params(self):
        trainer, ev = _build_trainer(ema_decay=0.9)
        self.assertIsNotNone(trainer.ema_params)
        for n, p in ev.named_parameters():
            self.assertTrue(torch.allclose(trainer.ema_params[n], p))

    def test_ema_tracks_and_lags(self):
        trainer, ev = _build_trainer(ema_decay=0.9)
        old_ema = {n: trainer.ema_params[n].clone() for n, _ in ev.named_parameters()}
        with torch.no_grad():
            for p in ev.parameters():
                p.add_(1.0)
        new_params = {n: p.detach().clone() for n, p in ev.named_parameters()}
        trainer._update_ema()
        for n, _ in ev.named_parameters():
            expected = 0.9 * old_ema[n] + 0.1 * new_params[n]
            self.assertTrue(torch.allclose(trainer.ema_params[n], expected, atol=1e-6))

    def test_save_writes_ema_checkpoint_and_restores_raw(self):
        trainer, ev = _build_trainer(ema_decay=0.9)
        # Make EMA differ from raw so we can tell them apart in the saved file.
        with torch.no_grad():
            for n in trainer.ema_params:
                trainer.ema_params[n].add_(5.0)
        raw_before = {n: p.detach().clone() for n, p in ev.named_parameters()}

        trainer._save_checkpoint_with_ema()

        ema_path = trainer._ema_save_path()
        self.assertTrue(os.path.exists(trainer.model_save_path))
        self.assertTrue(os.path.exists(ema_path))

        # Raw evaluator weights must be unchanged after the swap-save-restore.
        for n, p in ev.named_parameters():
            self.assertTrue(torch.allclose(p, raw_before[n]))

        # The EMA checkpoint must hold the EMA weights, not the raw ones.
        sd, _ = load_state_dict(ema_path)
        for n in trainer.ema_params:
            self.assertTrue(torch.allclose(sd[n], trainer.ema_params[n], atol=1e-6))


if __name__ == "__main__":
    unittest.main()
