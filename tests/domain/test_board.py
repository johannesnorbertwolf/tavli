import unittest

from domain import Board, WHITE, BLACK, HalfMove, Move


def _make(board_size: int = 24, home_size: int = 6, pieces: int = 15) -> Board:
    return Board(board_size=board_size, home_size=home_size, pieces_per_player=pieces)


class TestBoardState(unittest.TestCase):
    def test_initial_position(self):
        b = Board.initial(board_size=24, home_size=6, pieces_per_player=15)
        self.assertEqual(b.n[1], 15)
        self.assertEqual(b.color[1], WHITE)
        self.assertEqual(b.n[24], 15)
        self.assertEqual(b.color[24], BLACK)
        self.assertEqual(b.borne_off[WHITE], 0)
        self.assertEqual(b.borne_off[BLACK], 0)

    def test_apply_undo_simple_move_is_symmetric(self):
        b = _make()
        b.set_point(5, WHITE, 3)
        b.set_point(6, WHITE, 1)
        snap = (b.n[:], b.color[:], b.pinned[:], dict(b.borne_off))

        token = b.apply(Move((HalfMove(5, 6),)), WHITE)
        self.assertEqual(b.n[5], 2)
        self.assertEqual(b.n[6], 2)
        self.assertEqual(b.color[6], WHITE)

        b.undo(token)
        self.assertEqual((b.n[:], b.color[:], b.pinned[:], dict(b.borne_off)), snap)

    def test_pinning_via_push(self):
        b = _make()
        b.set_point(5, WHITE, 1)
        b.set_point(6, BLACK, 1)  # a blot to be pinned
        token = b.apply(Move((HalfMove(5, 6),)), WHITE)
        self.assertEqual(b.n[6], 1)            # one owner (white) on top
        self.assertEqual(b.color[6], WHITE)
        self.assertTrue(b.pinned[6])
        self.assertTrue(b.is_captured_by(6, WHITE))
        # Pinned black can't move.
        self.assertEqual(b.movable_count(6, BLACK), 0)

        b.undo(token)
        self.assertEqual(b.n[6], 1)
        self.assertEqual(b.color[6], BLACK)
        self.assertFalse(b.pinned[6])

    def test_pin_released_when_last_owner_leaves(self):
        b = _make()
        # 6 is owned by W with 1 owner + B pinned underneath
        b.set_point(6, WHITE, 1, pinned=True)
        b.set_point(7, WHITE, 0)
        # Move 6 -> 7. The white owner leaves 6; the trapped black becomes a blot.
        token = b.apply(Move((HalfMove(6, 7),)), WHITE)
        self.assertEqual(b.n[6], 1)
        self.assertEqual(b.color[6], BLACK)
        self.assertFalse(b.pinned[6])
        self.assertEqual(b.n[7], 1)
        self.assertEqual(b.color[7], WHITE)

        b.undo(token)
        self.assertEqual(b.color[6], WHITE)
        self.assertTrue(b.pinned[6])
        self.assertEqual(b.n[7], 0)

    def test_bear_off_updates_borne_off_and_undoes(self):
        b = _make()
        b.set_point(24, WHITE, 1)
        token = b.apply(Move((HalfMove(24, 25),)), WHITE)
        self.assertEqual(b.borne_off[WHITE], 1)
        self.assertEqual(b.n[25], 1)
        self.assertEqual(b.color[25], WHITE)

        b.undo(token)
        self.assertEqual(b.borne_off[WHITE], 0)
        self.assertEqual(b.n[25], 0)
        self.assertEqual(b.n[24], 1)

    def test_count_outside_home_includes_pinned_checkers(self):
        b = _make()
        # White owns 10 with 2 whites + pinned black underneath. Black home is 1-6.
        # So the pinned black at 10 is outside-home for black.
        b.set_point(10, WHITE, 2, pinned=True)
        b.set_point(5, BLACK, 13)  # 13 blacks already in home
        self.assertEqual(b.count_outside_home(BLACK), 1)
        self.assertEqual(b.count_outside_home(WHITE), 2)

    def test_has_won_by_bear_off(self):
        b = _make()
        b.borne_off[WHITE] = 15
        self.assertTrue(b.has_won(WHITE))
        self.assertFalse(b.has_won(BLACK))

    def test_has_won_by_capturing_starting_point(self):
        b = _make()
        # White pins black's starting point (24).
        b.set_point(24, WHITE, 2, pinned=True)
        self.assertTrue(b.has_won(WHITE))
        self.assertFalse(b.has_won(BLACK))

    def test_clone_is_independent(self):
        b = Board.initial(board_size=24, home_size=6, pieces_per_player=15)
        c = b.clone()
        c.set_point(5, WHITE, 1)
        self.assertEqual(b.n[5], 0)
        self.assertEqual(c.n[5], 1)


if __name__ == "__main__":
    unittest.main()
