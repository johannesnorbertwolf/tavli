from tavli.half_move import HalfMove
from tavli.move import Move
from tavli.board import GameBoard
from tavli.color import Color
from tavli.dice import Dice, Die
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
                    continue

                if half_move1.from_point == half_move2.from_point:
                    if not half_move1.two_checkers_available():
                        continue

                possible_moves.append(Move([half_move1, half_move2]))

        return possible_moves

    def generate_half_moves(self, die: Die) -> List[HalfMove]:
        from_range = self.get_from_range(die)
        return [self.create_half_move(from_point_index, die) for from_point_index in from_range]

    def get_from_range(self, die: Die) -> List[int]:
        return list(range(1, 25 - die.value) if self.color.is_white() else range(1 + die.value, 25))


    def create_half_move(self, from_point_index: int, die: Die) -> HalfMove:
        to_point_index = from_point_index + die.value if self.color.is_white() else from_point_index - die.value
        from_point = self.board.points[from_point_index]
        to_point = self.board.points[to_point_index]
        return HalfMove(from_point, to_point, self.color)
