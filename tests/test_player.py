import unittest
from tavli.board import GameBoard
from tavli.player import Player

class TestPlayer(unittest.TestCase):
    def setUp(self):
        self.board = GameBoard()
        self.board.initialize_board()
        self.player_white = Player(name="Player1", color="W")
        self.player_black = Player(name="Player2", color="B")

    def test_initialization(self):
        self.assertEqual(self.player_white.name, "Player1")
        self.assertEqual(self.player_white.color, "W")
        self.assertEqual(self.player_black.name, "Player2")
        self.assertEqual(self.player_black.color, "B")

    def test_valid_move(self):
        # Move a white checker from 24 to 23
        self.player_white.make_move(self.board, 24, 23)
        self.assertEqual(len(self.board.points[24]), 14)
        self.assertEqual(len(self.board.points[23]), 1)
        self.assertEqual(self.board.points[23][0], 'W')

    def test_invalid_move(self):
        # Attempt to move a white checker from 24 to a blocked point 1
        self.board.points[1] = ['B'] * 2  # Block point 1 with two black checkers
        self.player_white.make_move(self.board, 24, 1)
        self.assertEqual(len(self.board.points[24]), 15)  # Move should not occur
        self.assertEqual(len(self.board.points[1]), 2)  # Point 1 remains blocked

    def test_can_move(self):
        # Test that a player can move to an open point
        self.assertTrue(self.player_white.can_move(self.board, 24, 23))
        # Test that a player cannot move to a blocked point
        self.board.points[1] = ['B'] * 2
        self.assertFalse(self.player_white.can_move(self.board, 24, 1))

if __name__ == '__main__':
    unittest.main()