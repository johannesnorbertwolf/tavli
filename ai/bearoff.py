"""Exact bear-off / race equity for Plakoto.

Once neither side can ever interact again — every stack sits in its owner's home
quadrant and no checker is pinned — the game is a pure race and exactly solvable:

  1. One-sided database: for every distribution of <= 15 checkers over the 6 home
     distances (~54k states), dynamic programming over the 21 weighted dice
     outcomes yields the exact probability distribution of the number of rolls
     needed to bear off everything, under roll-minimizing play.
  2. Two-sided win probability for the player on roll:
         P(win) = sum_n P_me(n) * P(opp needs >= n rolls)

Move legality is delegated to ``domain.move_generation.legal_moves`` on a
synthetic one-sided board, so the database replicates the engine's exact rules —
including the "bear off only with the exact die value" rule, which means a race
can stall (pass rolls). Pass rolls keep the state unchanged and are handled in
closed form: P(s, n) = p_pass * P(s, n-1) + sum_{non-pass r} w_r * P(s'_r, n-1).

Roll-minimizing play is the standard one-sided approximation (true equity-optimal
play can depend on the opponent's position); its error is negligible in practice.

The full database builds in a few minutes and is cached on disk (npz). Use
``BearoffDB.load_or_build()``; the trainer builds it eagerly before spawning
self-play workers so workers only ever hit the cache.
"""

import itertools
import os
import time
from typing import Dict, List, Optional, Tuple

import numpy as np

from domain.board import Board
from domain.constants import BLACK, WHITE
from domain.dice import Dice
from domain.move_generation import legal_moves

# Truncation length of the rolls-to-finish pmf. Exact-die bear-off makes some
# states very slow: 15 checkers at distance 1 only come off via rolls containing
# a 1 (E ≈ 39 rolls) with a geometric pass tail (ratio 25/36 per roll), so the
# pmf needs ~128 slots before the truncated mass drops below the 1e-6 guard.
N_MAX = 128

_DEFAULT_DB_PATH = os.path.join("models", "bearoff_db.npz")


def _dice_outcomes(sides: int = 6) -> List[Tuple[int, int, float]]:
    outcomes = []
    for i in range(1, sides + 1):
        for j in range(i, sides + 1):
            weight = (1.0 / (sides * sides)) if i == j else (2.0 / (sides * sides))
            outcomes.append((i, j, weight))
    return outcomes


def _enumerate_states(home_size: int, max_checkers: int) -> List[Tuple[int, ...]]:
    """All count-tuples (c_1..c_home_size), sum <= max_checkers, in lex order.

    The order is the canonical row order of the database; it must be identical
    at build and load time."""
    states = []
    for counts in itertools.product(range(max_checkers + 1), repeat=home_size):
        if sum(counts) <= max_checkers:
            states.append(counts)
    return states


