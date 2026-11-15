"""Legal-move generation for standard (bkgm) Plakoto.

Independent of domain/move_generation.py (the house-rule engine). Differences
(docs/variants/plakoto-standard.md, rules 7-8):

- Only plays using the maximum number of dice are legal (both dice, or as many
  of the four on doubles as possible).
- Non-double where only one die can be used: the larger die must be played if
  it can be; otherwise the smaller.
- Bearing off (all own checkers home, a checker pinned outside home blocks it):
  exact die bears off; a larger die bears off only from the highest occupied
  point (own pinned checkers count as occupying their point). Notation is
  `HalfMove(src, off_slot)` even when the die exceeds the distance.

Landing / pinning / combined moves are unchanged. Notation follows the repo
convention: a non-double play where one checker uses both dice is the merged
single half `Move((HalfMove(src, final),))`; two different checkers give two
halves in a legal sequential order; doubles give one half per die in
movement order (sources non-decreasing along the direction of play).
Moves are de-duplicated (two die orders reaching the same play yield one Move).

Implementation works in "perspective" coordinates p (the mover always moves
upward, p = 1..N points, p = N+1 off) on local arrays, never touching the board.
During our own turn the set of points open to us never changes (landing on a
blot pins it -> ours; leaving our pin reveals an opponent blot -> still open;
closed points are opponent stacks we cannot affect), so `opn` is precomputed.
"""

from typing import List

from domain.constants import WHITE
from domain.move import HalfMove, Move


def legal_moves(board, color: int, dice) -> List[Move]:
    d1 = dice.die1.value
    d2 = dice.die2.value

    N = board.board_size
    OFF = N + 1
    home_lo = N - board.home_size + 1
    bn = board.n
    bc = board.color
    bp = board.pinned
    white = color == WHITE

    mov = [0] * (OFF + 1)          # movable own checkers per perspective point
    opn = [False] * (OFF + 1)      # point open for us (constant during our turn)
    pin_ours = [False] * (OFF + 1)  # an own checker is pinned here by the opponent
    to_idx = list(range(OFF + 1)) if white else [OFF - p for p in range(OFF + 1)]
    outside = 0
    for p in range(1, OFF):
        i = p if white else OFF - p
        k = bn[i]
        if k == 0:
            opn[p] = True
        elif bc[i] == color:
            mov[p] = k
            opn[p] = True
            if p < home_lo:
                outside += k
        elif bp[i]:
            pin_ours[p] = True
            if p < home_lo:
                outside += 1
        elif k == 1:
            opn[p] = True

    def can_step(p, d, outside):
        t = p + d
        if t <= N:
            return opn[t]
        if outside:
            return False
        if t == OFF:
            return True
        # Larger die: only from the highest occupied point (all own checkers are home).
        for q in range(home_lo, p):
            if mov[q] or pin_ours[q]:
                return False
        return True

    if d1 == d2:
        return _doubles(d1, N, OFF, home_lo, mov, can_step, to_idx, outside)

    # ---- non-doubles ----
    two = {}
    singles = {d1: [], d2: []}
    for a, b in ((d1, d2), (d2, d1)):
        for p in range(1, OFF):
            if not mov[p] or not can_step(p, a, outside):
                continue
            singles[a].append(p)
            t = p + a
            if t > OFF:
                t = OFF
            mov[p] -= 1
            if t <= N:
                mov[t] += 1
            out2 = outside - 1 if (p < home_lo <= t) else outside
            for q in range(1, OFF):
                if not mov[q] or not can_step(q, b, out2):
                    continue
                u = q + b
                if u > OFF:
                    u = OFF
                if q == t or u == p:
                    # One checker's worth of net movement: p->t->u, or (other checker
                    # first) q->p->t — both are the merged single-half jump.
                    s, e = (p, u) if q == t else (q, t)
                    key = (s, e)
                    if key not in two:
                        two[key] = Move((HalfMove(to_idx[s], to_idx[e]),))
                else:
                    key = (p, t, q, u) if (p, t) <= (q, u) else (q, u, p, t)
                    if key not in two:
                        two[key] = Move((HalfMove(to_idx[p], to_idx[t]),
                                         HalfMove(to_idx[q], to_idx[u])))
            mov[p] += 1
            if t <= N:
                mov[t] -= 1
    if two:
        return list(two.values())
    big, small = (d1, d2) if d1 > d2 else (d2, d1)
    die = big if singles[big] else small
    return [Move((HalfMove(to_idx[p], to_idx[min(p + die, OFF)]),)) for p in singles[die]]


def _doubles(d, N, OFF, home_lo, mov, can_step, to_idx, outside) -> List[Move]:
    best = [0]
    found: List[tuple] = []
    seq: List[tuple] = []

    def rec(start, outside):
        extended = False
        for p in range(start, OFF):
            if not mov[p] or not can_step(p, d, outside):
                continue
            extended = True
            t = p + d
            if t > OFF:
                t = OFF
            mov[p] -= 1
            if t <= N:
                mov[t] += 1
            seq.append((p, t))
            if len(seq) == 4:
                if best[0] < 4:
                    best[0] = 4
                    found.clear()
                found.append(tuple(seq))
            else:
                rec(p, outside - 1 if (p < home_lo <= t) else outside)
            seq.pop()
            mov[p] += 1
            if t <= N:
                mov[t] -= 1
        if not extended and seq:
            L = len(seq)
            if L > best[0]:
                best[0] = L
                found.clear()
            if L == best[0]:
                found.append(tuple(seq))

    rec(1, outside)
    return [Move(tuple(HalfMove(to_idx[p], to_idx[t]) for p, t in s)) for s in found]
