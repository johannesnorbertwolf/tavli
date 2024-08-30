import unittest
import numpy as np
from domain.color import Color
from domain.point import Point
from domain.board import GameBoard
from config.config_loader import ConfigLoader
from ai.board_encoder import BoardEncoder

class TestBoardEncoder(unittest.TestCase):
    def setUp(self):
        # Setting up a mock configuration
        self.config = ConfigLoader("../config-test.yml")  # Adjust path if needed
        self.board = GameBoard(self.config)
        self.encoder = BoardEncoder(self.config)

    def test_encode_empty_point(self):
        # Test encoding of an empty point
        empty_point = Point(position=1)  # No pieces on the point
        expected_encoding = [0, 0, 0, 0] + [0] * self.config.get_pieces_per_player()
        self.assertEqual(self.encoder.encode_point(empty_point), expected_encoding)

    def test_encode_point_with_white_pieces(self):
        # Test encoding of a point with white pieces
        white_point = Point(position=1, color=Color.WHITE, count=3)
        expected_encoding = [1, 0, 0, 0] + [1, 1, 1] + [0] * (self.config.get_pieces_per_player() - 3)
        self.assertEqual(self.encoder.encode_point(white_point), expected_encoding)

    def test_encode_point_with_black_pieces(self):
        # Test encoding of a point with black pieces
        black_point = Point(position=1, color=Color.BLACK, count=2)
        expected_encoding = [1, 1, 0, 0] + [1, 1] + [0] * (self.config.get_pieces_per_player() - 2)
        self.assertEqual(self.encoder.encode_point(black_point), expected_encoding)

    def test_encode_point_captured_by_white(self):
        # Test encoding of a point captured by white
        white_capturing_point = Point(position=1, color=Color.WHITE, count=1)
        white_capturing_point.push(Color.BLACK)  # Simulate capturing
        expected_encoding = [1, 1, 0, 1] + [1] + [0] * (self.config.get_pieces_per_player() - 1)
        self.assertEqual(self.encoder.encode_point(white_capturing_point), expected_encoding)

    def test_encode_board(self):
        # Test encoding of an initialized board
        self.board.initialize_board()
        encoded_board = self.encoder.encode_board(self.board, True)

        # Manually encode the board's initial state
        manual_encoded_board = [0]
        for i in range(0, self.board.board_size + 2):
            point = self.board.points[i]
            manual_encoded_board.extend(self.encoder.encode_point(point))

        manual_encoded_board = np.array(manual_encoded_board)
        np.testing.assert_array_equal(encoded_board, manual_encoded_board)

    def test_encoded_board_length(self):
        # Ensure that the length of the encoded board matches the expected length
        self.board.initialize_board()
        encoded_board = self.encoder.encode_board(self.board, True)
        expected_length = (self.config.get_board_size() + 2) * (4 + self.config.get_pieces_per_player()) + 1
        self.assertEqual(len(encoded_board), expected_length)

if __name__ == "__main__":
    unittest.main()