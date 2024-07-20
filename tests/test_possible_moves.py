import unittest
from tavli.board import GameBoard
from tavli.player import Player
from tavli.possible_moves import PossibleMoves

class TestPossibleMoves(unittest.TestCase):
    def setUp(self):
        self.board = GameBoard()
        self.board.initialize_board()
        self.player_white = Player(name="Player1", color="W")
        self.player_black = Player(name="Player2", color="B")

    def test_possible_moves_white(self):
        # Mocking a dice roll of (1, 2)
        dice_roll = (1, 2)
        possible_moves_white = PossibleMoves(self.board, self.player_white, dice_roll).find_moves()
        expected_moves_white = [(24, 23), (24, 22)]
        
        self.assertCountEqual(possible_moves_white, expected_moves_white)

    def test_possible_moves_black(self):
        # Mocking a dice roll of (1, 2)
        dice_roll = (1, 2)
        possible_moves_black = PossibleMoves(self.board, self.player_black, dice_roll).find_moves()
        expected_moves_black = [(24, 23), (24, 22)]
        
        self.assertCountEqual(possible_moves_black, expected_moves_black)

    def test_no_moves(self):
        # Mocking a dice roll where no moves should be possible
        self.board.points[24] = []  # Removing all white checkers from 24
        dice_roll = (1, 2)
        possible_moves_white = PossibleMoves(self.board, self.player_white, dice_roll).find_moves()
        
        self.assertEqual(possible_moves_white, [])

    def test_blocked_moves(self):
        # Mocking a scenario where white checkers are blocked by black checkers
        self.board.points[23] = ['B', 'B']
        self.board.points[22] = ['B', 'B']
        dice_roll = (1, 2)
        possible_moves_white = PossibleMoves(self.board, self.player_white, dice_roll).find_moves()
        
        self.assertEqual(possible_moves_white, [])

if __name__ == '__main__':
    unittest.main()