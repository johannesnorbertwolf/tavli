from typing import List

from domain.board import Board
from domain.constants import WHITE
from domain.dice import Dice
from domain.move import HalfMove, Move


def legal_moves(board: Board, color: int, dice: Dice) -> List[Move]:
    """Public entry point. Returns all legal Moves for (color, dice) on board.
    Matches the semantics of domain.possible_moves.PossibleMoves.find_moves."""
    if dice.is_pasch():
        return _pasch_moves(board, color, dice.die1.value)
    return _normal_moves(board, color, dice.die1.value, dice.die2.value)


# ---------- helpers shared by pasch and non-pasch ----------

def _all_halves(board: Board, color: int, die_value: int) -> List[HalfMove]:
    """All structurally-possible (src, dst) pairs for one die value.

    Validity (source owned, destination open, home rule) is checked separately
    by callers — matches the old `PossibleMoves.generate_half_moves` layering.
    """
    bsize = board.board_size
    if color == WHITE:
        from_range = range(1, bsize + 2 - die_value)
    else:
        from_range = range(die_value, bsize + 1)
    return [HalfMove(i, i + color * die_value) for i in from_range]


def _is_valid_half(board: Board, color: int, h: HalfMove) -> bool:
    return (board.n[h.src] > 0
            and board.color[h.src] == color
            and board.is_open_for(h.dst, color))


def _is_bear_off(board: Board, h: HalfMove) -> bool:
    return h.dst == 0 or h.dst == board.board_size + 1


def _outside_delta(board: Board, color: int, src: int, dst: int) -> int:
    if board.is_home(color, src):
        return 0
    if board.is_home(color, dst) or board.is_off_board(dst):
        return -1
    return 0


def _is_half_legal_with_home(board: Board, color: int, h: HalfMove,
                             outside: int) -> bool:
    if _is_bear_off(board, h):
        return outside == 0
    return True


def _is_pair_legal_in_order(board: Board, color: int,
                            first: HalfMove, second: HalfMove,
                            outside: int) -> bool:
    if not _is_half_legal_with_home(board, color, first, outside):
        return False
    after = outside + _outside_delta(board, color, first.src, first.dst)
    return _is_half_legal_with_home(board, color, second, after)


def _is_pair_legal(board: Board, color: int,
                   h1: HalfMove, h2: HalfMove, outside: int) -> bool:
    """Either order must be legal w.r.t. the bear-off home rule."""
    if _is_pair_legal_in_order(board, color, h1, h2, outside):
        return True
    return _is_pair_legal_in_order(board, color, h2, h1, outside)


# ---------- non-pasch ----------

def _normal_moves(board: Board, color: int, d1: int, d2: int) -> List[Move]:
    outside = board.count_outside_home(color)
    moves: List[Move] = []

    halves1 = _all_halves(board, color, d1)
    halves2 = _all_halves(board, color, d2)

    # Two-half pairs (skip mergeable chains; they're handled separately).
    for h1 in halves1:
        if not _is_valid_half(board, color, h1):
            continue
        for h2 in halves2:
            if not _is_valid_half(board, color, h2):
                continue
            if h1.dst == h2.src or h2.dst == h1.src:
                continue
            if not _is_pair_legal(board, color, h1, h2, outside):
                continue
            if h1.src == h2.src:
                # Same source — need two owning checkers there.
                if board.n[h1.src] < 2 or board.color[h1.src] != color:
                    continue
            moves.append(Move((h1, h2)))

    # Merged single-half jumps (one checker uses both dice).
    merged_halves = _all_halves(board, color, d1 + d2)
    for h in merged_halves:
        if not _is_valid_half(board, color, h):
            continue
        mid1 = h.src + color * d1
        mid2 = h.src + color * d2
        if not (board.is_open_for(mid1, color) or board.is_open_for(mid2, color)):
            continue
        if not _is_merged_legal_with_home(board, color, h, outside, mid1, mid2):
            continue
        moves.append(Move((h,)))

    # Rule 2: emit single-die move when playing it makes the other die unplayable.
    _emit_rule_2(board, color, moves, halves1, d2, outside)
    _emit_rule_2(board, color, moves, halves2, d1, outside)

    return moves


