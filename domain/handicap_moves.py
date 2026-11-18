"""House-rule Plakoto move generation with the tier-2 overshoot bear-off (#148).

`legal_moves_tier2(board, color, dice)` is the generator of the `plakoto_hc` RuleSet. It reads
the handicap from the board (`domain.handicap.HandicapBoard`):

- a plain `Board`, or a side without `overshoot`: the house generator
  (`domain.move_generation.legal_moves`) unchanged — smaller homes, safe points and checker
  counts already work through `board.is_home` / `board.is_open_for` / `board.all_borne_off`;
- a side with `overshoot`: `_overshoot_moves`, a copy of the house generator's structure
  (pairs + merged single-checker jumps + rule-2 singles; the nested pasch loop with its
  persistent "shorter sequence" flags) with one extra kind of half-move: bearing off with a die
  larger than the distance. That is legal under the standard-Plakoto rule
  (domain/plakoto_standard_moves.py): all own checkers home (an own checker pinned outside home
  blocks it, as for every bear-off) and no own checker — movable or pinned under an opponent —
  on a point farther from the bear-off slot than the source. Notation `HalfMove(src, off)`.
  Order matters (the farther checker may leave first), so pair legality is checked in each
  order on the board as it is after the first half.

Everything that is not an overshoot half follows the house generator exactly; a test pins that
the overshoot path equals the house generator wherever no overshoot half is legal.

A demoted double (`no_doubles`, non-pasch Dice with die1 == die2) runs through the non-pasch
path; duplicates are removed (as in domain/handicap.py). The overshoot path always de-duplicates
(two dice can now produce the same `(src, off)` half).
"""

from typing import List, Tuple

from domain.constants import WHITE
from domain.move import HalfMove, Move
from domain.move_generation import legal_moves as _house_legal_moves


def _dedupe(moves: List[Move]) -> List[Move]:
    seen = set()
    out = []
    for m in moves:
        key = tuple(sorted(m.halves))
        if key not in seen:
            seen.add(key)
            out.append(m)
    return out


def legal_moves_tier2(board, color: int, dice) -> List[Move]:
    """All legal moves for `color`, honouring the board's tier-2 handicap (see module doc)."""
    ov = getattr(board, "overshoot", None)
    demoted = dice.die1.value == dice.die2.value and not dice.is_pasch()
    if ov is None or not ov[color]:
        moves = _house_legal_moves(board, color, dice)
        return _dedupe(moves) if demoted else moves
    if dice.is_pasch():
        return _pasch_moves_ov(board, color, dice.die1.value)
    return _dedupe(_normal_moves_ov(board, color, dice.die1.value, dice.die2.value))


# ---------- helpers ----------

def _off(board, color: int) -> int:
    return board.board_size + 1 if color == WHITE else 0


def _farther_own(board, color: int, src: int) -> bool:
    """True iff `color` has a checker (an own stack, or one pinned under an opponent) on a
    point farther from its bear-off slot than `src`."""
    n, col, pin = board.n, board.color, board.pinned
    rng = range(1, src) if color == WHITE else range(src + 1, board.board_size + 1)
    for i in rng:
        if n[i] and (col[i] == color or (pin[i] and col[i] == -color)):
            return True
    return False


def _halves(board, color: int, d: int) -> List[Tuple[HalfMove, bool]]:
    """(half, is_overshoot) for die `d`: the house generator's exact halves, then the
    overshoot bear-offs (`src + d` beyond the bear-off slot)."""
    bs = board.board_size
    if color == WHITE:
        out = [(HalfMove(i, i + d), False) for i in range(1, bs + 2 - d)]
        out += [(HalfMove(i, bs + 1), True) for i in range(max(1, bs + 2 - d), bs + 1)]
    else:
        out = [(HalfMove(i, i - d), False) for i in range(d, bs + 1)]
        out += [(HalfMove(i, 0), True) for i in range(1, min(d, bs + 1))]
    return out


def _is_valid(board, color: int, h: HalfMove) -> bool:
    return (board.n[h.src] > 0 and board.color[h.src] == color
            and board.is_open_for(h.dst, color))


