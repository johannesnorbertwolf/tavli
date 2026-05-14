import unittest
from pathlib import Path
from domain.board import GameBoard
from domain.point import Point
from domain.color import Color
from config.config_loader import ConfigLoader


class TestGameBoard(unittest.TestCase):
    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        config = ConfigLoader(str(config_path))
        self.board = GameBoard(config)
        self.board.initialize_board()

    def test_initial_setup(self):
        self.assertEqual(len(self.board.points[24]), 15)
        self.assertEqual(self.board.points[24].is_white(), False)
        self.assertEqual(len(self.board.points[1]), 15)
        self.assertEqual(self.board.points[1].is_white(), True)

    def test_string(self):
        actual = str(self.board)
        expected = """25: 
--------------------
24: XXXXXXXXXXXXXXX
23: 
22: 
21: 
20: 
19: 
--------------------
18: 
17: 
16: 
15: 
14: 
13: 
12: 
11: 
10: 
 9: 
 8: 
 7: 
--------------------
 6: 
 5: 
 4: 
 3: 
 2: 
 1: OOOOOOOOOOOOOOO
--------------------
 0: """
        self.assertEqual(actual, expected)

    def test_white_wins_by_bearing_off(self):
        board_size = self.board.board_size
        pieces = self.board.number_of_pieces
        for i in range(0, board_size + 2):
            self.board.points[i] = Point(i)
        self.board.points[board_size + 1] = Point(board_size + 1, Color.WHITE, pieces)
        self.assertTrue(self.board.has_won(Color.WHITE))
        self.assertFalse(self.board.has_won(Color.BLACK))

    def test_black_wins_by_bearing_off(self):
        board_size = self.board.board_size
        pieces = self.board.number_of_pieces
        for i in range(0, board_size + 2):
            self.board.points[i] = Point(i)
        self.board.points[0] = Point(0, Color.BLACK, pieces)
        self.assertTrue(self.board.has_won(Color.BLACK))
        self.assertFalse(self.board.has_won(Color.WHITE))

    def test_white_wins_by_capturing_start(self):
        board_size = self.board.board_size
        # Black starting point captured by white: [Black, White]
        self.board.points[board_size] = Point(board_size, Color.BLACK, 1)
        self.board.points[board_size].push(Color.WHITE)
        self.assertTrue(self.board.has_won(Color.WHITE))

if __name__ == '__main__':
    unittest.main()
