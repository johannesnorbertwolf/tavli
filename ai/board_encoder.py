import numpy as np
from typing import List

from domain.color import Color
from domain.point import Point
from domain.board import GameBoard
from config.config_loader import ConfigLoader

class BoardEncoder:
    def __init__(self, config: ConfigLoader):
        self.board_size = config.get_board_size()
        self.pieces_per_player = config.get_pieces_per_player()
        self.point_size = 4 + self.pieces_per_player  # 2 bits for color, 2 bits for captured, n bits for piece count

    def encode_point(self, point: Point, is_whites_turn: bool) -> List[int]:
        if point.is_empty():
            return [0, 0, 0, 0] + [0] * self.pieces_per_player  # Empty

        # Determine if the piece belongs to the current player ("us") from a consistent perspective
        is_our_piece = (is_whites_turn and point.is_white()) or \
                       (not is_whites_turn and not point.is_white() and not point.is_empty())

        # Encode color from the consistent perspective ("us" vs "them")
        # [1, 0] is "us", [1, 1] is "them"
        color_bit = [1, 0] if is_our_piece else [1, 1]

        # Order "captured by" bits from the consistent perspective ("us" vs "them")
        if is_whites_turn:
            captured_us = [1] if point.is_captured_by(Color.WHITE) else [0]
            captured_them = [1] if point.is_captured_by(Color.BLACK) else [0]
        else:  # Black's turn
            captured_us = [1] if point.is_captured_by(Color.BLACK) else [0]
            captured_them = [1] if point.is_captured_by(Color.WHITE) else [0]

        count_bits = [1] * point.get_count() + [0] * (self.pieces_per_player - point.get_count())  # Unary encoding
        return color_bit + captured_us + captured_them + count_bits

    def encode_board(self, board: GameBoard, is_whites_turn: bool) -> np.ndarray:
        # The AI always sees the board from its own perspective, so no turn indicator is needed.
        encoded_board = []

        point_indices = range(self.board_size + 2)
        if not is_whites_turn:
            # For black, iterate in reverse to "flip" the board perspective
            point_indices = reversed(point_indices)

        for i in point_indices:
            point = board.points[i]
            encoded_board.extend(self.encode_point(point, is_whites_turn))
            
        return np.array(encoded_board)
