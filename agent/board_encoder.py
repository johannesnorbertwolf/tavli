import numpy as np
from typing import List

from sympy.logic.boolalg import Boolean

from domain.color import Color
from domain.point import Point
from domain.board import GameBoard
from config.config_loader import ConfigLoader

class BoardEncoder:
    def __init__(self, config: ConfigLoader):
        self.board_size = config.get_board_size()
        self.pieces_per_player = config.get_pieces_per_player()
        self.point_size = 4 + self.pieces_per_player  # 2 bits for color, 2 bits for captured, n bits for piece count

    def encode_point(self, point: Point) -> List[int]:
        if point.is_empty():
            return [0, 0, 0, 0] + [0] * self.pieces_per_player  # Empty
        color_bit = [1, 0] if point.is_white() else [1, 1]
        captured_by_white = [1] if point.is_captured_by(Color.WHITE) else [0]
        captured_by_black = [1] if point.is_captured_by(Color.BLACK) else [0]
        count_bits = [1] * point.get_count() + [0] * (self.pieces_per_player - point.get_count())  # Unary encoding
        return color_bit + captured_by_white + captured_by_black + count_bits

    def encode_board(self, board: GameBoard, is_whites_turn: Boolean) -> np.ndarray:
        encoded_board = [0 if is_whites_turn else 1]
        for i in range(0, self.board_size + 2):
            point = board.points[i]
            encoded_board.extend(self.encode_point(point))
        return np.array(encoded_board)

# Example usage
if __name__ == "__main__":
    config_loader = ConfigLoader("../config/config.yml")
    board = GameBoard(config_loader)
    board.initialize_board()

    encoder = BoardEncoder(config_loader)
    encoded_board = encoder.encode_board(board, 0)
    print(encoded_board)
    print(len(encoded_board))  # Should be (board_size + 2) * (4 + pieces_per_player) bits