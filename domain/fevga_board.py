"""FevgaBoard: game state for Fevga (docs/variants/fevga.md).

Storage is **physical** (same layout as the Plakoto `Board`): slots 1..24 are the
points, slot 0 is Black's bear-off, slot 25 is White's. A point holds checkers of
at most one colour (no hitting, no pinning), so per-slot state is just
`n[i]` (count) and `color[i]` (owner, 0 if empty).

Both colours travel the same rotational direction:

    White: start slot 1,  path 1, 2, ..., 24            home 19..24, off slot 25
    Black: start slot 13, path 13, ..., 24, 1, ..., 12  home 7..12,  off slot 0

Per-colour *path index* p in 1..24 (25 = borne off) is what the rules and the
encoder reason in; `path_of` / `slot_of` convert. White: p == s. Black: rotation
by 12.
"""

from typing import List, Tuple

from domain.constants import WHITE, BLACK, color_name
from domain.move import Move

BOARD_SIZE = 24
HOME_SIZE = 6
HALF = BOARD_SIZE // 2

#: SLOT_OF[c][p] — physical slot of colour c's path index p (p = 25 → off slot).
#: PATH_OF[c][s] — colour c's path index of physical slot s (1..24 only).
SLOT_OF = {
    WHITE: [0] + list(range(1, 25)) + [25],
    BLACK: [0] + [p + HALF if p <= HALF else p - HALF for p in range(1, 25)] + [0],
}
PATH_OF = {
    WHITE: list(range(0, 26)),
    BLACK: [0] + [s - HALF if s > HALF else s + HALF for s in range(1, 25)] + [0],
}
OFF_SLOT = {WHITE: 25, BLACK: 0}
START_SLOT = {WHITE: 1, BLACK: 13}


def path_of(c: int, s: int) -> int:
    return PATH_OF[c][s]


def slot_of(c: int, p: int) -> int:
    return SLOT_OF[c][p]


# Undo token: (move, colour). Fevga moves never hit, so the inverse of a move is
# simply moving every checker back — no before-state needs to be captured.
UndoToken = Tuple[Move, int]


class FevgaBoard:
    __slots__ = ("board_size", "home_size", "pieces_per_player",
                 "n", "color", "pinned", "borne_off")

    def __init__(self, board_size: int = BOARD_SIZE, home_size: int = HOME_SIZE,
                 pieces_per_player: int = 15) -> None:
        if board_size != BOARD_SIZE or home_size != HOME_SIZE:
            raise ValueError("Fevga is implemented for a 24-point board with 6-point homes")
        self.board_size = board_size
        self.home_size = home_size
        self.pieces_per_player = pieces_per_player
        self.n: List[int] = [0] * (board_size + 2)
        self.color: List[int] = [0] * (board_size + 2)
        # Compatibility with Plakoto-aware helpers (renderer, logs): never pinned.
        self.pinned: List[bool] = [False] * (board_size + 2)
        self.borne_off = {WHITE: 0, BLACK: 0}

    # --- construction ---

    @classmethod
    def from_config(cls, config) -> "FevgaBoard":
        return cls(board_size=config.get_board_size(), home_size=config.get_home_size(),
                   pieces_per_player=config.get_pieces_per_player())

    @classmethod
    def initial(cls, config=None, **kwargs) -> "FevgaBoard":
        b = cls.from_config(config) if config is not None else cls(**kwargs)
        b.set_point(START_SLOT[WHITE], WHITE, b.pieces_per_player)
        b.set_point(START_SLOT[BLACK], BLACK, b.pieces_per_player)
        return b

    def set_point(self, i: int, color: int, n: int) -> None:
        """Replace slot i's state. Test / setup helper (playable slots only)."""
        self.n[i] = n
        self.color[i] = color if n else 0

    def set_borne_off(self, color: int, k: int) -> None:
        """Test / setup helper: `k` of `color`'s checkers are borne off."""
        self.borne_off[color] = k
        off = OFF_SLOT[color]
        self.n[off] = k
        self.color[off] = color if k else 0

    def clone(self) -> "FevgaBoard":
        b = FevgaBoard.__new__(FevgaBoard)
        b.board_size = self.board_size
        b.home_size = self.home_size
        b.pieces_per_player = self.pieces_per_player
        b.n = self.n[:]
        b.color = self.color[:]
        b.pinned = self.pinned
        b.borne_off = dict(self.borne_off)
        return b

    # --- inspection ---

    def is_open_for(self, i: int, c: int) -> bool:
        return self.n[i] == 0 or self.color[i] == c

    def is_off_board(self, i: int) -> bool:
        return i == 0 or i == self.board_size + 1

    def movable_count(self, i: int, c: int) -> int:
        return self.n[i] if self.color[i] == c else 0

    def checkers_on_board(self, c: int) -> int:
        n, col = self.n, self.color
        return sum(n[i] for i in range(1, 25) if col[i] == c)

    # --- mutation ---

    def apply_half(self, src: int, dst: int, c: int) -> None:
        n, col = self.n, self.color
        n[src] -= 1
        if n[src] == 0:
            col[src] = 0
        if dst == 0 or dst == 25:
            self.borne_off[c] += 1
        elif n[dst] and col[dst] != c:
            raise ValueError(f"illegal apply_half src={src} dst={dst} c={c}: "
                             f"dst held by {col[dst]}")
        n[dst] += 1
        col[dst] = c

    def undo_half(self, src: int, dst: int, c: int) -> None:
        n, col = self.n, self.color
        if dst == 0 or dst == 25:
            self.borne_off[c] -= 1
        n[dst] -= 1
        if n[dst] == 0:
            col[dst] = 0
        n[src] += 1
        col[src] = c

    def apply(self, move: Move, c: int) -> UndoToken:
        for h in move.halves:
            self.apply_half(h.src, h.dst, c)
        return (move, c)

    def undo(self, token: UndoToken) -> None:
        move, c = token
        for h in reversed(move.halves):
            self.undo_half(h.src, h.dst, c)

    # --- win ---

    def has_won(self, c: int) -> bool:
        return self.borne_off[c] >= self.pieces_per_player

    # --- debug ---

    def __repr__(self) -> str:
        lines = []
        for i in range(self.board_size + 1, -1, -1):
            owner = color_name(self.color[i]) if self.n[i] > 0 else "."
            label = f"{i:2d}: {owner}{self.n[i]}"
            if i == 0:
                label += f"  borne_off[B]={self.borne_off[BLACK]}"
            elif i == self.board_size + 1:
                label += f"  borne_off[W]={self.borne_off[WHITE]}"
            lines.append(label)
        return "\n".join(lines)
