import unittest
import torch
from agent.board_evaluator import BoardEvaluator

class TestBoardEvaluator(unittest.TestCase):
    def setUp(self):
        self.input_size = 128  # Example input size, adjust based on your actual board encoding
        self.hidden_size = 64  # Example hidden layer size
        self.model = BoardEvaluator(self.input_size, self.hidden_size)

        # Generate a batch of random board encodings
        self.batch_size = 10
        self.board_encodings = torch.rand(self.batch_size, self.input_size)

    def test_output_shape(self):
        # Test if the output shape is correct
        outputs = self.model(self.board_encodings)
        self.assertEqual(outputs.shape, (self.batch_size, 1), "Output shape is incorrect")

    def test_output_range(self):
        # Test if the output values are within the expected range [0, 1] due to the sigmoid
        outputs = self.model(self.board_encodings)
        self.assertTrue(torch.all(outputs >= 0) and torch.all(outputs <= 1),
                        "Output values are not in the range [0, 1]")

    def test_find_max_output(self):
        # Test finding the board encoding with the maximum output
        outputs = self.model(self.board_encodings)
        max_index = torch.argmax(outputs)
        best_encoding = self.board_encodings[max_index]

        # Ensure max_index is within the valid range
        self.assertTrue(0 <= max_index < self.batch_size, "Max index is out of range")

        # Check if best_encoding is indeed part of the input encodings
        self.assertTrue(best_encoding in self.board_encodings, "Best encoding is not in the input batch")

    def test_forward_pass(self):
        # Test if the forward pass runs without errors
        try:
            outputs = self.model(self.board_encodings)
        except Exception as e:
            self.fail(f"Forward pass failed with error: {e}")

    def test_weight_initialization(self):
        # Test if the weights are initialized randomly and not all zeros
        for param in self.model.parameters():
            self.assertTrue(torch.any(param != 0), "Weights should not be initialized to zero")


if __name__ == '__main__':
    unittest.main()