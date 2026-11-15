"""Portes board state (issue #137, spec: docs/variants/portes.md).

One signed array `p` of length 26:

    p[i] > 0   White has p[i] checkers on slot i
    p[i] < 0   Black has -p[i] checkers on slot i
    p[0]  >= 0 White's bar   (White enters at slot d, i.e. dst = 0 + d)
    p[25] <= 0 Black's bar   (Black enters at slot 25 - d)

Points are slots 1..24; White moves 1 -> 24 (home 19..24), Black 24 -> 1 (home
1..6). Every half-move, bar entry included, is `dst = src + color * die`. A
bear-off is `HalfMove(src, 25)` for White and `HalfMove(src, 0)` for Black;
borne-off checkers are only counted in `borne_off[c]`, never stored in p[0]/p[25],
so slot 0 only ever holds White bar checkers and slot 25 only Black ones.

Landing on a single opposing checker (a blot) hits it: it goes to its owner's bar.
"""

from typing import List, Tuple

from domain.constants import WHITE, BLACK
from domain.move import Move

WHITE_BAR = 0
BLACK_BAR = 25
WHITE_OFF = 25
BLACK_OFF = 0
CHECKERS = 15

# Standard backgammon setup in this repo's coordinates (spec rule 1).
_INITIAL = {1: 2, 12: 5, 17: 3, 19: 5,          # White
            24: -2, 13: -5, 8: -3, 6: -5}       # Black

# Undo entry per half-move: (src, dst, color, hit) — hit=True iff a blot was sent
# to the opponent's bar. Applying is fully determined by these, so undo is exact.
UndoToken = List[Tuple[int, int, int, bool]]


class PortesBoard:
    __slots__ = ("p", "borne_off")

    # Fixed geometry (read by shared code that expects these attributes).
    board_size = 24
    home_size = 6
    pieces_per_player = CHECKERS

    def __init__(self) -> None:
        self.p: List[int] = [0] * 26
        self.borne_off = {WHITE: 0, BLACK: 0}

    # --- construction ---

    @classmethod
    def initial(cls) -> "PortesBoard":
        b = cls()
        for i, v in _INITIAL.items():
            b.p[i] = v
        return b

    @classmethod
    def from_counts(cls, white=None, black=None, white_off: int = 0, black_off: int = 0) -> "PortesBoard":
        """Test/setup helper: `white` / `black` map slot -> count (White bar = 0,
        Black bar = 25)."""
        b = cls()
        for i, k in (white or {}).items():
            b.p[i] += k
        for i, k in (black or {}).items():
            b.p[i] -= k
        b.borne_off[WHITE] = white_off
        b.borne_off[BLACK] = black_off
        return b

    def set_point(self, i: int, color: int, n: int) -> None:
        self.p[i] = color * n

    def clone(self) -> "PortesBoard":
        b = PortesBoard.__new__(PortesBoard)
        b.p = self.p[:]
        b.borne_off = dict(self.borne_off)
        return b

    # --- inspection ---

    def count(self, i: int, c: int) -> int:
        """Checkers of color `c` on slot `i` (bar slots included)."""
        v = self.p[i] * c
        return v if v > 0 else 0

    def bar(self, c: int) -> int:
        return self.p[0] if c == WHITE else -self.p[25]

    def is_open_for(self, i: int, c: int) -> bool:
        """Slot i (1..24) can receive a checker of c: empty, own, or a single opponent blot."""
        return self.p[i] * c >= -1

    def total(self, c: int) -> int:
        """All of c's checkers: on points, on the bar and borne off (always 15)."""
        return sum(v * c for v in self.p if v * c > 0) + self.borne_off[c]

    def pip_count(self, c: int) -> int:
        if c == WHITE:
            return sum(v * (25 - i) for i, v in enumerate(self.p) if v > 0)
        return sum(-v * i for i, v in enumerate(self.p) if v < 0)

    def key(self) -> tuple:
        """Hashable full position (for de-duplication / tests)."""
        return tuple(self.p) + (self.borne_off[WHITE], self.borne_off[BLACK])

    # --- mutation ---

    def apply_half(self, src: int, dst: int, c: int) -> tuple:
        p = self.p
        p[src] -= c
        if c == WHITE:
            if dst >= 25:
                self.borne_off[WHITE] += 1
                return (src, dst, c, False)
            if p[dst] == -1:
                p[dst] = 1
                p[25] -= 1          # Black checker to Black's bar
                return (src, dst, c, True)
            p[dst] += 1
            return (src, dst, c, False)
        if dst <= 0:
            self.borne_off[BLACK] += 1
            return (src, dst, c, False)
        if p[dst] == 1:
            p[dst] = -1
            p[0] += 1               # White checker to White's bar
            return (src, dst, c, True)
        p[dst] -= 1
        return (src, dst, c, False)

    def undo_half(self, entry: tuple) -> None:
        src, dst, c, hit = entry
        p = self.p
        if c == WHITE:
            if dst >= 25:
                self.borne_off[WHITE] -= 1
            elif hit:
                p[dst] = -1
                p[25] += 1
            else:
                p[dst] -= 1
        else:
            if dst <= 0:
                self.borne_off[BLACK] -= 1
            elif hit:
                p[dst] = 1
                p[0] -= 1
            else:
                p[dst] += 1
        p[src] += c

    def apply(self, move: Move, c: int) -> UndoToken:
        return [self.apply_half(h.src, h.dst, c) for h in move.halves]

    def undo(self, token: UndoToken) -> None:
        for entry in reversed(token):
            self.undo_half(entry)

    # --- result ---

    def has_won(self, c: int) -> bool:
        return self.borne_off[c] >= CHECKERS

    def result_points(self, winner: int) -> int:
        """2 (gammon / 'diplo') if the loser has borne off none, else 1. No triple."""
        return 2 if self.borne_off[-winner] == 0 else 1

    def __repr__(self) -> str:
        lines = []
        for i in range(25, -1, -1):
            v = self.p[i]
            label = "B" if v < 0 else ("W" if v > 0 else ".")
            tag = " (W bar)" if i == 0 else (" (B bar)" if i == 25 else "")
            lines.append(f"{i:2d}: {label}{abs(v)}{tag}")
        lines.append(f"off: W={self.borne_off[WHITE]} B={self.borne_off[BLACK]}")
        return "\n".join(lines)
