import unittest

from domain import Board, WHITE, BLACK


def _make(board_size: int = 24, home_size: int = 6, pieces: int = 15) -> Board:
    return Board(board_size=board_size, home_size=home_size, pieces_per_player=pieces)


class TestIsRace(unittest.TestCase):
    def test_initial_position_not_a_race(self):
        b = Board.initial(board_size=24, home_size=6, pieces_per_player=15)
        self.assertFalse(b.is_race())

    def test_empty_board_is_a_race(self):
        # Neither side has checkers on the board (all borne off / unplayable).
        b = _make()
        self.assertTrue(b.is_race())

    def test_pure_bear_off_is_a_race(self):
        # Both sides fully in their home boards, no overlap.
        b = _make()
        b.set_point(22, WHITE, 5)
        b.set_point(24, WHITE, 5)
        b.set_point(3, BLACK, 5)
        b.set_point(1, BLACK, 5)
        # white_min=22, black_max=3 → 22 > 3 → race.
        self.assertTrue(b.is_race())

    def test_white_blot_in_opponent_home_breaks_race(self):
        # A lagging white blot among black checkers means contact is still possible.
        b = _make()
        b.set_point(24, WHITE, 14)
        b.set_point(3, WHITE, 1)      # blot among black's home
        b.set_point(6, BLACK, 1)
        b.set_point(5, BLACK, 14)
        # white_min=3, black_max=6 → 3 > 6 false → not a race.
        self.assertFalse(b.is_race())

    def test_pinned_blot_counts_toward_its_own_color(self):
        # White pinned blot under a black stack at point 10. All other whites are at 22.
        # Without counting the pinned blot, white_min=22, black_max=10 → race.
        # With the pinned blot counted as WHITE at point 10: white_min=10, black_max=10
        # → 10 > 10 false → not a race. Correct: the pin could release and contact
        # could resume.
        b = _make()
        b.set_point(22, WHITE, 14)
        b.set_point(10, BLACK, 1, pinned=True)  # WHITE blot pinned under BLACK at 10
        b.set_point(5, BLACK, 14)
        self.assertFalse(b.is_race())

    def test_pinned_blot_inside_winners_lead_still_blocks_race(self):
        # Black blot pinned under a white stack at point 20. All other blacks are at 5.
        # Counting the black blot as BLACK at 20: white_min=20 (and the pinned BLACK
        # at 20), black_max=20 → 20 > 20 false → not a race.
        b = _make()
        b.set_point(20, WHITE, 1, pinned=True)  # BLACK blot pinned under WHITE at 20
        b.set_point(22, WHITE, 14)
        b.set_point(5, BLACK, 14)
        self.assertFalse(b.is_race())

    def test_white_far_ahead_is_race(self):
        # White all near home, black all near their home, fully separated.
        b = _make()
        b.set_point(20, WHITE, 15)
        b.set_point(4, BLACK, 15)
        self.assertTrue(b.is_race())

    def test_all_white_borne_off_with_black_still_on_board_is_race(self):
        b = _make()
        b.borne_off[WHITE] = 15
        b.set_point(5, BLACK, 15)
        # white_min sentinel stays 26 > black_max=5 → race.
        self.assertTrue(b.is_race())


if __name__ == "__main__":
    unittest.main()
