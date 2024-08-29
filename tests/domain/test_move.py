import unittest
from domain.tavli.point import Point
from domain.tavli.color import Color
from domain.tavli.half_move import HalfMove
from domain.tavli.move import Move

class TestMove(unittest.TestCase):
    def setUp(self) -> None:
        self.from_point1 = Point(1, Color.WHITE, 2)
        self.to_point1 = Point(2)
        self.from_point2 = self.to_point1  # The second move starts where the first one ended
        self.to_point2 = Point(3)

    def test_single_valid_half_move(self) -> None:
        half_move = HalfMove(self.from_point1, self.to_point1, color=Color.WHITE)
        move = Move([half_move])
        self.assertTrue(move.is_valid())

    def test_single_invalid_half_move(self) -> None:
        half_move = HalfMove(self.from_point1, self.to_point1, color=Color.BLACK)
        move = Move([half_move])
        self.assertFalse(move.is_valid())

    def test_two_invalid_half_moves(self) -> None:
        half_move1 = HalfMove(self.from_point1, self.to_point1, color=Color.WHITE)
        half_move2 = HalfMove(self.from_point2, self.to_point2, color=Color.BLACK)
        move = Move([half_move1, half_move2])
        self.assertFalse(move.is_valid())

    def test_two_half_moves_same_from_point_valid(self) -> None:
        from_point = Point(1, Color.WHITE, 2)
        to_point1 = Point(2)
        to_point2 = Point(3)
        half_move1 = HalfMove(from_point, to_point1, color=Color.WHITE)
        half_move2 = HalfMove(from_point, to_point2, color=Color.WHITE)
        move = Move([half_move1, half_move2])
        self.assertTrue(move.is_valid())

    def test_two_half_moves_same_from_point_invalid(self) -> None:
        from_point = Point(1, Color.WHITE, 1)
        to_point1 = Point(2)
        to_point2 = Point(3)
        half_move1 = HalfMove(from_point, to_point1, color=Color.WHITE)
        half_move2 = HalfMove(from_point, to_point2, color=Color.WHITE)
        move = Move([half_move1, half_move2])
        self.assertFalse(move.is_valid())

if __name__ == '__main__':
    unittest.main()