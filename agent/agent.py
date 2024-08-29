from domain.tavli.half_move import HalfMove
from domain.tavli.move import Move
from domain.tavli.board import GameBoard
from domain.tavli.color import Color
from domain.tavli.dice import Dice, Die
from typing import List

class PossibleMoves:
    def __init__(self, board: GameBoard, color: Color, dice: Dice) -> None:
        self.board = board
        self.color = color
        self.dice = dice

    def find_moves(self) -> List[Move]:
        possible_moves = []

        half_moves1 = self.generate_half_moves(self.dice.die1)
        half_moves2 = self.generate_half_moves(self.dice.die2)

        for half_move1 in half_moves1:
            if not half_move1.is_valid():
                continue

            for half_move2 in half_moves2:
                if not half_move2.is_valid():
                    if half_move1.can_merge(half_move2):
                        # Note: we allow stepping over a blocked piece here! Must be dealt with when this is not a poc anymore.
                        merged_half_move = half_move1.merge(half_move2)
                        if merged_half_move.is_valid():
                            possible_moves.append(Move([merged_half_move]))
                    continue

                if half_move1.from_point == half_move2.from_point:
                    if not half_move1.two_checkers_available():
                        continue
                    possible_moves.append(Move([half_move1, half_move2]))

                possible_moves.append(Move([half_move1, half_move2]))

        if len(possible_moves) == 0:
            for half_move in half_moves1 + half_moves2:
                if half_move.is_valid():
                    possible_moves.append(Move([half_move]))

        return possible_moves

    def generate_half_moves(self, die: Die) -> List[HalfMove]:
        from_range = self.get_from_range(die)
        return [self.create_half_move(from_point_index, die) for from_point_index in from_range]

    def get_from_range(self, die: Die) -> List[int]:
        board_size = self.board.config.get_board_size()
        return list(range(1, board_size + 2 - die.value) if self.color.is_white() else range(0 + die.value, board_size + 1))


    def create_half_move(self, from_point_index: int, die: Die) -> HalfMove:
        to_point_index = from_point_index + die.value if self.color.is_white() else from_point_index - die.value
        from_point = self.board.points[from_point_index]
        to_point = self.board.points[to_point_index]
        return HalfMove(from_point, to_point, self.color)
