import unittest
import numpy as np
from domain.board import Board
from domain.constants import WHITE, BLACK
from config.config_loader import ConfigLoader
from ai.board_encoder import BoardEncoder, LEGACY_V1, UNARY_V2, UNARY_V3

CONFIG_PATH = "config-test.yml"


class TestBoardEncoder(unittest.TestCase):
    def setUp(self):
        self.config = ConfigLoader(CONFIG_PATH)
        self.board = Board.initial(self.config)

    def test_encode_initial_board_legacy_v1(self):
        encoder = BoardEncoder(self.config, version=LEGACY_V1)
        encoded = encoder.encode_board(self.board, is_whites_turn=True)
        self.assertEqual(len(encoded), encoder.input_size)
        self.assertEqual(encoded.dtype, np.float32)

    def test_encode_initial_board_unary_v2(self):
        encoder = BoardEncoder(self.config, version=UNARY_V2)
        encoded = encoder.encode_board(self.board, is_whites_turn=True)
        self.assertEqual(len(encoded), encoder.input_size)

    def test_encode_initial_board_unary_v3(self):
        encoder = BoardEncoder(self.config, version=UNARY_V3)
        encoded = encoder.encode_board(self.board, is_whites_turn=True)
        self.assertEqual(len(encoded), encoder.input_size)

    def test_input_size_legacy_v1(self):
        encoder = BoardEncoder(self.config, version=LEGACY_V1)
        board_size = self.config.get_board_size()
        pieces = self.config.get_pieces_per_player()
        expected = (board_size + 2) * (4 + pieces)
        self.assertEqual(encoder.input_size, expected)

    def test_input_size_unary_v3(self):
        encoder = BoardEncoder(self.config, version=UNARY_V3)
        board_size = self.config.get_board_size()
        pieces = self.config.get_pieces_per_player()
        expected = (board_size + 2) * (3 + pieces) + 18
        self.assertEqual(encoder.input_size, expected)

    def test_perspective_flip(self):
        encoder = BoardEncoder(self.config, version=UNARY_V3)
        encoded_white = encoder.encode_board(self.board, is_whites_turn=True)
        encoded_black = encoder.encode_board(self.board, is_whites_turn=False)
        # Initial position is symmetric; both perspectives should be identical.
        np.testing.assert_array_almost_equal(encoded_white, encoded_black)

    def test_encode_captured_point(self):
        encoder = BoardEncoder(self.config, version=UNARY_V2)
        board = Board.from_config(self.config)
        # Place white at slot 5 with a pinned black below.
        board.set_point(5, WHITE, 2, pinned=True)
        encoded = encoder.encode_board(board, is_whites_turn=True)
        self.assertEqual(encoded.dtype, np.float32)
        # captured_by_us bit should be set at point 5's base offset.
        ps = encoder.point_size
        n = self.config.get_board_size() + 2
        slot = 5  # white's turn: slot == point index
        base = slot * ps
        self.assertEqual(encoded[base + 1], 1.0)  # captured_by_us

    def test_empty_board_all_zeros(self):
        encoder = BoardEncoder(self.config, version=LEGACY_V1)
        board = Board.from_config(self.config)
        encoded = encoder.encode_board(board, is_whites_turn=True)
        np.testing.assert_array_equal(encoded, np.zeros(encoder.input_size, dtype=np.float32))


if __name__ == "__main__":
    unittest.main()