class BearoffDB:
    """One-sided rolls-to-finish distributions + two-sided exact win probability.

    A state is a tuple (c_1..c_home_size): c_d checkers at distance d from the
    bear-off slot. The same database serves both colors (distances are
    color-agnostic)."""

    FORMAT_VERSION = 1

    def __init__(self, pmf: np.ndarray, home_size: int, max_checkers: int):
        self.pmf = pmf  # shape (num_states, N_MAX), float32
        self.home_size = int(home_size)
        self.max_checkers = int(max_checkers)
        states = _enumerate_states(self.home_size, self.max_checkers)
        if len(states) != pmf.shape[0]:
            raise ValueError(
                f"bear-off DB shape mismatch: {len(states)} states expected, "
                f"pmf has {pmf.shape[0]} rows"
            )
        self.index: Dict[Tuple[int, ...], int] = {s: i for i, s in enumerate(states)}

    # --- queries ---

    def rolls_pmf(self, state: Tuple[int, ...]) -> np.ndarray:
        """P(exactly n rolls to bear off everything), n = 0..N_MAX-1."""
        return self.pmf[self.index[tuple(state)]]

    def expected_rolls(self, state: Tuple[int, ...]) -> float:
        p = self.rolls_pmf(state)
        return float(np.dot(p, np.arange(p.shape[0])))

    def win_prob_on_roll(self, me: Tuple[int, ...], opp: Tuple[int, ...]) -> float:
        """Exact P(the player on roll wins) for a pure-race position.

        I win iff I finish on my n-th roll and the opponent still needs >= n
        rolls (I always roll first within each round)."""
        if sum(me) == 0:
            return 1.0  # already finished (terminal; callers normally pre-handle)
        if sum(opp) == 0:
            return 0.0
        pmf_me = self.rolls_pmf(me)
        cdf_opp = np.cumsum(self.rolls_pmf(opp))
        # sum over n>=1 of P_me(n) * (1 - cdf_opp[n-1])
        return float(np.dot(pmf_me[1:], 1.0 - cdf_opp[:-1]))

    # --- construction ---

    @classmethod
    def build(cls, home_size: int = 6, max_checkers: int = 15,
              board_size: int = 24, progress: bool = False) -> "BearoffDB":
        states = _enumerate_states(home_size, max_checkers)
        index = {s: i for i, s in enumerate(states)}
        num_states = len(states)
        pmf = np.zeros((num_states, N_MAX), dtype=np.float64)
        # Exact expected rolls per state, used for the roll-minimizing policy.
        # Computed without pmf truncation: E = (1 + sum w_r E_succ) / (1 - p_pass).
        exp_rolls = np.zeros(num_states, dtype=np.float64)

        outcomes = _dice_outcomes()
        dice = Dice(6)
        # Synthetic one-sided board: Black's home is points 1..home_size and its
        # bear-off slot is 0, so a checker at distance d sits exactly at point d.
        board = Board(board_size=board_size, home_size=home_size,
                      pieces_per_player=max_checkers)

        # Process in increasing-pip order: every legal play strictly reduces
        # pips, so all non-pass successors are already solved.
        order = sorted(range(num_states), key=lambda i: _pips(states[i]))

        empty = tuple([0] * home_size)
        pmf[index[empty], 0] = 1.0

        t0 = time.perf_counter()
        for k, row in enumerate(order):
            state = states[row]
            if sum(state) == 0:
                continue

            for d in range(1, home_size + 1):
                board.set_point(d, BLACK, state[d - 1])
            board.set_point(0, BLACK, 0)
            board.borne_off[BLACK] = 0

            base = np.zeros(N_MAX, dtype=np.float64)
            p_pass = 0.0
            e_acc = 0.0
            for (d1, d2, weight) in outcomes:
                dice.set(d1, d2)
                moves = legal_moves(board, BLACK, dice)
                if not moves:
                    p_pass += weight
                    continue
                best_row = -1
                best_e = float("inf")
                seen = set()
                for move in moves:
                    token = board.apply(move, BLACK)
                    succ = tuple(board.n[d] if board.color[d] == BLACK else 0
                                 for d in range(1, home_size + 1))
                    board.undo(token)
                    if succ in seen:
                        continue
                    seen.add(succ)
                    succ_row = index[succ]
                    if exp_rolls[succ_row] < best_e:
                        best_e = exp_rolls[succ_row]
                        best_row = succ_row
                base[1:] += weight * pmf[best_row][:-1]
                e_acc += weight * best_e

            # Pass rolls repeat the same state: P(s,n) = p_pass*P(s,n-1) + base[n].
            row_pmf = pmf[row]
            row_pmf[0] = 0.0
            for n in range(1, N_MAX):
                row_pmf[n] = base[n] + p_pass * row_pmf[n - 1]
            exp_rolls[row] = (1.0 + e_acc) / (1.0 - p_pass)

            if progress and (k + 1) % 5000 == 0:
                elapsed = time.perf_counter() - t0
                print(f"  bear-off DB: {k + 1}/{num_states} states ({elapsed:.0f}s)")

        truncation = float(np.max(1.0 - pmf.sum(axis=1)))
        if truncation > 1e-6:
            raise RuntimeError(f"bear-off DB pmf truncation too large: {truncation}")
        return cls(pmf.astype(np.float32), home_size, max_checkers)

    # --- persistence ---

    def save(self, path: str) -> None:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        np.savez_compressed(
            path,
            pmf=self.pmf,
            home_size=self.home_size,
            max_checkers=self.max_checkers,
            format_version=self.FORMAT_VERSION,
        )

    @classmethod
    def load(cls, path: str) -> "BearoffDB":
        with np.load(path) as data:
            if int(data["format_version"]) != cls.FORMAT_VERSION:
                raise ValueError(f"unsupported bear-off DB format in {path}")
            return cls(data["pmf"], int(data["home_size"]), int(data["max_checkers"]))

    @classmethod
    def load_or_build(cls, path: str = _DEFAULT_DB_PATH, home_size: int = 6,
                      max_checkers: int = 15, progress: bool = True) -> "BearoffDB":
        if path and os.path.exists(path):
            return cls.load(path)
        if progress:
            print(f"Building bear-off database ({home_size} points, "
                  f"{max_checkers} checkers) — one-time, cached to {path} ...")
        t0 = time.perf_counter()
        db = cls.build(home_size=home_size, max_checkers=max_checkers, progress=progress)
        if path:
            db.save(path)
        if progress:
            print(f"Bear-off database ready in {time.perf_counter() - t0:.0f}s "
                  f"({db.pmf.shape[0]} states)")
        return db


def _pips(state: Tuple[int, ...]) -> int:
    return sum(d * c for d, c in zip(range(1, len(state) + 1), state))


def race_state(board: Board) -> Optional[Tuple[Tuple[int, ...], Tuple[int, ...]]]:
    """Return (white_counts, black_counts) by distance 1..home_size iff the
    position is an exact race: no pins anywhere and every stack inside its
    owner's home quadrant. Otherwise None.

    Those two conditions imply no future contact: White's checkers are all on
    points board_size-home_size+1.., Black's all on 1..home_size, moving apart."""
    bsize = board.board_size
    hsize = board.home_size
    white = [0] * hsize
    black = [0] * hsize
    for i in range(1, bsize + 1):
        if board.n[i] == 0:
            continue
        if board.pinned[i]:
            return None
        c = board.color[i]
        if not board.is_home(c, i):
            return None
        if c == WHITE:
            white[bsize - i] += board.n[i]  # distance = bsize + 1 - i
        else:
            black[i - 1] += board.n[i]  # distance = i
    return tuple(white), tuple(black)


def exact_value_on_roll(board: Board, persp_is_white: bool,
                        db: Optional[BearoffDB]) -> Optional[float]:
    """Exact win probability of the perspective player *assuming they are on
    roll* — the same quantity the value net answers for an encoded position.
    None when the position is not an exact race (or no DB given)."""
    if db is None:
        return None
    rs = race_state(board)
    if rs is None:
        return None
    white, black = rs
    me, opp = (white, black) if persp_is_white else (black, white)
    return db.win_prob_on_roll(me, opp)
