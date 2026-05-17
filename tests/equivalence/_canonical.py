"""Canonicalize board state across the old and new domains.

Both domains describe a Plakoto position fully by:
    for each slot i in [0..board_size+1]:
        (number of owning checkers, owner color int, is_pinned)

The owner color is encoded as +1 (WHITE), -1 (BLACK), or 0 (empty).
A pinned checker counts toward its own color's slot via the symmetric
representation, not toward this tuple — but at runtime the only place an
opposite-color checker can occupy a slot is the captured-bottom case, which
this tuple already encodes via the `pinned` flag.

This is the equality oracle the equivalence test uses to compare per-ply
legal-move sets *by resulting board state*.
"""

from typing import Tuple

from domain.board import GameBoard as OldBoard
from domain.color import Color as OldColor
from domain.move import Move as OldMove

from domain_v2.board import Board as NewBoard
from domain_v2.move import Move as NewMove
from domain_v2.constants import WHITE, BLACK


SlotKey = Tuple[int, int, bool]
BoardKey = Tuple[SlotKey, ...]


def _old_color_int(c) -> int:
    if c is None:
        return 0
    return 1 if c.is_white() else -1


def old_canonical(board: OldBoard) -> BoardKey:
    out = []
    for i in range(board.board_size + 2):
        pt = board.points[i]
        pieces = pt.pieces
        if not pieces:
            out.append((0, 0, False))
        elif len(pieces) > 1 and pieces[0] != pieces[1]:
            # Captured: bottom is opposite of layer above; owner is the top.
            owner = pieces[-1]
            out.append((len(pieces) - 1, _old_color_int(owner), True))
        else:
            owner = pieces[-1]
            out.append((len(pieces), _old_color_int(owner), False))
    return tuple(out)


def new_canonical(board: NewBoard) -> BoardKey:
    return tuple(
        (board.n[i], board.color[i], board.pinned[i])
        for i in range(board.board_size + 2)
    )


def old_key_after_move(board: OldBoard, move: OldMove) -> BoardKey:
    board.apply(move)
    try:
        return old_canonical(board)
    finally:
        board.undo(move)


def new_key_after_move(board: NewBoard, move: NewMove, color: int) -> BoardKey:
    token = board.apply(move, color)
    try:
        return new_canonical(board)
    finally:
        board.undo(token)
