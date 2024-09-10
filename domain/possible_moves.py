from domain.half_move import HalfMove
from domain.move import Move
from domain.board import GameBoard
from domain.color import Color
from domain.dice import Dice, Die
from typing import List

class PossibleMoves:
    def __init__(self, board: GameBoard, color: Color, dice: Dice) -> None:
        self.board = board
        self.color = color
        self.dice = dice

    def find_moves(self) -> List[Move]:
        possible_moves = []


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
