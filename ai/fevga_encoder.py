"""FevgaEncoder: Fevga board -> float32 vector from the mover's perspective.

Everything is expressed in the MOVER's path index p = 1..24 (see
domain/fevga_board.py), so the colour flip is a rotation by 12 and a position and
its colour-swapped twin encode identically. Layout (`fevga_v1`, 406 floats with
15 checkers per side) is documented in ai/REFERENCE.md.
"""

import numpy as np

from domain.constants import WHITE, BLACK
from domain.fevga_board import SLOT_OF

FEVGA_V1 = "fevga_v1"
SMART_FEATURE_COUNT = 20

_PATH = range(1, 25)


def _rot(a):
    """Re-index a path array (index 1..24) into the other colour's path."""
    return [0] + a[13:25] + a[1:13]


def _longest_run(held, lo: int = 1) -> int:
    """Longest run of consecutive truthy entries of held[lo..24] (no wrap)."""
    best = cur = 0
    for q in range(lo, 25):
        if held[q]:
            cur += 1
            if cur > best:
                best = cur
        else:
            cur = 0
    return best


def _rear(a) -> int:
    for p in _PATH:
        if a[p]:
            return p
    return 25


class FevgaEncoder:
    def __init__(self, config, version: str = FEVGA_V1):
        if version != FEVGA_V1:
            raise ValueError(f"Unknown Fevga encoder version '{version}' (known: {FEVGA_V1})")
        if config.get_board_size() != 24 or config.get_home_size() != 6:
            raise ValueError("Fevga encoder requires a 24-point board with 6-point homes")
        self.version = version
        self.board_size = 24
        self.pieces_per_player = config.get_pieces_per_player()
        self.point_size = 1 + self.pieces_per_player
        self._raw_size = 24 * self.point_size
        self._smart_base = self._raw_size + 2

    @property
    def input_size(self) -> int:
        return self._raw_size + 2 + SMART_FEATURE_COUNT

    def _side(self, own, opp, borne_own):
        """Features of one side, `own`/`opp` = counts in that side's own path."""
        own_in_opp = _rot(own)              # own checkers seen in the opponent's path
        opp_own_path = _rot(opp)            # opponent checkers in the opponent's path
        rear = _rear(own)
        opp_rear = _rear(opp_own_path)
        pip = 0
        held = 0
        home = 0
        for p in _PATH:
            k = own[p]
            if k:
                pip += k * (25 - p)
                held += 1
                if p >= 19:
                    home += k
        unlocked = 1.0 if borne_own or any(own[p] for p in range(14, 25)) else 0.0
        run = min(_longest_run(own_in_opp), 6)
        run_front = min(_longest_run(own_in_opp, opp_rear + 1), 6) if opp_rear < 24 else 0
        blk6 = sum(1 for p in range(rear + 1, min(rear + 6, 24) + 1) if opp[p])
        blk12 = sum(1 for p in range(rear + 1, min(rear + 12, 24) + 1) if opp[p])
        contact = any(opp[p] for p in range(rear + 1, 25))
        return pip, own[1], unlocked, held, run, run_front, blk6, blk12, home, contact

    def encode_board(self, board, is_whites_turn: bool) -> np.ndarray:
        us = WHITE if is_whites_turn else BLACK
        them = -us
        slot = SLOT_OF[us]
        bn = board.n
        bc = board.color
        ppp = self.pieces_per_player
        ps = self.point_size
        out = np.zeros(self.input_size, dtype=np.float32)

        mine = [0] * 25
        theirs = [0] * 25
        for p in _PATH:
            s = slot[p]
            k = bn[s]
            if k:
                base = (p - 1) * ps
                if bc[s] == us:
                    mine[p] = k
                else:
                    theirs[p] = k
                    out[base] = 1.0
                out[base + 1: base + 1 + k] = 1.0

        bo_us = board.borne_off[us]
        bo_them = board.borne_off[them]
        r = self._raw_size
        out[r] = bo_us / ppp
        out[r + 1] = bo_them / ppp

        a = self._side(mine, theirs, bo_us)
        b = self._side(_rot(theirs), _rot(mine), bo_them)
        pip_scale = float(ppp * 24)
        f = self._smart_base
        out[f + 0] = a[0] / pip_scale
        out[f + 1] = b[0] / pip_scale
        out[f + 2] = 0.5 + (a[0] - b[0]) / (2.0 * pip_scale)
        out[f + 3] = a[1] / ppp
        out[f + 4] = b[1] / ppp
        out[f + 5] = a[2]
        out[f + 6] = b[2]
        out[f + 7] = a[3] / ppp
        out[f + 8] = b[3] / ppp
        out[f + 9] = a[4] / 6.0
        out[f + 10] = b[4] / 6.0
        out[f + 11] = a[5] / 6.0
        out[f + 12] = b[5] / 6.0
        out[f + 13] = a[6] / 6.0
        out[f + 14] = a[7] / 12.0
        out[f + 15] = b[6] / 6.0
        out[f + 16] = b[7] / 12.0
        out[f + 17] = a[8] / ppp
        out[f + 18] = b[8] / ppp
        out[f + 19] = 0.0 if (a[9] or b[9]) else 1.0
        return out
