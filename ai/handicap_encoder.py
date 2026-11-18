"""Encoder `unary_v3_hc1` for the handicap-aware house-Plakoto net (`plakoto_hc`, #148 E3).

Layout (606 floats), everything from the player-to-move's perspective like unary_v3:

  [0, 486)    the unchanged `unary_v3` vector (BoardEncoder; a stack above 15 saturates at 15)
  [486, 538)  overflow block: per mover-perspective slot s = 0..25 (same slot order as the
              unary_v3 block), two units [count >= 16, count >= 17]. Together with the unary_v3
              block this is a capacity-17 unary encoding, laid out so the unary_v3 prefix stays
              byte-identical (warm start from gold_v11 needs no weight remapping)
  [538, 606)  handicap block: 34 features for the side to move ("own"), then 34 for the
              opponent:
                +0        overshoot bear-off allowed
                +1..+24   safe point one-hot, index p-1 with p in that side's own numbering
                          (1 = its start point); all zero = no safe point
                +25       (checkers - 15) / 2
                +26..+29  checker-count one-hot for 13, 14, 16, 17 (all zero = 15)
                +30       (6 - home size) / 3
                +31..+33  home-size one-hot for 5, 4, 3 (all zero = 6)

Every feature after the unary_v3 prefix is exactly 0 in a normal game, so a net whose new input
columns are zero (the warm start, ai/handicap_model.py) computes gold_v11's function there — and
keeps computing it from the same shared weights whatever the new columns learn.
"""

import numpy as np

from ai.board_encoder import BoardEncoder, UNARY_V3
from domain.constants import WHITE, BLACK

UNARY_V3_HC1 = "unary_v3_hc1"
OVERFLOW_UNITS = 2                      # capacity 15 + 2 = 17 (domain.handicap.MAX_CHECKERS)
SIDE_FEATURES = 34
CHECKER_ONEHOT = (13, 14, 16, 17)
HOME_ONEHOT = (5, 4, 3)
NUM_POINTS = 24


class HandicapEncoder:
    def __init__(self, config, version: str = UNARY_V3_HC1):
        if version != UNARY_V3_HC1:
            raise ValueError(f"HandicapEncoder only supports {UNARY_V3_HC1}, got {version}")
        if config.get_board_size() != NUM_POINTS:
            raise ValueError("unary_v3_hc1 assumes a 24-point board")
        self.version = version
        self._base = BoardEncoder(config, version=UNARY_V3)
        self._base_size = self._base.input_size
        self.board_size = config.get_board_size()
        self.pieces_per_player = config.get_pieces_per_player()
        self.home_size = config.get_home_size()
        self._num_slots = self.board_size + 2
        self._overflow_size = self._num_slots * OVERFLOW_UNITS
        self._hc_offset = self._base_size + self._overflow_size

    @property
    def input_size(self) -> int:
        return self._hc_offset + 2 * SIDE_FEATURES

    @property
    def base_size(self) -> int:
        """Length of the unary_v3 prefix (the gold_v11 input)."""
        return self._base_size

    def encode_board(self, board, is_whites_turn: bool) -> np.ndarray:
        bs = self._base_size
        out = np.zeros(self.input_size, dtype=np.float32)
        out[:bs] = self._base.encode_board(board, is_whites_turn)
        ppp = self.pieces_per_player
        n = board.n
        last = self._num_slots - 1
        for pi in range(self._num_slots):
            k = n[pi]
            if k > ppp:
                slot = pi if is_whites_turn else last - pi
                base = bs + slot * OVERFLOW_UNITS
                out[base: base + min(k - ppp, OVERFLOW_UNITS)] = 1.0
        checkers = getattr(board, "checkers", None)
        if checkers is None:
            return out  # a plain Board: no handicap, block stays zero
        our = WHITE if is_whites_turn else BLACK
        for k, c in enumerate((our, -our)):
            o = self._hc_offset + k * SIDE_FEATURES
            if board.overshoot[c]:
                out[o] = 1.0
            p = board.safe_point[c]
            if p:
                out[o + p] = 1.0
            cnt = checkers[c]
            if cnt != ppp:
                out[o + 25] = (cnt - ppp) / 2.0
                if cnt in CHECKER_ONEHOT:
                    out[o + 26 + CHECKER_ONEHOT.index(cnt)] = 1.0
            home = board.home_white if c == WHITE else board.home_black
            if home != self.home_size:
                out[o + 30] = (self.home_size - home) / 3.0
                if home in HOME_ONEHOT:
                    out[o + 31 + HOME_ONEHOT.index(home)] = 1.0
        return out
