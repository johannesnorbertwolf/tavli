import unittest
from tavli.board import GameBoard

class TestGameBoard(unittest.TestCase):
    def setUp(self):
        self.board = GameBoard()
        self.board.initialize_board()

    def test_initial_setup(self):
        self.assertEqual(len(self.board.points[24]), 15)
        self.assertEqual(self.board.points[24], ['W'] * 15)
        self.assertEqual(len(self.board.points[1]), 15)
        self.assertEqual(self.board.points[1], ['B'] * 15)

    def test_move_checker(self):
        self.board.move_checker(24, 23)
        self.assertEqual(len(self.board.points[24]), 14)
        self.assertEqual(len(self.board.points[23]), 1)
        self.assertEqual(self.board.points[23][0], 'W')

    def test_string(self):
        actual = str(self.board)
        expected = """24: OOOOOOOOOOOOOOO
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
1: XXXXXXXXXXXXXXX"""
        self.assertEqual(actual, expected)

if __name__ == '__main__':
    unittest.main()