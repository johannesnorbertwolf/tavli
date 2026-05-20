import random
import unittest

from ai.mc_rollouts import mc_value_estimate
from domain import Board, WHITE, BLACK


def _make(board_size: int = 24, home_size: int = 6, pieces: int = 15) -> Board:
    return Board(board_size=board_size, home_size=home_size, pieces_per_player=pieces)


class TestMcValueEstimate(unittest.TestCase):
    def test_already_won_white_returns_one_for_white(self):
        # White has all 15 checkers borne off; black still has pieces but the
        # game is already over.
        b = _make()
        b.borne_off[WHITE] = 15
        b.set_point(5, BLACK, 15)
        rng = random.Random(0)
        self.assertEqual(mc_value_estimate(b, WHITE, num_rollouts=10, rng=rng), 1.0)

    def test_already_won_white_returns_zero_for_black(self):
        b = _make()
        b.borne_off[WHITE] = 15
        b.set_point(5, BLACK, 15)
        rng = random.Random(0)
        self.assertEqual(mc_value_estimate(b, BLACK, num_rollouts=10, rng=rng), 0.0)

    def test_one_checker_each_side_white_to_move_has_first_move_edge(self):
        # White has one checker remaining at point 24 (needs an exact die=1 to
        # bear off). Black symmetric on point 1. Both need 14 already borne off
        # but pieces_per_player=15 keeps the game live until the last bear-off.
        # White moves first → modest advantage.
        b = _make(pieces=15)
        b.borne_off[WHITE] = 14
        b.borne_off[BLACK] = 14
        b.set_point(24, WHITE, 1)
        b.set_point(1, BLACK, 1)
        rng = random.Random(42)
        p = mc_value_estimate(b, WHITE, num_rollouts=400, rng=rng)
        # P(any die == 1) = 11/36 ≈ 0.306. White goes first; if white succeeds
        # we win, else black gets a chance, etc. Expected ≈ 0.56. Loose window.
        self.assertGreater(p, 0.45)
        self.assertLess(p, 0.75)

    def test_winning_race_for_white_returns_close_to_one(self):
        # White has all 15 checkers home (need to bear off); Black has 15 deep
        # in their start area. They are racing; White is much closer to bearing
        # off. Random rollouts should overwhelmingly favor White.
        b = _make()
        b.set_point(20, WHITE, 15)
        b.set_point(24, BLACK, 15)
        rng = random.Random(7)
        p = mc_value_estimate(b, WHITE, num_rollouts=200, rng=rng)
        self.assertGreater(p, 0.9)

    def test_num_rollouts_zero_returns_neutral(self):
        b = _make()
        b.set_point(20, WHITE, 15)
        b.set_point(4, BLACK, 15)
        self.assertEqual(mc_value_estimate(b, WHITE, num_rollouts=0), 0.5)


if __name__ == "__main__":
    unittest.main()
