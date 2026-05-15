from domain.point import Point
from domain.color import Color

class HalfMove:
    def __init__(self, from_point: Point, to_point: Point, color: Color) -> None:
        self.from_point = from_point
        self.to_point = to_point
        self.color = color

    def __str__(self):
        return str(self.from_point.position) + "->" + str(self.to_point.position)

    def __repr__(self):
        return self.__str__()

    def is_valid(self) -> bool:
        return self.from_point.is_color(self.color) and self.to_point.is_open(self.color)

    def two_checkers_available(self) -> bool:
        return self.from_point.is_double_color(self.color)

    def merge(self, other: 'HalfMove'):
        return HalfMove(self.from_point, other.to_point, self.color)

    def can_merge(self, other: 'HalfMove'):
        return self.to_point == other.from_point

    def can_merge_or_vice_versa(self, other: 'HalfMove'):
        return self.can_merge(other) or other.can_merge(self)


