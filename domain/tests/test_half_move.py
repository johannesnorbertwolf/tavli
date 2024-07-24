import unittest
from domain.tavli.point import Point
from domain.tavli.color import Color
from domain.tavli.half_move import HalfMove

class TestHalfMove(unittest.TestCase):
    def setUp(self) -> None:
        self.from_point = Point(1, Color.WHITE, 2)
        self.to_point = Point(2)

    def test_valid_half_move(self) -> None:
        half_move = HalfMove(self.from_point, self.to_point, color=Color.WHITE)
        self.assertTrue(half_move.is_valid())

    def test_invalid_half_move_wrong_color(self) -> None:
        self.from_point = Point(1, Color.BLACK, 2)
        half_move = HalfMove(self.from_point, self.to_point, color=Color.WHITE)
        self.assertFalse(half_move.is_valid())

    def test_invalid_half_move_to_point_not_open(self) -> None:
        self.to_point = Point(2, Color.BLACK, 2)  # Not open for WHITE if there are 2 BLACK checkers
        half_move = HalfMove(self.from_point, self.to_point, color=Color.WHITE)
        self.assertFalse(half_move.is_valid())

    def test_two_checkers_available(self) -> None:
        half_move = HalfMove(self.from_point, self.to_point, color=Color.WHITE)
        self.assertTrue(half_move.two_checkers_available())

    def test_not_two_checkers_available(self) -> None:
        self.from_point = Point(1, Color.WHITE, 1)  # Only one checker
        half_move = HalfMove(self.from_point, self.to_point, color=Color.WHITE)
        self.assertFalse(half_move.two_checkers_available())

if __name__ == '__main__':
    unittest.main()