def _is_bear_off(board, h: HalfMove) -> bool:
    return h.dst == 0 or h.dst == board.board_size + 1


def _outside_delta(board, color: int, src: int, dst: int) -> int:
    if board.is_home(color, src):
        return 0
    if board.is_home(color, dst) or board.is_off_board(dst):
        return -1
    return 0


def _home_ok(board, color: int, h: HalfMove, over: bool, outside: int) -> bool:
    """Bear-off legality of `h` on the board as it is now (`outside` = own checkers outside
    home, pinned ones included)."""
    if not _is_bear_off(board, h):
        return True
    if outside:
        return False
    return not (over and _farther_own(board, color, h.src))


def _pair_ok_in_order(board, color, first, o1, second, o2, outside) -> bool:
    if not _home_ok(board, color, first, o1, outside):
        return False
    after = outside + _outside_delta(board, color, first.src, first.dst)
    if not _is_bear_off(board, second):
        return True
    if after:
        return False
    if not o2:
        return True
    entry = board.apply_half(first.src, first.dst, color)
    try:
        return not _farther_own(board, color, second.src)
    finally:
        board.undo_half(entry)


# ---------- non-pasch ----------

def _normal_moves_ov(board, color: int, d1: int, d2: int) -> List[Move]:
    outside = board.count_outside_home(color)
    off = _off(board, color)
    moves: List[Move] = []
    halves1 = _halves(board, color, d1)
    halves2 = _halves(board, color, d2)

    # Two-half pairs (chains are merged moves, below).
    for h1, o1 in halves1:
        if not _is_valid(board, color, h1):
            continue
        for h2, o2 in halves2:
            if not _is_valid(board, color, h2):
                continue
            if h1.dst == h2.src or h2.dst == h1.src:
                continue
            if not (_pair_ok_in_order(board, color, h1, o1, h2, o2, outside)
                    or _pair_ok_in_order(board, color, h2, o2, h1, o1, outside)):
                continue
            if h1.src == h2.src and (board.n[h1.src] < 2 or board.color[h1.src] != color):
                continue
            moves.append(Move((h1, h2)))

    # Merged single-checker jumps landing on the board or exactly on the bear-off slot:
    # the house generator's rule, unchanged.
    for h, over in _halves(board, color, d1 + d2):
        if over or not _is_valid(board, color, h):
            continue
        mid1 = h.src + color * d1
        mid2 = h.src + color * d2
        if not (board.is_open_for(mid1, color) or board.is_open_for(mid2, color)):
            continue
        if not _merged_exact_ok(board, color, h, outside, mid1, mid2):
            continue
        moves.append(Move((h,)))

    # Merged jumps whose second leg overshoots: src -> mid (first die, mid on the board),
    # then mid -> off with the other die larger than the remaining distance.
    bs = board.board_size
    for src in range(1, bs + 1):
        if not (board.n[src] > 0 and board.color[src] == color):
            continue
        for da, db in ((d1, d2), (d2, d1)):
            mid = src + color * da
            if not (1 <= mid <= bs):
                continue  # the first die already reaches the slot: a single, not a merge
            final = mid + color * db
            if (color == WHITE and final <= bs + 1) or (color != WHITE and final >= 0):
                continue  # exact landing / exact bear-off: handled above
            if not board.is_open_for(mid, color):
                continue
            after = outside + _outside_delta(board, color, src, mid)
            if after:
                continue
            entry = board.apply_half(src, mid, color)
            try:
                ok = not _farther_own(board, color, mid)
            finally:
                board.undo_half(entry)
            if ok:
                moves.append(Move((HalfMove(src, off),)))
                break

    # Rule 2: a single die when playing it leaves the other die unplayable.
    _emit_rule_2(board, color, moves, halves1, d2, outside)
    _emit_rule_2(board, color, moves, halves2, d1, outside)
    return moves


