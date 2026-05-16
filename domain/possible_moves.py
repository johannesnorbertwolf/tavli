from domain.half_move import HalfMove
from domain.move import Move
from domain.board import GameBoard
from domain.color import Color
from domain.dice import Dice, Die
from typing import List

class PaschGenerator:
    def __init__(self, board: GameBoard, color: Color, die: Die) -> None:
        self.board_size = board.board_size
        self.color = color
        self.board = board

        self.die_value = die.value

        if color.is_white():
            self.first_possible_start = 1
            self.last_possible_start = self.board_size - die.value + 2
            self.direction = 1
        else:
            self.first_possible_start = self.board_size
            self.last_possible_start = die.value - 1
            self.direction = -1

        self.die_with_direction = self.die_value * self.direction
        self.movable_pieces: dict[int, int] = {i: board.points[i].get_number_of_movable_pieces(color) for i in range(0, self.board_size + 2)}
        self.open_points: dict[int, bool] = {i: board.points[i].is_open(color) for i in range(0, self.board_size + 2)}
        self.outside_home_count = board.count_checkers_outside_home(color)

    def find_moves(self):
        possible_moves: List[Move] = []
        second_is_possible = False
        third_is_possible = False
        fourth_is_possible = False
        for first in range(self.first_possible_start, self.last_possible_start, self.direction):
            if not self.can_move_from(first, self.outside_home_count):
                continue
            outside_after_first = self.outside_home_count + self.get_outside_home_delta(first)
            self.movable_pieces[first] -= 1
            self.movable_pieces[first + self.die_with_direction] += 1

            for second in range(first, self.last_possible_start, self.direction):
                if not self.can_move_from(second, outside_after_first):
                    continue
                second_is_possible = True
                outside_after_second = outside_after_first + self.get_outside_home_delta(second)
                self.movable_pieces[second] -= 1
                self.movable_pieces[second + self.die_with_direction] += 1

                for third in range(second, self.last_possible_start, self.direction):
                    if not self.can_move_from(third, outside_after_second):
                        continue
                    third_is_possible = True
                    outside_after_third = outside_after_second + self.get_outside_home_delta(third)
                    self.movable_pieces[third] -= 1
                    self.movable_pieces[third + self.die_with_direction] += 1

                    for fourth in range(third, self.last_possible_start, self.direction):
                        if not self.can_move_from(fourth, outside_after_third):
                            continue
                        fourth_is_possible = True

                        possible_moves.append(Move([HalfMove(self.board.points[start], self.board.points[start + self.die_with_direction], self.color) for start in [first, second, third, fourth] ]))

                    if not fourth_is_possible:
                        possible_moves.append(Move([HalfMove(self.board.points[start], self.board.points[start + self.die_with_direction], self.color) for start in [first, second, third] ]))
                    self.movable_pieces[third] += 1
                    self.movable_pieces[third + self.die_with_direction] -= 1

                if not third_is_possible:
                    possible_moves.append(Move([HalfMove(self.board.points[start], self.board.points[start + self.die_with_direction], self.color) for start in [first, second]]))
                self.movable_pieces[second] += 1
                self.movable_pieces[second + self.die_with_direction] -= 1

            if not second_is_possible:
                possible_moves.append(Move([HalfMove(self.board.points[first], self.board.points[first + self.die_with_direction], self.color)]))
            self.movable_pieces[first] += 1
            self.movable_pieces[first + self.die_with_direction] -= 1

        return possible_moves

    def can_move_from(self, point_index: int, outside_home_count: int):
        destination = point_index + self.die_with_direction
        if self.is_off_board(destination) and outside_home_count > 0:
            return False
        return self.movable_pieces[point_index] > 0 and self.open_points[destination]

    def is_off_board(self, point_index: int) -> bool:
        return point_index == 0 or point_index == self.board_size + 1

    def get_outside_home_delta(self, from_point_index: int) -> int:
        to_point_index = from_point_index + self.die_with_direction
        if self.board.is_home_point(self.color, from_point_index):
            return 0
        if self.board.is_home_point(self.color, to_point_index) or self.is_off_board(to_point_index):
            return -1
        return 0