def _is_merged_legal_with_home(board: Board, color: int, h: HalfMove,
                               outside: int, mid1: int, mid2: int) -> bool:
    if not _is_bear_off(board, h):
        return True
    if outside == 0:
        return True
    # Bear-off with outside > 0 is only legal if one of the two split paths
    # (via mid1 or mid2) is itself a legal pair-order.
    via1a = HalfMove(h.src, mid1)
    via1b = HalfMove(mid1, h.dst)
    if _is_pair_legal_in_order(board, color, via1a, via1b, outside):
        return True
    via2a = HalfMove(h.src, mid2)
    via2b = HalfMove(mid2, h.dst)
    return _is_pair_legal_in_order(board, color, via2a, via2b, outside)


def _emit_rule_2(board: Board, color: int, moves: List[Move],
                 halves: List[HalfMove], other_die: int, outside: int) -> None:
    """For each individually valid hm whose application leaves the other die
    with no legal half-move, emit Move((hm,))."""
    for hm in halves:
        if not _is_valid_half(board, color, hm):
            continue
        if not _is_half_legal_with_home(board, color, hm, outside):
            continue
        delta = _outside_delta(board, color, hm.src, hm.dst)
        entry = board.apply_half(hm.src, hm.dst, color)
        try:
            new_outside = outside + delta
            other_halves = _all_halves(board, color, other_die)
            has_legal_other = False
            for oh in other_halves:
                if (_is_valid_half(board, color, oh)
                        and _is_half_legal_with_home(board, color, oh, new_outside)):
                    has_legal_other = True
                    break
            if not has_legal_other:
                moves.append(Move((hm,)))
        finally:
            board.undo_half(entry)


# ---------- pasch (doubles) ----------

def _pasch_moves(board: Board, color: int, die_value: int) -> List[Move]:
    """Up to 4 half-moves of the same die value. Replicates the 4-nested-loop
    in domain.possible_moves.PaschGenerator faithfully, including the
    persistent `_is_possible` flags that gate emission of shorter sequences."""
    delta = color * die_value
    bsize = board.board_size

    if color == WHITE:
        first_start = 1
        last_start = bsize - die_value + 2  # exclusive
    else:
        first_start = bsize
        last_start = die_value - 1  # exclusive (range steps by -1)

    size = bsize + 2
    movable = [board.movable_count(i, color) for i in range(size)]
    is_open = [board.is_open_for(i, color) for i in range(size)]
    outside_count = board.count_outside_home(color)

    possible_moves: List[Move] = []
    second_is_possible = False
    third_is_possible = False
    fourth_is_possible = False

    for first in range(first_start, last_start, color):
        if not _can_step(first, delta, movable, is_open, bsize, outside_count):
            continue
        outside_after_first = outside_count + _outside_delta(
            board, color, first, first + delta)
        movable[first] -= 1
        movable[first + delta] += 1

        for second in range(first, last_start, color):
            if not _can_step(second, delta, movable, is_open, bsize, outside_after_first):
                continue
            second_is_possible = True
            outside_after_second = outside_after_first + _outside_delta(
                board, color, second, second + delta)
            movable[second] -= 1
            movable[second + delta] += 1

            for third in range(second, last_start, color):
                if not _can_step(third, delta, movable, is_open, bsize, outside_after_second):
                    continue
                third_is_possible = True
                outside_after_third = outside_after_second + _outside_delta(
                    board, color, third, third + delta)
                movable[third] -= 1
                movable[third + delta] += 1

                for fourth in range(third, last_start, color):
                    if not _can_step(fourth, delta, movable, is_open, bsize, outside_after_third):
                        continue
                    fourth_is_possible = True
                    possible_moves.append(Move(tuple(
                        HalfMove(p, p + delta)
                        for p in (first, second, third, fourth)
                    )))

                if not fourth_is_possible:
                    possible_moves.append(Move(tuple(
                        HalfMove(p, p + delta)
                        for p in (first, second, third)
                    )))
                movable[third] += 1
                movable[third + delta] -= 1

            if not third_is_possible:
                possible_moves.append(Move(tuple(
                    HalfMove(p, p + delta) for p in (first, second)
                )))
            movable[second] += 1
            movable[second + delta] -= 1

        if not second_is_possible:
            possible_moves.append(Move((HalfMove(first, first + delta),)))
        movable[first] += 1
        movable[first + delta] -= 1

    return possible_moves


def _can_step(point_index: int, delta: int, movable, is_open,
              bsize: int, outside_count: int) -> bool:
    dest = point_index + delta
    if (dest == 0 or dest == bsize + 1) and outside_count > 0:
        return False
    return movable[point_index] > 0 and is_open[dest]
