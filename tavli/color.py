from enum import Enum


class Color(Enum):
    WHITE = "W"
    BLACK = "B"

    def is_white(self):
        return self == Color.WHITE
