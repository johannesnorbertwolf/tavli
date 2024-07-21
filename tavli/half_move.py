from tavli.point import Point
from tavli.color import Color

class HalfMove:
    def __init__(self, from_point: Point, to_point: Point, color: Color) -> None:
        """
        Initialize the HalfMove with a starting point, an ending point, and the player's color.
        """
        self.from_point = from_point
        self.to_point = to_point
        self.color = color

    def __str__(self):
        return str(self.from_point.position) + "->" + str(self.to_point.position)

    def __repr__(self):
        return self.__str__()

    def is_valid(self) -> bool:
        """
        Validate the half-move. A half-move is valid if:
        - The starting point contains a checker of the player's color.
        - The ending point is open to the player's color.
        """
        return self.from_point.is_color(self.color) and self.to_point.is_open(self.color)

    def two_checkers_available(self) -> bool:
        """
        Check if there are at least two checkers of the player's color at the starting point.
        """
        return self.from_point.is_double_color(self.color)

    def merge(self, other: 'HalfMove'):
        return HalfMove(self.from_point,other.to_point)

    def can_merge(self, other: 'HalfMove'):
        return self.to_point == other.from_point