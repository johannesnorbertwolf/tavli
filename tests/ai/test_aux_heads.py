import os
import tempfile
import unittest

import numpy as np
import torch

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import ENCODER_VERSION_CURRENT, load_agent_from_checkpoint, save_checkpoint
from ai.self_play_worker import play_one_game_record
from ai.td_lambda_training import ReplayBuffer, TdLambdaTraining
from config.config_loader import ConfigLoader


class TestAuxHeads(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader("config-test.yml")
        torch.manual_seed(0)

    def test_evaluator_aux_shapes_and_main_path_unchanged(self):
        ev = BoardEvaluator(20, hidden_sizes=[16, 8], aux_heads=2)
        ev.eval()
        x = torch.rand(5, 20)
        with torch.no_grad():
            main_logit, aux_logits = ev.forward_aux_logits(x)
            self.assertEqual(main_logit.shape, (5, 1))
            self.assertEqual(aux_logits.shape, (5, 2))
            # forward() must be the sigmoid of the same main logit (aux head inert).
            self.assertTrue(torch.allclose(ev(x), torch.sigmoid(main_logit)))

    def test_trajectory_carries_outcome_fields(self):
        encoder = BoardEncoder(self.config, version=ENCODER_VERSION_CURRENT)
        ev = BoardEvaluator(encoder.input_size, hidden_sizes=[16, 8])
        ev.eval()
        agent = Agent(ev, encoder, bearoff=None)
        traj = play_one_game_record(agent, encoder, self.config,
                                    epsilon=0.0, exploration_temperature=1.0)
        self.assertIn("win_by_pin", traj)
        self.assertIsInstance(traj["win_by_pin"], bool)
        total = self.config.get_pieces_per_player()
        self.assertTrue(0 <= traj["final_borne_off_white"] <= total)
        self.assertTrue(0 <= traj["final_borne_off_black"] <= total)

    def test_replay_buffer_aux_round_trip(self):
        buf = ReplayBuffer(capacity=8, state_dim=3, aux_dim=2)
        states = np.arange(12, dtype=np.float32).reshape(4, 3)
        targets = np.array([0.1, 0.2, 0.3, 0.4], dtype=np.float32)
        aux = np.arange(8, dtype=np.float32).reshape(4, 2) / 10.0
        buf.push_many(states, targets, aux)
        s, t, a = buf.sample_aux(4)
        self.assertEqual(a.shape[1], 2)
        for i in range(len(t)):
            j = int(np.where(np.isclose(targets, t[i]))[0][0])
            np.testing.assert_array_almost_equal(a[i], aux[j])

    def test_train_one_game_with_aux_heads(self):
        cfg = ConfigLoader("config-test.yml")
        cfg.config["aux_heads"] = 2
        cfg.config["aux_loss_weight"] = 0.3
        encoder = BoardEncoder(cfg, version=ENCODER_VERSION_CURRENT)
        ev = BoardEvaluator(encoder.input_size, hidden_sizes=[16, 8], aux_heads=2)
        trainer = TdLambdaTraining(ev, encoder, cfg)
        trainer.train_one_game()
        x = torch.rand(1, encoder.input_size)
        with torch.no_grad():
            out = ev(x)
        self.assertTrue(0.0 <= float(out) <= 1.0)

    def test_checkpoint_round_trip_preserves_aux_head(self):
        encoder = BoardEncoder(self.config, version=ENCODER_VERSION_CURRENT)
        ev = BoardEvaluator(encoder.input_size, hidden_sizes=[16, 8], aux_heads=2)
        ev.eval()
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "aux.pth")
            save_checkpoint(path, ev, self.config)
            agent, meta = load_agent_from_checkpoint(path, self.config)
            self.assertEqual(meta["aux_heads"], 2)
            self.assertEqual(agent.board_evaluator.aux_heads, 2)
            x = torch.rand(3, encoder.input_size)
            with torch.no_grad():
                self.assertTrue(torch.allclose(ev(x), agent.board_evaluator(x)))
