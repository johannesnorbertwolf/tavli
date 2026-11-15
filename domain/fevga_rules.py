"""FevgaRules: Fevga (docs/variants/fevga.md) as a RuleSet, plus its move generator.

Rules implemented (path indices, see domain/fevga_board.py):
  - one checker holds a point; no hitting, no pinning;
  - first-checker rule: a colour is *unlocked* once it has a checker at path >= 14
    or borne off. While locked, a start checker (path 1) may move only if all
    checkers are still on the start; otherwise only off-start checkers move.
    Evaluated per half-move (an unlocking first die frees the second);
  - R1: a play may not end holding all six points of the own starting table (path 1..6);
  - R2: a play may not end holding six points consecutive in the OPPONENT's path
    with no opponent checker ahead of them (none further along, none borne off);
  - bear-off only with all checkers in home (path 19..24); exact die, or a larger die
    from the rearmost (lowest path index) checker;
  - order of checks: enumerate every play sequence (and every prefix), drop the ones
    ending in an R1/R2 position, then keep only the most-dice plays, and on a
    one-die non-double play only the larger die when it is playable. None left = pass.

`fevga_legal_moves` returns one `Move` per distinct resulting position. Halves carry
physical slots in play order; on a non-double a checker that uses both dice is
merged into a single half (Plakoto notation), doubles list every step.
"""

import random
from typing import List

from domain.constants import WHITE
from domain.fevga_board import FevgaBoard, SLOT_OF, OFF_SLOT
from domain.move import HalfMove, Move
from domain.ruleset import RuleSet, register_ruleset

FEVGA = "fevga"

_UNLOCK_PATH = 14        # strictly past the opponent's start (path 13)
_HOME_FIRST = 19         # home = path 19..24
_MASK24 = (1 << 24) - 1
_LOW12 = (1 << 12) - 1
_START_TABLE = 0x3F      # path 1..6

# Additive position hash: key = sum of _Z[path] over the mover's moved checkers'
# net displacement. Two play sequences reach the same position iff same key.
_rng = random.Random(0xFE76A)
_Z = [_rng.getrandbits(61) for _ in range(26)]
del _rng


def _has_six_run(x: int) -> bool:
    return (x & (x >> 1) & (x >> 2) & (x >> 3) & (x >> 4) & (x >> 5)) != 0


