from typing import Optional
from domain.color import Color


class Point:
    def __init__(self, position: int, color: Color = Color.WHITE, count: int = 0) -> None:
        # Handle single constructor signature with default arguments
        self.position = position
        self.pieces: list[color] = [color] * count if count else []

    def __eq__(self, other: 'Point') -> bool:
        return self.position == other.position

    def __str__(self):
        if self.position < 10:
            result = " "
        else:
            result = ""

        result += str(self.position) + ": "
        for piece in self.pieces:
            if piece.is_white():
                result += "O"
            else:
                result += "X"
        return result

    def __repr__(self):
        return self.__str__()

    def __len__(self):
        return len(self.pieces)

    def pop(self) -> None:
        if self.pieces:
            self.pieces.pop()


    def push(self, color: Color) -> None:
        self.pieces.append(color)

    def is_color(self, color: Color) -> bool:
        return self.get_color() == color

    def is_white(self):
        return self.is_color(Color.WHITE)

    def get_color(self) -> Optional[Color]:
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

    def is_captured_by(self, color: Color) -> bool:
        return len(self.pieces) > 1 and self.pieces[0] != color and self.pieces[1] == color

    def is_captured(self) -> bool:
        return len(self.pieces) > 1 and self.pieces[0] != self.pieces[1]

    def get_count(self) -> int:
        if self.is_captured():
            return len(self.pieces) - 1
        return len(self.pieces)

    def get_number_of_movable_pieces(self, color: Color) -> int:
        if not self.is_color(color):
            return 0
        return self.get_count()
