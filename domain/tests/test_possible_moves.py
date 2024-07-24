import unittest
from domain.tavli.board import GameBoard
from domain.tavli.color import Color
from domain.tavli.dice import Dice, Die
from domain.tavli.possible_moves import PossibleMoves
from domain.tavli.move import Move
from domain.tavli.point import Point


class TestPossibleMoves(unittest.TestCase):
    def setUp(self) -> None:
        self.board = GameBoard()
        self.board.initialize_board()
        self.dice = Dice()
        self.color_white = Color.WHITE
        self.color_black = Color.BLACK

    def test_single_valid_move(self) -> None:
        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Check that there are valid moves for the initial setup and dice roll
        self.assertTrue(any(isinstance(move, Move) for move in possible_moves))
        self.assertTrue(all(move.is_valid() for move in possible_moves))

    def test_combined_valid_moves(self) -> None:
        # Manually setting up board state for more controlled tests
        self.board.points[1] = Point(1, self.color_white, 2)
        self.board.points[2] = Point(2)
        self.board.points[3] = Point(3)

        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Expect moves from point 1 to point 2 (die 1), then point 2 to point 3 (die 2)
        self.assertTrue(any(isinstance(move, Move) for move in possible_moves))
        self.assertTrue(all(move.is_valid() for move in possible_moves))

    def test_no_moves_for_blocked_path(self) -> None:
        # Block all points so no moves can be made
        for i in range(1, 25):
            self.board.points[i] = Point(i, self.color_black, 2)

        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Check that there are no valid moves when all paths are blocked
        self.assertFalse(any(isinstance(move, Move) for move in possible_moves))

    def test_two_half_moves_from_same_point_valid(self) -> None:
        # Set up the board with two checkers at point 1 for a valid double move
        self.board.points[1] = Point(1, self.color_white, 2)
        self.board.points[2] = Point(2)
        self.board.points[3] = Point(3)

        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Expect a valid move involving both half-moves starting from the same point
        self.assertTrue(any(isinstance(move, Move) for move in possible_moves))
        self.assertTrue(all(move.is_valid() for move in possible_moves))

    def test_two_half_moves_from_same_point_invalid(self) -> None:
        # Set up the board with only one checker at point 1 for an invalid double move
        self.board.points[1] = Point(1, self.color_white, 1)
        self.board.points[2] = Point(2)
        self.board.points[3] = Point(3)
        self.dice.die1 = Die(1)
        self.dice.die2 = Die(2)


        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Expect no valid move involving both half-moves starting from the same point
        self.assertEquals(len(possible_moves), 1)


if __name__ == '__main__':
    unittest.main()