def fevga_legal_moves(board: FevgaBoard, color: int, dice) -> List[Move]:
    d1 = dice.die1.value
    d2 = dice.die2.value
    ppp = board.pieces_per_player
    slot = SLOT_OF[color]
    bn = board.n
    bcol = board.color

    # Mover state in its own path coordinates.
    cnt = [0] * 26
    blocked = [False] * 26
    held = 0
    opp_front = 0           # opponent's most advanced checker, OPPONENT path index
    for p in range(1, 25):
        s = slot[p]
        k = bn[s]
        if k:
            if bcol[s] == color:
                cnt[p] = k
                held |= 1 << (p - 1)
            else:
                blocked[p] = True
                op = p + 12 if p <= 12 else p - 12
                if op > opp_front:
                    opp_front = op
    if board.borne_off[-color] > 0:
        opp_front = 25
    # R2 can only fire for a run lying wholly beyond opp_front (opponent path).
    beyond = (_MASK24 & ~((1 << opp_front) - 1)) if opp_front <= 18 else 0

    state = [held, sum(cnt[1:_HOME_FIRST]), board.borne_off[color] + sum(cnt[_UNLOCK_PATH:25])]
    # state = [held mask, checkers outside home, checkers at path>=14 or off]

    doubles = d1 == d2
    if doubles:
        max_depth = 4
    else:
        max_depth = 2
        if d1 < d2:
            d1, d2 = d2, d1          # d1 = larger die, explored first
    found = [dict() for _ in range(max_depth + 1)]
    visited = set()

    def clean(h: int) -> bool:
        if h & _START_TABLE == _START_TABLE:
            return False
        if beyond:
            rot = ((h & _LOW12) << 12) | (h >> 12)   # mover path -> opponent path bits
            if _has_six_run(rot & beyond):
                return False
        return True

    def step_targets(d: int):
        """(p, t) half-moves for die d in the current state (t = 25: bear off)."""
        out = []
        if state[2] == 0:                       # locked
            if cnt[1] == ppp:
                sources = (1,)
            else:
                sources = [p for p in range(2, 25) if cnt[p]]
        else:
            sources = [p for p in range(1, 25) if cnt[p]]
        outside = state[1]
        for p in sources:
            t = p + d
            if t <= 24:
                if blocked[t]:
                    continue
            else:
                if outside:
                    continue
                # All checkers home => unlocked => `sources` is every occupied
                # point in ascending order, so sources[0] is the rearmost checker.
                if t > 25 and p != sources[0]:
                    continue
                t = 25
            out.append((p, t))
        return out

    def rec(depth: int, key: int, halves: tuple, first_die: int, rem: tuple) -> None:
        if clean(state[0]):
            fd = found[depth]
            if key not in fd:
                fd[key] = (halves, first_die)
        if not rem:
            return
        tried = set()
        for i, d in enumerate(rem):
            if d in tried:
                continue
            tried.add(d)
            nrem = rem[:i] + rem[i + 1:]
            for p, t in step_targets(d):
                nkey = key - _Z[p] + _Z[t]
                vk = (nkey, nrem)
                if vk in visited:
                    continue
                visited.add(vk)
                # apply
                saved = (state[0], state[1], state[2])
                cnt[p] -= 1
                h = state[0]
                if cnt[p] == 0:
                    h &= ~(1 << (p - 1))
                if t <= 24:
                    if cnt[t] == 0:
                        h |= 1 << (t - 1)
                    cnt[t] += 1
                state[0] = h
                if p < _HOME_FIRST <= t:
                    state[1] -= 1
                if p < _UNLOCK_PATH <= t:
                    state[2] += 1
                rec(depth + 1, nkey, halves + ((p, t),), first_die or d, nrem)
                # undo
                if t <= 24:
                    cnt[t] -= 1
                cnt[p] += 1
                state[0], state[1], state[2] = saved

    rec(0, 0, (), 0, (d1,) * 4 if doubles else (d1, d2))

    m = max_depth
    while m > 0 and not found[m]:
        m -= 1
    if m == 0:
        return []
    cands = found[m].values()
    if m == 1 and not doubles:
        larger = [c for c in cands if c[1] == d1]
        if larger:
            cands = larger

    off = OFF_SLOT[color]
    moves = []
    for halves, _ in cands:
        if not doubles and m == 2 and halves[1][0] == halves[0][1]:
            halves = ((halves[0][0], halves[1][1]),)
        moves.append(Move(tuple(
            HalfMove(slot[p], off if t == 25 else slot[t]) for p, t in halves)))
    return moves


class FevgaRules(RuleSet):
    name = FEVGA
    default_encoder_version = "fevga_v1"   # == ai.fevga_encoder.FEVGA_V1
    supports_bearoff_db = False
    max_points = 2                 # mars (loser bore off nothing) = 2 points
    random_starting_player = True  # single game: random starter, who then rolls both dice

    legal_moves = staticmethod(fevga_legal_moves)

    def initial_board(self, config) -> FevgaBoard:
        return FevgaBoard.initial(config)

    def has_won(self, board: FevgaBoard, color: int) -> bool:
        return board.has_won(color)

    def is_open_for(self, board: FevgaBoard, i: int, color: int) -> bool:
        return board.is_open_for(i, color)

    def result_points(self, board: FevgaBoard, winner: int) -> int:
        """2 (mars) if the loser has borne off nothing, else 1."""
        return 2 if board.borne_off[-winner] == 0 else 1

    def make_encoder(self, config, version: str = None):
        from ai.fevga_encoder import FevgaEncoder  # lazy: domain must not import ai at load
        return FevgaEncoder(config, version=version or self.default_encoder_version)


register_ruleset(FevgaRules())
