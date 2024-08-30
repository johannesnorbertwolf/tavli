from domain.tavli.point import Point
from domain.tavli.color import Color
from domain.tavli.move import Move
from domain.tavli.half_move import HalfMove
from config.config_loader import ConfigLoader
from typing import Dict


class GameBoard:
    def __init__(self, config: ConfigLoader):
        self.config = config
        self.board_size = config.get_board_size()
        self.number_of_pieces = self.config.get_pieces_per_player()
        self.points: Dict[int, Point] = {i: Point(i) for i in range(0, self.board_size + 2)}  # 1 to 24 points plus two

    def __str__(self):
        lines = [str(self.points[i]) for i in range(self.board_size + 1, -1, -1)]
        return "\n".join(lines)

    def __repr__(self):
        return self.__str__()

    def initialize_board(self):
        self.points[1] = Point(1, Color.WHITE, self.number_of_pieces)
        self.points[self.board_size] = Point(self.board_size, Color.BLACK, self.number_of_pieces)

    def move_checker(self, from_point, to_point):
        if self.is_point_open(to_point) or (
                len(self.points[to_point]) == 1 and self.points[to_point][0] != self.points[from_point][0]):
            checker = self.points[from_point].pop()
            self.points[to_point].append(checker)

    def apply(self, move: Move):
        for half_move in move.half_moves:
            self.apply_half_move(half_move)

    def undo(self, move: Move):
        for half_move in move.half_moves:
            self.undo_half_move(half_move)

    def apply_half_move(self, half_move: HalfMove):
        half_move.from_point.pop()
        half_move.to_point.push(half_move.color)

    def undo_half_move(self, half_move: HalfMove):
        half_move.to_point.pop()
        half_move.from_point.push(half_move.color)

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
        return self.all_players_in_goal(color) or self.captured_starting_position(color)

    def all_players_in_goal(self, color: Color):
        if color.is_white():
            return len(self.points[self.board_size + 1]) == self.number_of_pieces
        else:
            return len(self.points[0]) == self.number_of_pieces

    def captured_starting_position(self, color: Color):
        if color.is_white():
            black_starting_point = self.points[self.board_size]
            return black_starting_point.is_captured_by(color.WHITE)
        else:
            white_starting_point = self.points[1]
            return white_starting_point.is_captured_by(color.BLACK)


