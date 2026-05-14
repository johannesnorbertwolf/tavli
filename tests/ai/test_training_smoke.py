import unittest
from pathlib import Path

import torch

from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder
from ai.td_lambda_training import TdLambdaTraining
from config.config_loader import ConfigLoader


class TestTrainingSmoke(unittest.TestCase):
    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))

    def test_train_one_game_smoke(self):
        encoder = BoardEncoder(self.config)
        evaluator = BoardEvaluator(encoder.input_size, hidden_sizes=self.config.get_hidden_sizes())
        trainer = TdLambdaTraining(evaluator, encoder, self.config)

        # Should complete without raising errors
        trainer.train_one_game()

        # Basic sanity: model outputs remain in [0, 1]
        sample = torch.rand(1, encoder.input_size)
        output = evaluator(sample)
        self.assertTrue(torch.all(output >= 0) and torch.all(output <= 1))


if __name__ == "__main__":
    unittest.main()

