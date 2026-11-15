"""StandardPlakotoBoard: Board state for standard (bkgm) Plakoto.

Same slot layout, arrays, apply/undo and pinning mechanics as `domain.board.Board`
(subclassed, not modified). Only the end-of-game logic differs
(docs/variants/plakoto-standard.md, rules 10-11):

- The "mother" of colour X is X's last checker on X's start slot (White: 1,
  Black: board_size). `mother_pinned(X)` <=> X's start slot is owned by -X with
  an X checker pinned under it.
- Both mothers pinned -> draw (0 points).
- X's mother pinned and the pinner Y has no checker of its own left on Y's start
  slot -> Y wins 2 points. While Y still has checkers on its start, play goes on.
- First to bear off all checkers wins 1 point, or 2 if the loser has borne off none.

All checks are pure functions of the position, so evaluating them after every
complete move (the spec's "after all halves are applied") is exactly "check the
board state after `apply(move)`".
"""

from typing import Optional, Tuple

from domain.board import Board
from domain.constants import WHITE, BLACK


class StandardPlakotoBoard(Board):
    __slots__ = ()

    def clone(self) -> "StandardPlakotoBoard":
        b = StandardPlakotoBoard(self.board_size, self.home_size, self.pieces_per_player)
        b.n = self.n[:]
        b.color = self.color[:]
        b.pinned = self.pinned[:]
        b.borne_off = dict(self.borne_off)
        return b

    # --- mother-checker helpers ---

    def start_slot(self, c: int) -> int:
        return 1 if c == WHITE else self.board_size

    def checkers_on_start(self, c: int) -> int:
        """c's checkers on c's own start slot (owned stack, or 1 if pinned there)."""
        s = 1 if c == WHITE else self.board_size
        k = self.n[s]
        if k == 0:
            return 0
        if self.color[s] == c:
            return k
        return 1 if self.pinned[s] else 0

    def mother_pinned(self, c: int) -> bool:
        s = 1 if c == WHITE else self.board_size
        return self.pinned[s] and self.color[s] == -c

    def is_draw(self) -> bool:
        return self.mother_pinned(WHITE) and self.mother_pinned(BLACK)

    def mother_win(self, c: int) -> bool:
        """c has pinned the opponent's mother and has no checkers left on c's own start."""
        return (self.mother_pinned(-c)
                and not self.mother_pinned(c)
                and self.checkers_on_start(c) == 0)

    # --- end of game ---

    def has_won(self, c: int) -> bool:  # overrides Board.has_won (no immediate start-pin win)
        return self.all_borne_off(c) or self.mother_win(c)

    def is_over(self) -> bool:
        return self.is_draw() or self.has_won(WHITE) or self.has_won(BLACK)

    def outcome(self) -> Tuple[Optional[int], int]:
        """(winner, points) of a finished game; (None, 0) for a draw.
        Also (None, 0) when the game is not over — check `is_over()` first."""
        if self.is_draw():
            return None, 0
        for c in (WHITE, BLACK):
            if self.mother_win(c):
                return c, 2
            if self.all_borne_off(c):
                return c, (2 if self.borne_off[-c] == 0 else 1)
        return None, 0
