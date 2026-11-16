"""Portes board encoder (`portes_v1`, issue #137).

Always from the perspective of the player to move ("own"); Black is mirrored, so a
position and its colour-mirrored twin encode identically for their movers. Layout
(float32, input_size = 414):

  [0, 384)    24 points in own-relative order r = 1..24 (r = pips to bear off;
              r 1..6 = own home, r 19..24 = opponent home). Per point 16 floats:
              [owner bit (1 = own checkers), unary count 1..15 (either colour)].
  [384, 394)  bars: own then opponent, each [unary 1..4, overflow (n-4)/11].
  [394, 396)  borne off: own/15, opponent/15.
  [396, 414)  18 smart features, own then opponent where paired:
              0-1 pip count /375 · 2 pip lead 0.5+(opp-own)/750 · 3-4 blots /15 ·
              5-6 made points (>=2) /7 · 7-8 longest prime /7 ·
              9-10 made points in own home board /6 ·
              11-12 back checkers (in the opponent's home board) /15 ·
              13-14 bar /15 · 15 race flag (no contact left) ·
              16-17 directly exposed blots /15 (an opposing checker or bar checker
              1..6 pips behind the blot in its moving direction).
"""

import numpy as np

from domain.constants import WHITE

PORTES_V1 = "portes_v1"
_POINT = 16
_POINTS = 24 * _POINT          # 384
_BAR = _POINTS                 # 384
_OFF = _BAR + 10               # 394
_SMART = _OFF + 2              # 396
INPUT_SIZE = _SMART + 18       # 414


def _split(p, is_white_to_move: bool):
    """(own, opp): checker counts indexed by each side's own relative point
    1..24 (pips to bear off), 25 = that side's bar; index 0 unused."""
    white = [0] * 26
    black = [0] * 26
    for r in range(1, 25):
        v = p[25 - r]
        if v > 0:
            white[r] = v
        v = p[r]
        if v < 0:
            black[r] = -v
    white[25] = p[0]
    black[25] = -p[25]
    return (white, black) if is_white_to_move else (black, white)


def _side(a, b):
    """Per-side smart stats of `a` against `b` (both in their own relative coords)."""
    pip = 0
    blots = 0
    made = 0
    home_made = 0
    back = 0
    run = 0
    prime = 0
    top = 0
    exposed = 0
    for r in range(1, 25):
        k = a[r]
        if k:
            pip += k * r
            top = r
            if r >= 19:
                back += k
            if k >= 2:
                made += 1
                if r <= 6:
                    home_made += 1
                run += 1
                if run > prime:
                    prime = run
                continue
            # a blot: any b checker (incl. bar) at b-relative s with 1 <= s-(25-r) <= 6
            blots += 1
            lo = 26 - r
            hi = lo + 5 if lo + 5 < 25 else 25
            for s in range(lo, hi + 1):
                if b[s]:
                    exposed += 1
                    break
        run = 0
    if a[25]:
        pip += 25 * a[25]
        top = 25
    return pip, blots, made, prime, home_made, back, exposed, top


class PortesEncoder:
    def __init__(self, config=None, version: str = PORTES_V1):
        if version != PORTES_V1:
            raise ValueError(f"Unknown Portes encoder version '{version}'")
        self.version = version

    @property
    def input_size(self) -> int:
        return INPUT_SIZE

    def encode_board(self, board, is_whites_turn: bool) -> np.ndarray:
        out = np.zeros(INPUT_SIZE, dtype=np.float32)
        own, opp = _split(board.p, is_whites_turn)
        for r in range(1, 25):
            base = (r - 1) * _POINT
            k = own[r]
            if k:
                out[base] = 1.0
                out[base + 1: base + 1 + k] = 1.0
            else:
                k = opp[25 - r]
                if k:
                    out[base + 1: base + 1 + k] = 1.0
        for j, k in ((0, own[25]), (5, opp[25])):
            if k:
                base = _BAR + j
                out[base: base + min(k, 4)] = 1.0
                if k > 4:
                    out[base + 4] = (k - 4) / 11.0
        own_off = board.borne_off[WHITE if is_whites_turn else -WHITE]
        opp_off = board.borne_off[-WHITE if is_whites_turn else WHITE]
        out[_OFF] = own_off / 15.0
        out[_OFF + 1] = opp_off / 15.0

        a = _side(own, opp)
        b = _side(opp, own)
        s = _SMART
        out[s + 0] = a[0] / 375.0
        out[s + 1] = b[0] / 375.0
        out[s + 2] = 0.5 + (b[0] - a[0]) / 750.0
        out[s + 3] = a[1] / 15.0
        out[s + 4] = b[1] / 15.0
        out[s + 5] = a[2] / 7.0
        out[s + 6] = b[2] / 7.0
        out[s + 7] = a[3] / 7.0
        out[s + 8] = b[3] / 7.0
        out[s + 9] = a[4] / 6.0
        out[s + 10] = b[4] / 6.0
        out[s + 11] = a[5] / 15.0
        out[s + 12] = b[5] / 15.0
        out[s + 13] = own[25] / 15.0
        out[s + 14] = opp[25] / 15.0
        out[s + 15] = 1.0 if a[7] + b[7] < 25 else 0.0
        out[s + 16] = a[6] / 15.0
        out[s + 17] = b[6] / 15.0
        return out
