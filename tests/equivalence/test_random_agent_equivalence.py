import os
import unittest

from tests.equivalence._harness import play_one_equivalence_game


# Default is small so the test fits in CI; the full 10K run is exposed via
# `python -m tests.equivalence.run_many <n>`.
CI_DEFAULT_GAMES = 200


class TestRandomAgentEquivalence(unittest.TestCase):
    def test_n_games_equivalent(self):
        n = int(os.environ.get("EQUIV_GAMES", CI_DEFAULT_GAMES))
        first_seed = int(os.environ.get("EQUIV_SEED", "0"))
        total_plies = 0
        for i in range(n):
            seed = first_seed + i
            try:
                plies = play_one_equivalence_game(seed)
            except Exception as e:
                self.fail(f"seed={seed} failed:\n{e}")
            total_plies += plies
        avg = total_plies / max(n, 1)
        print(f"\n[equivalence] {n} games OK, avg plies {avg:.1f}")


if __name__ == "__main__":
    unittest.main()
