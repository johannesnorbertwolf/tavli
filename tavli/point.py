from typing import Optional
from tavli.color import Color


class Point:
    def __init__(self, position: int, color: Optional[Color] = None, number: int = 0) -> None:
        # Handle single constructor signature with default arguments
        self.position = position
        self.pieces: list[color] = [color] * number if number else []

    def __eq__(self, other: 'Point') -> bool:
        return self.position == other.position

    def __str__(self):
        result = str(self.position) + ": "
        for piece in self.pieces:
            if piece.is_white():
                result += "O"
            else:
                result += "X"
        return result

    def __repr__(self):
        return self.__str__()

    def __repr__(self):
        return self.__str__()

    def pop(self) -> None:
        if self.pieces:
            self.pieces.pop()

    def push(self, color: Color) -> None:
        self.pieces.append(color)

    def is_color(self, color: Color) -> bool:
        return self.color() == color

    def color(self) -> Optional[Color]:
        if self.is_empty():
            return None
        return self.pieces[-1]  # Check the last element

    def is_catchable(self) -> bool:
        return len(self.pieces) == 1

    def is_empty(self) -> bool:
        return not self.pieces

    def is_open(self, color: Color) -> bool:
        return self.is_empty() or self.is_color(color) or self.is_catchable()

    def is_double_color(self, color: Color) -> bool:
        return len(self.pieces) > 1 and self.pieces[-1] == self.pieces[-2] == color
