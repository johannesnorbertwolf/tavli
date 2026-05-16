from domain.point import Point
from domain.color import Color
from domain.move import Move
from domain.half_move import HalfMove
from config.config_loader import ConfigLoader
from typing import Dict


class GameBoard:
    def __init__(self, config: ConfigLoader):
        self.config = config
        self.board_size = config.get_board_size()
        self.home_size = config.get_home_size()
        self.number_of_pieces = self.config.get_pieces_per_player()
        self.points: Dict[int, Point] = {i: Point(i) for i in range(0, self.board_size + 2)}  # 1 to 24 points plus two

    def __str__(self):
        white_home_start = self.board_size - self.home_size + 1
        black_home_start = self.home_size
        # Render separators between points, so home boundaries are one step before
        # the first home point in the descending board printout.
        # White moves upward (line before white_home_start - 1), Black moves
        # downward (line before black_home_start).
        white_home_boundary = white_home_start - 1
        black_home_boundary = black_home_start
        boundary_points = {self.board_size, white_home_boundary, black_home_boundary, 0}
        lines = []
        for i in range(self.board_size + 1, -1, -1):
            if i in boundary_points:
                lines.append("--------------------")
            lines.append(str(self.points[i]))
        return "\n".join(lines)

    def __repr__(self):
        return self.__str__()

    def initialize_board(self):
        self.points[1] = Point(1, Color.WHITE, self.number_of_pieces)
        self.points[self.board_size] = Point(self.board_size, Color.BLACK, self.number_of_pieces)

    def apply(self, move: Move):
        for half_move in move.half_moves:
            self.apply_half_move(half_move)


    def undo(self, move: Move):
        for half_move in move.half_moves[::-1]:
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

    def is_home_point(self, color: Color, point_index: int) -> bool:
        if color.is_white():
            return self.board_size - self.home_size + 1 <= point_index <= self.board_size
        return 1 <= point_index <= self.home_size

    def count_checkers_outside_home(self, color: Color) -> int:
        outside = 0
        for point_index in range(1, self.board_size + 1):
            if not self.is_home_point(color, point_index):
                outside += self.points[point_index].get_count_for_color(color)
        return outside

    def all_checkers_in_home(self, color: Color) -> bool:
        return self.count_checkers_outside_home(color) == 0
