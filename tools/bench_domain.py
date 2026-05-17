"""Microbenchmark: time legal_moves on the old vs new domain.

Three fixed positions × a fixed dice schedule. For each (position, dice)
combination, time `iterations` calls in both domains and report median, p95,
mean, and the speedup of new over old.

Usage:
    python -m tools.bench_domain [iterations]   # default 10000
"""

import argparse
import statistics
import sys
import time
from pathlib import Path
from typing import Callable, List, Tuple

from config.config_loader import ConfigLoader

from domain.board import GameBoard as OldBoard
from domain.color import Color as OldColor
from domain.dice import Dice as OldDice, Die as OldDie
from domain.point import Point as OldPoint
from domain.possible_moves import PossibleMoves as OldPossibleMoves

from domain_v2.board import Board as NewBoard
from domain_v2.dice import Dice as NewDice
from domain_v2.move_generation import legal_moves as new_legal_moves
from domain_v2.constants import WHITE, BLACK


CONFIG_PATH = Path(__file__).resolve().parents[1] / "config-test.yml"


# --- position builders ---
# Each returns (old_board, new_board, description, color, dice_schedule).

def position_opening() -> Tuple[OldBoard, NewBoard, str, int, List[Tuple[int, int]]]:
    config = ConfigLoader(str(CONFIG_PATH))
    old = OldBoard(config)
    old.initialize_board()
    new = NewBoard.initial(config)
    schedule = [(3, 1), (5, 2), (6, 4), (2, 2), (5, 5)]
    return old, new, "opening", BLACK, schedule


def position_midgame_two_pins() -> Tuple[OldBoard, NewBoard, str, int, List[Tuple[int, int]]]:
    config = ConfigLoader(str(CONFIG_PATH))
    old = OldBoard(config)
    new = NewBoard.from_config(config)

    # White owns 8 and 14 with a pinned black checker on each (pinning state),
    # plus blocking stacks. Black has 12 checkers spread around.
    def set_old(b, i, color, count, pinned=False):
        # Rebuild Point.pieces directly so pinning shape matches.
        b.points[i].pieces = []
        if pinned and count >= 1:
            b.points[i].pieces.append(OldColor.BLACK if color == OldColor.WHITE else OldColor.WHITE)
        for _ in range(count):
            b.points[i].pieces.append(color)

    layout = [
        # (point, color_int, count, pinned)
        (1, WHITE, 4, False),
        (8, WHITE, 2, True),     # white tower pinning a black
        (14, WHITE, 3, True),    # another pin
        (19, WHITE, 4, False),
        (24, BLACK, 6, False),
        (20, BLACK, 4, False),
        (13, BLACK, 2, False),
    ]
    for i, c, n, p in layout:
        new.set_point(i, c, n, pinned=p)
        old_color = OldColor.WHITE if c == WHITE else OldColor.BLACK
        set_old(old, i, old_color, n, pinned=p)

    schedule = [(6, 3), (5, 1), (4, 4), (2, 1), (3, 3)]
    return old, new, "midgame-two-pins", WHITE, schedule


def position_late_bear_off() -> Tuple[OldBoard, NewBoard, str, int, List[Tuple[int, int]]]:
    config = ConfigLoader(str(CONFIG_PATH))
    old = OldBoard(config)
    new = NewBoard.from_config(config)

    # White: 5 borne off + 10 in home (19-24). Black: 4 borne off + 11 in home (1-6).
    def set_old(b, i, color, count):
        b.points[i].pieces = [color] * count

    # White home: 19-24
    white_home = {19: 1, 20: 2, 21: 2, 22: 2, 23: 2, 24: 1}
    # Black home: 1-6
    black_home = {1: 1, 2: 2, 3: 2, 4: 2, 5: 2, 6: 2}
    # Borne off:
    white_off = 5
    black_off = 4

    for i, n in white_home.items():
        new.set_point(i, WHITE, n)
        set_old(old, i, OldColor.WHITE, n)
    for i, n in black_home.items():
        new.set_point(i, BLACK, n)
        set_old(old, i, OldColor.BLACK, n)

    new.borne_off[WHITE] = white_off
    new.borne_off[BLACK] = black_off
    new.set_point(25, WHITE, white_off)
    new.set_point(0, BLACK, black_off)
    set_old(old, 25, OldColor.WHITE, white_off)
    set_old(old, 0, OldColor.BLACK, black_off)

    schedule = [(6, 5), (3, 2), (1, 1), (6, 6), (4, 3)]
    return old, new, "late-bear-off", WHITE, schedule


def _time_calls(fn: Callable[[], None], iterations: int) -> List[float]:
    times = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        fn()
        times.append(time.perf_counter() - t0)
    return times


def _old_color(c: int):
    return OldColor.WHITE if c == WHITE else OldColor.BLACK


def _stats(times: List[float]) -> Tuple[float, float, float]:
    """Return (median_us, p95_us, mean_us)."""
    n = len(times)
    sorted_t = sorted(times)
    p95 = sorted_t[int(n * 0.95)]
    return (
        statistics.median(times) * 1e6,
        p95 * 1e6,
        statistics.mean(times) * 1e6,
    )


def bench_one_position(builder, iterations: int) -> None:
    old_board, new_board, name, color, schedule = builder()
    print(f"\n=== {name} (color={'W' if color == WHITE else 'B'}, {iterations} iters per dice) ===")
    print(f"{'dice':<8} {'old median':>11} {'new median':>11} {'speedup':>8} "
          f"{'old p95':>9} {'new p95':>9} {'old moves':>10}")
    for v1, v2 in schedule:
        old_dice = OldDice(6)
        old_dice.die1 = OldDie(6, v1)
        old_dice.die2 = OldDie(6, v2)
        new_dice = NewDice(6)
        new_dice.set(v1, v2)

        c_old = _old_color(color)

        old_call = lambda: OldPossibleMoves(old_board, c_old, old_dice).find_moves()
        new_call = lambda: new_legal_moves(new_board, color, new_dice)

        # Warmup
        for _ in range(50):
            old_call(); new_call()

        old_t = _time_calls(old_call, iterations)
        new_t = _time_calls(new_call, iterations)

        old_med, old_p95, _ = _stats(old_t)
        new_med, new_p95, _ = _stats(new_t)
        speedup = old_med / new_med if new_med > 0 else float("inf")
        nmoves = len(old_call())
        print(f"{v1},{v2:<6}{old_med:>10.1f}µs {new_med:>10.1f}µs {speedup:>7.2f}x "
              f"{old_p95:>8.1f}µs {new_p95:>8.1f}µs {nmoves:>10d}")


def main(argv=None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("iterations", nargs="?", type=int, default=10000)
    args = p.parse_args(argv)

    for builder in (position_opening, position_midgame_two_pins, position_late_bear_off):
        bench_one_position(builder, args.iterations)
    return 0


if __name__ == "__main__":
    sys.exit(main())