class PossibleMoves:
    def __init__(self, board: GameBoard, color: Color, dice: Dice) -> None:
        self.board = board
        self.color = color
        self.dice = dice

    def find_moves(self) -> List[Move]:
        possible_moves = []
        outside_home_count = self.board.count_checkers_outside_home(self.color)

        if self.dice.is_pasch():
            pasch_generator = PaschGenerator(self.board, self.color, self.dice.die1)
            return pasch_generator.find_moves()

        else:
            half_moves1 = self.generate_half_moves(self.dice.die1.value)
            half_moves2 = self.generate_half_moves(self.dice.die2.value)

            for half_move1 in half_moves1:
                if not half_move1.is_valid():
                    continue

                for half_move2 in half_moves2:
                    if not half_move2.is_valid():
                        continue
                    if half_move1.can_merge_or_vice_versa(half_move2):
                        # Merged moves are handled separately.
                        continue
                    if not self.is_two_half_move_sequence_legal(half_move1, half_move2, outside_home_count):
                        continue
                    if half_move1.from_point == half_move2.from_point:
                        if half_move1.two_checkers_available():
                            possible_moves.append(Move([half_move1, half_move2]))
                        continue

                    possible_moves.append(Move([half_move1, half_move2]))

            merged_half_moves = self.generate_half_moves(self.dice.die1.value + self.dice.die2.value)

            for half_move in merged_half_moves:
                if not half_move.is_valid():
                    continue
                middle_step1_index = half_move.from_point.position + self.dice.die1.value if self.color.is_white() else half_move.from_point.position - self.dice.die1.value
                middle_step2_index = half_move.from_point.position + self.dice.die2.value if self.color.is_white() else half_move.from_point.position - self.dice.die2.value
                middle_step1 = self.board.points[middle_step1_index]
                middle_step2 = self.board.points[middle_step2_index]

                if not (middle_step1.is_open(self.color) or middle_step2.is_open(self.color)):
                    continue
                if not self.is_merged_half_move_legal_with_home_rule(half_move, outside_home_count, middle_step1_index, middle_step2_index):
                    continue
                possible_moves.append(Move([half_move]))

            self._emit_single_die_moves(possible_moves, half_moves1, self.dice.die2.value, outside_home_count)
            self._emit_single_die_moves(possible_moves, half_moves2, self.dice.die1.value, outside_home_count)

        return possible_moves

    def _emit_single_die_moves(
        self,
        possible_moves: List[Move],
        half_moves: List[HalfMove],
        other_die_value: int,
        outside_home_count: int,
    ) -> None:
        """Emit Move([hm]) for each individually-valid hm whose application leaves the
        other die with no legal half-move on the resulting board. Implements the
        Plakoto rule that the player chooses which die to play first; if doing so
        makes the other die unplayable, the turn ends with one die played."""
        for hm in half_moves:
            if not hm.is_valid():
                continue
            if not self.is_half_move_legal_with_home_rule(hm, outside_home_count):
                continue
            self.board.apply_half_move(hm)
            new_outside = outside_home_count + self.get_outside_home_delta(hm)
            other_hms = self.generate_half_moves(other_die_value)
            has_legal_other = any(
                other_hm.is_valid() and self.is_half_move_legal_with_home_rule(other_hm, new_outside)
                for other_hm in other_hms
            )
            self.board.undo_half_move(hm)
            if not has_legal_other:
                possible_moves.append(Move([hm]))

    def generate_half_moves(self, die_value: int) -> List[HalfMove]:
        from_range = self.get_from_range(die_value)
        return [self.create_half_move(from_point_index, die_value) for from_point_index in from_range]

    def get_from_range(self, die_value: int) -> List[int]:
        board_size = self.board.config.get_board_size()
        return list(range(1, board_size + 2 - die_value) if self.color.is_white() else range(0 + die_value, board_size + 1))


    def create_half_move(self, from_point_index: int, die_value: int) -> HalfMove:
        to_point_index = from_point_index + die_value if self.color.is_white() else from_point_index - die_value
        from_point = self.board.points[from_point_index]
        to_point = self.board.points[to_point_index]
        return HalfMove(from_point, to_point, self.color)

    def is_bear_off_move(self, half_move: HalfMove) -> bool:
        destination = half_move.to_point.position
        return destination == 0 or destination == self.board.board_size + 1

    def get_outside_home_delta(self, half_move: HalfMove) -> int:
        from_position = half_move.from_point.position
        to_position = half_move.to_point.position
        if self.board.is_home_point(self.color, from_position):
            return 0
        if self.board.is_home_point(self.color, to_position) or self.is_off_board_position(to_position):
            return -1
        return 0

    def is_off_board_position(self, position: int) -> bool:
        return position == 0 or position == self.board.board_size + 1

    def is_half_move_legal_with_home_rule(self, half_move: HalfMove, outside_home_count: int) -> bool:
        return not self.is_bear_off_move(half_move) or outside_home_count == 0

    def is_two_half_move_sequence_legal(self, first: HalfMove, second: HalfMove, outside_home_count: int) -> bool:
        if self.is_sequence_legal_in_order(first, second, outside_home_count):
            return True
        return self.is_sequence_legal_in_order(second, first, outside_home_count)

    def is_sequence_legal_in_order(self, first: HalfMove, second: HalfMove, outside_home_count: int) -> bool:
        if not self.is_half_move_legal_with_home_rule(first, outside_home_count):
            return False
        updated_outside_count = outside_home_count + self.get_outside_home_delta(first)
        return self.is_half_move_legal_with_home_rule(second, updated_outside_count)

    def is_merged_half_move_legal_with_home_rule(
        self,
        merged_half_move: HalfMove,
        outside_home_count: int,
        middle_step1_index: int,
        middle_step2_index: int
    ) -> bool:
        if not self.is_bear_off_move(merged_half_move):
            return True
        if outside_home_count == 0:
            return True

        from_position = merged_half_move.from_point.position
        to_position = merged_half_move.to_point.position
        if self.is_sequence_legal_by_positions(from_position, middle_step1_index, to_position, outside_home_count):
            return True
        return self.is_sequence_legal_by_positions(from_position, middle_step2_index, to_position, outside_home_count)

    def is_sequence_legal_by_positions(
        self,
        from_position: int,
        middle_position: int,
        to_position: int,
        outside_home_count: int
    ) -> bool:
        first = HalfMove(self.board.points[from_position], self.board.points[middle_position], self.color)
        second = HalfMove(self.board.points[middle_position], self.board.points[to_position], self.color)
        return self.is_sequence_legal_in_order(first, second, outside_home_count)
