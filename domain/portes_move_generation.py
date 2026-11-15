"""Portes legal-move generation (issue #137, spec: docs/variants/portes.md).

`legal_moves(board, color, dice)` returns every legal `Move` for `color`, one per
distinct resulting position (rule: legal-move sets are sets of positions). A
checker using both dice is two separate halves (`(10->14, 14->15)`), never a
merged jump, because hitting on the intermediate point changes the result.

Algorithm: copy the board once into a mover-relative array `q` (own checkers
positive, opponent negative; relative point r = pips to bear off, r = 25 is the
own bar, r <= 0 is off), then depth-first search over the dice sequence(s) on
`q` in place:

- non-doubles: both orders (d1, d2) and (d2, d1);
- doubles: four times the same die, with the source point non-increasing across
  halves. This loses no position: Portes half-moves of one roll commute when
  re-ordered back-to-front (a lower checker can never enable a higher one).

Leaves are recorded by resulting position; only sequences using the maximum
number of dice `M` survive, and if `M == 1` on a non-double the larger die must
be played when it can (rule 8). Bar entry first, bear-off only with all 15 home,
and the larger-die-from-the-highest-point bear-off are enforced in `_steps`.
"""

from typing import List

from domain.constants import WHITE
from domain.move import HalfMove, Move


def _to_relative(p: List[int], color: int) -> List[int]:
    """q[r] for r in 1..24 = own (>0) / opponent (<0) checkers r pips from bearing
    off; q[25] = own bar count; q[0] unused."""
    if color == WHITE:
        q = p[::-1]                  # q[r] = p[25 - r]; q[25] = p[0] = White's bar
    else:
        q = [-v for v in p]          # q[r] = -p[r];     q[25] = -p[25] = Black's bar
    q[0] = 0                         # the opponent's bar is irrelevant to the mover
    return q


def legal_moves(board, color: int, dice) -> List[Move]:
    d1 = dice.die1.value
    d2 = dice.die2.value
    q = _to_relative(board.p, color)
    outside = 0
    for r in range(7, 26):
        v = q[r]
        if v > 0:
            outside += v

    # key -> list of (src_rel, dst_rel) halves; best[0] = max halves seen
    found = {}
    best = [0]
    halves: List[tuple] = []

    def record(die_if_single):
        n = len(halves)
        if n < best[0]:
            return
        if n > best[0]:
            best[0] = n
            found.clear()
        key = tuple(q)
        if n == 1:
            key = (die_if_single,) + key
        if key not in found:
            found[key] = (die_if_single, tuple(halves))

    def rec(seq, idx, outside, max_src, doubles):
        d = seq[idx]
        moved = False
        if q[25] > 0:
            # Bar entry obligation: the only legal source while the bar is occupied.
            dst = 25 - d
            if q[dst] >= -1:
                srcs = ((25, dst),)
            else:
                srcs = ()
        else:
            srcs = _steps(q, d, outside, max_src)
        for src, dst in srcs:
            # apply on q
            q[src] -= 1
            hit = False
            if dst >= 1:
                if q[dst] == -1:
                    q[dst] = 1
                    hit = True
                else:
                    q[dst] += 1
            new_outside = outside - 1 if (src > 6 and dst <= 6) else outside
            halves.append((src, dst))
            if idx + 1 < len(seq):
                rec(seq, idx + 1, new_outside, src if doubles else 25, doubles)
            else:
                record(d)
            halves.pop()
            # undo on q
            if dst >= 1:
                if hit:
                    q[dst] = -1
                else:
                    q[dst] -= 1
            q[src] += 1
            moved = True
        if not moved and idx > 0:
            record(seq[0] if idx == 1 else 0)

    if d1 == d2:
        rec((d1, d1, d1, d1), 0, outside, 25, True)
    else:
        rec((d1, d2), 0, outside, 25, False)
        rec((d2, d1), 0, outside, 25, False)

    if not found:
        return []
    entries = list(found.values())
    if best[0] == 1 and d1 != d2:
        big = d1 if d1 > d2 else d2
        larger = [e for e in entries if e[0] == big]
        if larger:
            entries = larger

    out = []
    if color == WHITE:
        for _, hs in entries:
            out.append(Move(tuple(HalfMove(25 - s, 25 - (t if t > 0 else 0)) for s, t in hs)))
    else:
        for _, hs in entries:
            out.append(Move(tuple(HalfMove(s, t if t > 0 else 0) for s, t in hs)))
    return out


def _steps(q, d, outside, max_src):
    """Legal (src, dst) for one die `d` with no checker on the bar; sources are
    limited to `src <= max_src` (doubles ordering)."""
    res = []
    top = max_src if max_src < 24 else 24
    for src in range(top, 0, -1):
        if q[src] <= 0:
            continue
        dst = src - d
        if dst >= 1:
            if q[dst] >= -1:
                res.append((src, dst))
        elif outside == 0:
            if dst == 0:
                res.append((src, 0))
            else:
                # Larger die: bear off only from the highest occupied point.
                ok = True
                for k in range(src + 1, 7):
                    if q[k] > 0:
                        ok = False
                        break
                if ok:
                    res.append((src, dst))
    return res
