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