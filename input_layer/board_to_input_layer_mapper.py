import numpy as np
from typing import List
from domain.tavli.color import Color
from domain.tavli.point import Point
from domain.tavli.board import GameBoard
from config.config_loader import ConfigLoader


board_size = ConfigLoader.get_board_size()
pieces_per_player = ConfigLoader.get_pieces_per_player()

class BoardEncoder:
    def __init__(self):
        self.point_size = 4 + pieces_per_player  # 2 bits for color, 2 bit for captured, 15 bits for piece count

    def encode_point(self, point: Point) -> List[int]:
        if point.is_empty():
            return [0, 0, 0] + [0] * pieces_per_player  # Empty
        color_bit = [1, 0] if point.is_white() else [1, 1]
        captured_by_white = [1] if point.is_captured_by(Color.WHITE) else [0]
        captured_by_black = [1] if point.is_captured_by(Color.BLACK) else [0]
        count_bits = [1] * point.get_count() + [0] * (pieces_per_player - point.get_count())  # Unary encoding
        return color_bit + captured_by_white + captured_by_black + count_bits

    def encode_board(self, board: GameBoard) -> np.ndarray:
        encoded_board = []
        for i in range(0, board_size + 2):
            point = board.points[i]
            encoded_board.extend(self.encode_point(point))
        return np.array(encoded_board)
