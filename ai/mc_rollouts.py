"""Monte-Carlo value estimation for race endgame positions.

In a "race" state (`Board.is_race()`) no contact between players is possible,
so future moves are independent random walks toward bear-off. The TD bootstrap
target is a poor signal there (sigmoid-MLPs are bad at exact arithmetic on pip
distributions); a clean empirical win probability from random rollouts is much
better. This module exposes one function used by the self-play paths to compute
that target — see `ai/td_lambda_training.py::_ingest_trajectory` for the
injection point.
"""

import random
from typing import Optional

from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.move_generation import legal_moves

# Hard ply cap per rollout. Race rollouts are bounded by checkers × ~2 (each
# checker takes at most a handful of plies to bear off), so realistic rollouts
# finish in well under 100 plies. This is a paranoid safety net against an
# unforeseen non-terminating loop.
_MAX_PLIES_PER_ROLLOUT = 500


def maybe_mc_target(
    board: Board,
    mover_color: int,
    num_rollouts: int,
    dice_sides: int = 6,
    rng: Optional[random.Random] = None,
) -> Optional[float]:
    """Return an MC win-probability target for `mover_color` at `board`, or
    None if the position is not a race or rollouts are disabled.

    Post-terminal positions return None so the existing target=0 convention
    (see `compute_lambda_returns`) is preserved.
    """
    if num_rollouts <= 0:
        return None
    if board.has_won(WHITE) or board.has_won(BLACK):
        return None
    if not board.is_race():
        return None
    return mc_value_estimate(board, mover_color, num_rollouts, dice_sides, rng)


def mc_value_estimate(
    board: Board,
    mover_color: int,
    num_rollouts: int,
    dice_sides: int = 6,
    rng: Optional[random.Random] = None,
) -> float:
    """Estimate P(mover_color wins) from `board` with `mover_color` to play next,
    via `num_rollouts` independent random rollouts to terminal.

    Random policy: at each ply, roll dice, enumerate legal moves, pick one
    uniformly at random. If no legal move, pass. Repeat until a winner is
    decided. Race rollouts terminate quickly because every move is forward or a
    bear-off.

    `rng` is used for both dice rolls and move selection. Pass a seeded
    `random.Random` for deterministic results, or `None` to use the global
    `random` module (which the caller is responsible for seeding).
    """
    if num_rollouts <= 0:
        return 0.5
    r = rng if rng is not None else random

    wins = 0
    for _ in range(num_rollouts):
        b = board.clone()
        current = mover_color
        # Reusable Dice object: cheaper than re-allocating per ply.
        dice = Dice(sides=dice_sides)
        plies = 0
        while not (b.has_won(WHITE) or b.has_won(BLACK)):
            if plies >= _MAX_PLIES_PER_ROLLOUT:
                break
            dice.set(r.randint(1, dice_sides), r.randint(1, dice_sides))
            moves = legal_moves(b, current, dice)
            if moves:
                chosen = moves[r.randrange(len(moves))]
                b.apply(chosen, current)
            current = -current
            plies += 1
        if mover_color == WHITE and b.has_won(WHITE):
            wins += 1
        elif mover_color == BLACK and b.has_won(BLACK):
            wins += 1
    return wins / num_rollouts
