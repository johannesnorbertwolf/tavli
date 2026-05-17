from typing import List, Tuple

from domain_v2.constants import WHITE, BLACK, color_name
from domain_v2.move import HalfMove, Move


# An UndoToken is a list of half-undo entries:
#   (src, n_src_before, color_src_before, pinned_src_before,
#    dst, n_dst_before, color_dst_before, pinned_dst_before,
#    moved_color)
# We carry the moved color so undo can decrement `borne_off` correctly.
UndoToken = List[Tuple[int, int, int, bool, int, int, int, bool, int]]


class Board:
    """Plakoto game state.

    Layout (length = board_size + 2):
      index 0           — Black's bear-off slot
      indices 1..board_size — playable points
      index board_size+1 — White's bear-off slot

    Per-slot state is three parallel arrays:
      n[i]      number of "owning" checkers stacked at i (>=0)
      color[i]  color of those checkers: +1 WHITE, -1 BLACK, 0 if empty
      pinned[i] True iff a single opponent checker is trapped under the owner stack

    The pinned color is always -color[i]. Pop removes the top owner; if the last
    owner is popped and a pin existed, the trapped checker becomes a regular
    blot (color flips, pinned cleared). Push onto a single-opponent blot pins.
    """

    __slots__ = (
        "board_size", "home_size", "pieces_per_player",
        "n", "color", "pinned",
        "borne_off",
    )

    def __init__(self, board_size: int = 24, home_size: int = 6,
                 pieces_per_player: int = 15) -> None:
        self.board_size = board_size
        self.home_size = home_size
        self.pieces_per_player = pieces_per_player
        size = board_size + 2
        self.n: List[int] = [0] * size
        self.color: List[int] = [0] * size
        self.pinned: List[bool] = [False] * size
        self.borne_off = {WHITE: 0, BLACK: 0}

    # --- construction helpers ---

    @classmethod
    def from_config(cls, config) -> "Board":
        return cls(
            board_size=config.get_board_size(),
            home_size=config.get_home_size(),
            pieces_per_player=config.get_pieces_per_player(),
        )

    @classmethod
    def initial(cls, config=None, **kwargs) -> "Board":
        b = cls.from_config(config) if config is not None else cls(**kwargs)
        b.set_point(1, WHITE, b.pieces_per_player)
        b.set_point(b.board_size, BLACK, b.pieces_per_player)
        return b

    def set_point(self, i: int, color: int, n: int, pinned: bool = False) -> None:
        """Replace slot i's state. Test / setup helper."""
        if n == 0:
            self.n[i] = 0
            self.color[i] = 0
            self.pinned[i] = False
        else:
            self.n[i] = n
            self.color[i] = color
            self.pinned[i] = pinned

    def clone(self) -> "Board":
        b = Board(self.board_size, self.home_size, self.pieces_per_player)
        b.n = self.n[:]
        b.color = self.color[:]
        b.pinned = self.pinned[:]
        b.borne_off = dict(self.borne_off)
        return b

    # --- inspection (all O(1)) ---

    def is_empty(self, i: int) -> bool:
        return self.n[i] == 0

    def is_open_for(self, i: int, c: int) -> bool:
        if self.n[i] == 0:
            return True
        if self.color[i] == c:
            return True
        return self.n[i] == 1 and not self.pinned[i]

    def is_captured_by(self, i: int, c: int) -> bool:
        return self.pinned[i] and self.color[i] == c

    def movable_count(self, i: int, c: int) -> int:
        if self.n[i] > 0 and self.color[i] == c:
            return self.n[i]
        return 0

    def is_home(self, c: int, i: int) -> bool:
        if c == WHITE:
            return self.board_size - self.home_size + 1 <= i <= self.board_size
        return 1 <= i <= self.home_size

    def is_off_board(self, i: int) -> bool:
        return i == 0 or i == self.board_size + 1

    def count_outside_home(self, c: int) -> int:
        """Number of c's checkers that are not yet in c's home board.

        A pinned-trapped checker counts toward its own color (it occupies the
        square, just frozen). Borne-off checkers are not counted (they're
        beyond home, effectively "done").
        """
        total = 0
        for i in range(1, self.board_size + 1):
            if self.is_home(c, i):
                continue
            if self.n[i] > 0 and self.color[i] == c:
                total += self.n[i]
            if self.pinned[i] and self.color[i] == -c:
                total += 1
        return total

    # --- mutation ---

    def apply_half(self, src: int, dst: int, c: int) -> tuple:
        """Apply (src -> dst) for color c. Returns an undo entry."""
        undo = (
            src, self.n[src], self.color[src], self.pinned[src],
            dst, self.n[dst], self.color[dst], self.pinned[dst],
            c,
        )

        # Pop owner at src.
        self.n[src] -= 1
        if self.n[src] == 0:
            if self.pinned[src]:
                # Last owner left; the previously-pinned opponent is now a blot.
                self.color[src] = -self.color[src]
                self.n[src] = 1
                self.pinned[src] = False
            else:
                self.color[src] = 0

        # Push at dst.
        if dst == 0 or dst == self.board_size + 1:
            # Bear off — destination is the goal slot.
            self.borne_off[c] += 1
            self.n[dst] += 1
            self.color[dst] = c
            # pinned[dst] stays False (no pin in bear-off slot)
        elif self.n[dst] == 0:
            self.n[dst] = 1
            self.color[dst] = c
            self.pinned[dst] = False
        elif self.color[dst] == c:
            self.n[dst] += 1
        elif self.n[dst] == 1 and not self.pinned[dst]:
            # Land on a single opponent blot: pin.
            self.color[dst] = c
            self.n[dst] = 1
            self.pinned[dst] = True
        else:
            raise ValueError(
                f"illegal apply_half src={src} dst={dst} c={c}: "
                f"dst state n={self.n[dst]} color={self.color[dst]} pinned={self.pinned[dst]}"
            )

        return undo

    def undo_half(self, entry: tuple) -> None:
        (src, n_src, c_src, p_src,
         dst, n_dst, c_dst, p_dst,
         moved_color) = entry
        if dst == 0 or dst == self.board_size + 1:
            self.borne_off[moved_color] -= 1
        self.n[src] = n_src
        self.color[src] = c_src
        self.pinned[src] = p_src
        self.n[dst] = n_dst
        self.color[dst] = c_dst
        self.pinned[dst] = p_dst

    def apply(self, move: Move, c: int) -> UndoToken:
        token: UndoToken = []
        for h in move.halves:
            token.append(self.apply_half(h.src, h.dst, c))
        return token

    def undo(self, token: UndoToken) -> None:
        for entry in reversed(token):
            self.undo_half(entry)

    # --- win conditions ---

    def has_won(self, c: int) -> bool:
        return self.all_borne_off(c) or self.captured_starting(c)

    def all_borne_off(self, c: int) -> bool:
        return self.borne_off[c] >= self.pieces_per_player

    def captured_starting(self, c: int) -> bool:
        # White wins by pinning Black's starting point (board_size = 24).
        # Black wins by pinning White's starting point (1).
        start = self.board_size if c == WHITE else 1
        return self.pinned[start] and self.color[start] == c

    # --- rendering for debug / error reports ---

    def __repr__(self) -> str:
        lines = []
        for i in range(self.board_size + 1, -1, -1):
            owner = color_name(self.color[i]) if self.n[i] > 0 else "."
            label = f"{i:2d}: {owner}{self.n[i]}"
            if self.pinned[i]:
                label += f" (pin:{color_name(-self.color[i])})"
            if i == 0:
                label += f"  borne_off[B]={self.borne_off[BLACK]}"
            elif i == self.board_size + 1:
                label += f"  borne_off[W]={self.borne_off[WHITE]}"
            lines.append(label)
        return "\n".join(lines)
