import unittest
from tavli.board import GameBoard
from tavli.color import Color

class TestGameBoard(unittest.TestCase):
    def setUp(self):
        self.board = GameBoard()
        self.board.initialize_board()

    def test_initial_setup(self):
        self.assertEqual(len(self.board.points[24]), 15)
        self.assertEqual(self.board.points[24].is_white(), False)
        self.assertEqual(len(self.board.points[1]), 15)
        self.assertEqual(self.board.points[1].is_white(), True)

    def test_string(self):
        actual = str(self.board)
        expected = """25: 
24: XXXXXXXXXXXXXXX
23: 
22: 
21: 
20: 
19: 
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
6: 
5: 
4: 
3: 
2: 
1: OOOOOOOOOOOOOOO
0: """
        self.assertEqual(actual, expected)

if __name__ == '__main__':
    unittest.main()