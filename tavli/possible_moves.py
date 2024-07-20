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

        for half_move1 in self.get_half_move_range(self.dice.range1(self.color)):
            if not half_move1.is_valid():
                continue

            for half_move2 in self.get_half_move_range(self.dice.range2(self.color)):
                if not half_move2.is_valid():
                    continue
                if half_move1.from_point == half_move2.from_point:
                    if not half_move1.two_checkers_available():
                        continue

                possible_moves.append(Move([half_move1, half_move2]))

        return possible_moves


    def get_half_move_range(self, from_range):
        return [self.get_half_move(from_point_index1, self.dice.die1) for from_point_index1 in from_range]
    def get_half_move(self, from_point_index: int, die: Die) -> HalfMove:
        to_point_index = from_point_index + die.roll if self.color.is_white() else from_point_index - die.roll()
        from_point = self.board.points[from_point_index]
        to_point = self.board.points[to_point_index]
        return HalfMove(from_point, to_point, self.color)

