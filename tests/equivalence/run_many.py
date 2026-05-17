"""CLI runner for the cross-domain equivalence test.

Usage:
    python -m tests.equivalence.run_many [num_games] [--seed N]

Plays `num_games` (default 10000) starting at the given seed. Reports
progress every 500 games and stops on the first divergence with full repro.
"""

import argparse
import sys
import time

from tests.equivalence._harness import play_one_equivalence_game, EquivalenceMismatch


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Cross-domain random-agent equivalence")
    p.add_argument("num_games", nargs="?", type=int, default=10000)
    p.add_argument("--seed", type=int, default=0, help="Starting seed (default 0)")
    p.add_argument("--progress-every", type=int, default=500)
    args = p.parse_args(argv)

    t0 = time.time()
    total_plies = 0
    for i in range(args.num_games):
        seed = args.seed + i
        try:
            plies = play_one_equivalence_game(seed)
        except EquivalenceMismatch as e:
            print(f"DIVERGENCE at seed={seed} after {i} clean games:")
            print(e)
            return 1
        total_plies += plies
        if (i + 1) % args.progress_every == 0:
            dt = time.time() - t0
            rate = (i + 1) / dt
            print(f"  {i+1}/{args.num_games} games OK "
                  f"({rate:.1f}/s, avg plies {total_plies/(i+1):.1f})")

    dt = time.time() - t0
    print(f"\nAll {args.num_games} games equivalent. "
          f"avg plies={total_plies/args.num_games:.1f} time={dt:.1f}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
