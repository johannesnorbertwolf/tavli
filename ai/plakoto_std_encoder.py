"""Encoder `plakoto_std_v1` for standard Plakoto (#139).

Layout = the full `unary_v3` vector (BoardEncoder, unchanged) followed by
8 features the standard end-of-game rules make relevant (current player's
perspective, "start" = a side's own starting slot, White 1 / Black board_size):

  +0 our mother still on start (>=1 own checker on own start, pinned or not)
  +1 their mother still on start
  +2 our mother pinned (opponent owns our start with our checker under it)
  +3 their mother pinned
  +4 our checkers on our start / pieces_per_player
  +5 their checkers on their start / pieces_per_player
  +6 we have borne off >= 1 (safe from a bear-off double loss)
  +7 they have borne off >= 1
"""

import numpy as np

from ai.board_encoder import BoardEncoder, UNARY_V3
from domain.constants import WHITE, BLACK

PLAKOTO_STD_V1 = "plakoto_std_v1"
STD_EXTRA_FEATURES = 8


class PlakotoStdEncoder:
    def __init__(self, config, version: str = PLAKOTO_STD_V1):
        if version != PLAKOTO_STD_V1:
            raise ValueError(f"PlakotoStdEncoder only supports {PLAKOTO_STD_V1}, got {version}")
        self.version = version
        self._base = BoardEncoder(config, version=UNARY_V3)
        self._base_size = self._base.input_size
        self.board_size = config.get_board_size()
        self.pieces_per_player = config.get_pieces_per_player()
        self.home_size = config.get_home_size()

    @property
    def input_size(self) -> int:
        return self._base_size + STD_EXTRA_FEATURES

    def encode_board(self, board, is_whites_turn: bool) -> np.ndarray:
        bs = self._base_size
        out = np.empty(bs + STD_EXTRA_FEATURES, dtype=np.float32)
        out[:bs] = self._base.encode_board(board, is_whites_turn)
        our = WHITE if is_whites_turn else BLACK
        n = board.n
        col = board.color
        pin = board.pinned
        inv = 1.0 / self.pieces_per_player
        # (start slot, colour) for us then them
        for k, c in enumerate((our, -our)):
            s = 1 if c == WHITE else self.board_size
            cnt = n[s]
            if cnt and col[s] == c:
                on_start, pinned = cnt, False
            elif cnt and pin[s]:
                on_start, pinned = 1, True
            else:
                on_start, pinned = 0, False
            out[bs + k] = 1.0 if on_start else 0.0
            out[bs + 2 + k] = 1.0 if pinned else 0.0
            out[bs + 4 + k] = on_start * inv
            out[bs + 6 + k] = 1.0 if board.borne_off[c] > 0 else 0.0
        return out
