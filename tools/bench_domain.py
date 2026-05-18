"""Microbenchmark: time legal_moves on three fixed positions.

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
from domain.board import Board
from domain.dice import Dice
from domain.move_generation import legal_moves
from domain.constants import WHITE, BLACK


CONFIG_PATH = Path(__file__).resolve().parents[1] / "config-test.yml"


def position_opening() -> Tuple[Board, str, int, List[Tuple[int, int]]]:
    config = ConfigLoader(str(CONFIG_PATH))
    board = Board.initial(config)
    schedule = [(3, 1), (5, 2), (6, 4), (2, 2), (5, 5)]
    return board, "opening", BLACK, schedule


def position_midgame_two_pins() -> Tuple[Board, str, int, List[Tuple[int, int]]]:
    config = ConfigLoader(str(CONFIG_PATH))
    board = Board.from_config(config)
    layout = [
        (1, WHITE, 4, False),
        (8, WHITE, 2, True),
        (14, WHITE, 3, True),
        (19, WHITE, 4, False),
        (24, BLACK, 6, False),
        (20, BLACK, 4, False),
        (13, BLACK, 2, False),
    ]
    for i, c, n, p in layout:
        board.set_point(i, c, n, pinned=p)
    schedule = [(6, 3), (5, 1), (4, 4), (2, 1), (3, 3)]
    return board, "midgame-two-pins", WHITE, schedule


def position_late_bear_off() -> Tuple[Board, str, int, List[Tuple[int, int]]]:
    config = ConfigLoader(str(CONFIG_PATH))
    board = Board.from_config(config)
    for i, n in {19: 1, 20: 2, 21: 2, 22: 2, 23: 2, 24: 1}.items():
        board.set_point(i, WHITE, n)
    for i, n in {1: 1, 2: 2, 3: 2, 4: 2, 5: 2, 6: 2}.items():
        board.set_point(i, BLACK, n)
    board.borne_off[WHITE] = 5
    board.borne_off[BLACK] = 4
    board.set_point(25, WHITE, 5)
    board.set_point(0, BLACK, 4)
    schedule = [(6, 5), (3, 2), (1, 1), (6, 6), (4, 3)]
    return board, "late-bear-off", WHITE, schedule


def _time_calls(fn: Callable[[], None], iterations: int) -> List[float]:
    times = []
    for _ in range(iterations):
        t0 = time.perf_counter()
        fn()
        times.append(time.perf_counter() - t0)
    return times


def _stats(times: List[float]) -> Tuple[float, float, float]:
    n = len(times)
    sorted_t = sorted(times)
    p95 = sorted_t[int(n * 0.95)]
    return statistics.median(times) * 1e6, p95 * 1e6, statistics.mean(times) * 1e6


def bench_one_position(builder, iterations: int) -> None:
    board, name, color, schedule = builder()
    print(f"\n=== {name} (color={'W' if color == WHITE else 'B'}, {iterations} iters per dice) ===")
    print(f"{'dice':<8} {'median':>11} {'p95':>9} {'moves':>8}")
    for v1, v2 in schedule:
        dice = Dice(6)
        dice.set(v1, v2)
        call = lambda: legal_moves(board, color, dice)
        for _ in range(50):
            call()
        times = _time_calls(call, iterations)
        med, p95, _ = _stats(times)
        nmoves = len(call())
        print(f"{v1},{v2:<6}{med:>10.1f}µs {p95:>8.1f}µs {nmoves:>8d}")


def main(argv=None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("iterations", nargs="?", type=int, default=10000)
    args = p.parse_args(argv)
    for builder in (position_opening, position_midgame_two_pins, position_late_bear_off):
        bench_one_position(builder, args.iterations)
    return 0


if __name__ == "__main__":
    sys.exit(main())
