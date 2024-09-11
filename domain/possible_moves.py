from domain.half_move import HalfMove
from domain.move import Move
from domain.board import GameBoard
from domain.color import Color
from domain.dice import Dice, Die
from typing import List

class PaschGenerator:
    def __init__(self, board: GameBoard, color: Color, die: Die) -> None:
        # TODO: use config for board_size
        self.board_size = 10
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

    def find_moves(self):
        possible_moves: List[Move] = []
        second_is_possible = False
        third_is_possible = False
        fourth_is_possible = False
        for first in range(self.first_possible_start, self.last_possible_start, self.direction):
            if not self.can_move_from(first):
                continue
            self.movable_pieces[first] -= 1
            self.movable_pieces[first + self.die_with_direction] += 1

            for second in range(first, self.last_possible_start, self.direction):
                if not self.can_move_from(second):
                    continue
                second_is_possible = True
                self.movable_pieces[second] -= 1
                self.movable_pieces[second + self.die_with_direction] += 1

                for third in range(second, self.last_possible_start, self.direction):
                    if not self.can_move_from(third):
                        continue
                    third_is_possible = True
                    self.movable_pieces[third] -= 1
                    self.movable_pieces[third + self.die_with_direction] += 1

                    for fourth in range(third, self.last_possible_start, self.direction):
                        if not self.can_move_from(fourth):
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

    def can_move_from(self, point_index: int):
        return self.movable_pieces[point_index] > 0 and self.open_points[point_index + self.die_with_direction]

class PossibleMoves:
    def __init__(self, board: GameBoard, color: Color, dice: Dice) -> None:
        self.board = board
        self.color = color
        self.dice = dice

    def find_moves(self) -> List[Move]:
        possible_moves = []

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

                if middle_step1.is_open(self.color) or middle_step2.is_open(self.color):
                    possible_moves.append(Move([half_move]))

        if len(possible_moves) == 0:
            for half_move in half_moves1 + half_moves2:
                if half_move.is_valid():
                    possible_moves.append(Move([half_move]))

        return possible_moves

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
