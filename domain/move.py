from typing import List
from domain.half_move import HalfMove


class Move:
    def __init__(self, half_moves: List[HalfMove]) -> None:
        self.half_moves = half_moves


    def __str__(self):
        result = "("
        for half_move in self.half_moves:
            result += str(half_move) + ","
        result = result[:-1] + ")"
        return result

    def __repr__(self):
        return self.__str__()

    def is_valid(self) -> bool:
        # Ensure each half-move is valid
        for half_move in self.half_moves:
            if not half_move.is_valid():
                return False

        # Validate if both start from the same point that two checkers are available.
        if len(self.half_moves) == 2:
            if self.half_moves[0].from_point == self.half_moves[1].from_point:
                return self.half_moves[0].two_checkers_available()

        return True
