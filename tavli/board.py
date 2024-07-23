from tavli.point import Point
from tavli.color import Color
from tavli.move import Move
from tavli.half_move import HalfMove

class GameBoard:
    def __init__(self):
        self.points = {i: Point(i) for i in range(0, 26)}  # 1 to 24 points plus two

    def __str__(self):
        lines = [str(self.points[i]) for i in range(25, -1, -1)]
        return "\n".join(lines)

    def __repr__(self):
        return self.__str__()

    def initialize_board(self):
        self.points[1] = Point(1, Color.WHITE, 15)
        self.points[24] = Point(24, Color.BLACK, 15)

    def move_checker(self, from_point, to_point):
        if self.is_point_open(to_point) or (
                len(self.points[to_point]) == 1 and self.points[to_point][0] != self.points[from_point][0]):
            checker = self.points[from_point].pop()
            self.points[to_point].append(checker)

    def apply(self, move: Move):
        for half_move in move.half_moves:
            self.apply_half_move(half_move)

    def apply_half_move(self, half_move: HalfMove):
        half_move.from_point.pop()
        half_move.to_point.push(half_move.color)

    def is_point_open(self, point):
        return len(self.points[point]) == 0 or (
                    len(self.points[point]) == 1 and self.points[point][0] == self.points[point][0])

    def pin_checker(self, from_point, to_point):
        if len(self.points[to_point]) == 1 and self.points[to_point][0] != self.points[from_point][0]:
            self.points[to_point] = [self.points[from_point].pop()]

    def release_pinned_checker(self, point):
        if len(self.points[point]) == 1:
            return self.points[point].pop()
        return None

    def has_won(self, color: Color):
        if color == Color.WHITE:
            return len(self.points[25]) == 15
        else:
            return len(self.points[0]) == 15