def _merged_exact_ok(board, color, h, outside, mid1, mid2) -> bool:
    if not _is_bear_off(board, h) or outside == 0:
        return True
    for mid in (mid1, mid2):
        if _pair_ok_in_order(board, color, HalfMove(h.src, mid), False,
                             HalfMove(mid, h.dst), False, outside):
            return True
    return False


def _emit_rule_2(board, color, moves, halves, other_die, outside) -> None:
    for hm, over in halves:
        if not _is_valid(board, color, hm):
            continue
        if not _home_ok(board, color, hm, over, outside):
            continue
        delta = _outside_delta(board, color, hm.src, hm.dst)
        entry = board.apply_half(hm.src, hm.dst, color)
        try:
            new_outside = outside + delta
            playable = False
            for oh, o_over in _halves(board, color, other_die):
                if _is_valid(board, color, oh) and _home_ok(board, color, oh, o_over, new_outside):
                    playable = True
                    break
            if not playable:
                moves.append(Move((hm,)))
        finally:
            board.undo_half(entry)


# ---------- pasch (doubles) ----------

def _pasch_moves_ov(board, color: int, d: int) -> List[Move]:
    """The house pasch generator (domain/move_generation.py `_pasch_moves`, including its
    persistent shorter-sequence flags) with sources extended to every point: a step past the
    bear-off slot is an overshoot bear-off, legal iff all own checkers are home and no own
    checker (movable now — the array tracks this turn's earlier steps — or pinned) is farther."""
    delta = color * d
    bs = board.board_size
    off = _off(board, color)
    if color == WHITE:
        first_start, last_start = 1, bs + 1          # exclusive
    else:
        first_start, last_start = bs, 0              # exclusive (steps by -1)

    size = bs + 2
    movable = [board.movable_count(i, color) for i in range(size)]
    is_open = [board.is_open_for(i, color) for i in range(size)]
    own_pinned = [bool(board.pinned[i] and board.color[i] == -color and board.n[i])
                  for i in range(size)]
    outside_count = board.count_outside_home(color)

    def dest(p):
        t = p + delta
        if color == WHITE:
            return (t, False) if t <= bs + 1 else (off, True)
        return (t, False) if t >= 0 else (off, True)

    def farther(p):
        rng = range(1, p) if color == WHITE else range(p + 1, bs + 1)
        for i in rng:
            if movable[i] > 0 or own_pinned[i]:
                return True
        return False

    def can_step(p, outside):
        t, over = dest(p)
        if t == off:
            if outside > 0:
                return False
            if over and farther(p):
                return False
        return movable[p] > 0 and is_open[t]

    def out_delta(p):
        return _outside_delta(board, color, p, dest(p)[0])

    possible: List[Move] = []
    second_ok = third_ok = fourth_ok = False

    def mv(points):
        return Move(tuple(HalfMove(p, dest(p)[0]) for p in points))

    for first in range(first_start, last_start, color):
        if not can_step(first, outside_count):
            continue
        out1 = outside_count + out_delta(first)
        t1 = dest(first)[0]
        movable[first] -= 1
        movable[t1] += 1
        for second in range(first, last_start, color):
            if not can_step(second, out1):
                continue
            second_ok = True
            out2 = out1 + out_delta(second)
            t2 = dest(second)[0]
            movable[second] -= 1
            movable[t2] += 1
            for third in range(second, last_start, color):
                if not can_step(third, out2):
                    continue
                third_ok = True
                out3 = out2 + out_delta(third)
                t3 = dest(third)[0]
                movable[third] -= 1
                movable[t3] += 1
                for fourth in range(third, last_start, color):
                    if not can_step(fourth, out3):
                        continue
                    fourth_ok = True
                    possible.append(mv((first, second, third, fourth)))
                if not fourth_ok:
                    possible.append(mv((first, second, third)))
                movable[third] += 1
                movable[t3] -= 1
            if not third_ok:
                possible.append(mv((first, second)))
            movable[second] += 1
            movable[t2] -= 1
        if not second_ok:
            possible.append(mv((first,)))
        movable[first] += 1
        movable[t1] -= 1
    return _dedupe(possible)
