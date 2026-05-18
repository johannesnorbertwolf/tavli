import unittest
from pathlib import Path

from domain import Board, Dice, HalfMove, Move, WHITE, BLACK, legal_moves
from config.config_loader import ConfigLoader


def clear(b: Board) -> None:
    for i in range(b.board_size + 2):
        b.set_point(i, 0, 0)


def with_dice(d: Dice, v1: int, v2: int) -> Dice:
    d.set(v1, v2)
    return d


class TestLegalMoves(unittest.TestCase):
    def setUp(self) -> None:
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))
        self.board = Board.initial(self.config)
        self.dice = Dice(self.config.get_die_sides())
        self.dice.set(1, 2)

    # --- ports of tests/domain/test_possible_moves.py ---

    def test_single_valid_move(self):
        # WHITE moves from initial setup with dice 1,2 — should have legal moves.
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertGreater(len(moves), 0)

    def test_combined_valid_moves(self):
        clear(self.board)
        self.board.set_point(1, WHITE, 2)
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertGreater(len(moves), 0)

    def test_no_moves_for_blocked_path(self):
        clear(self.board)
        for i in range(1, 25):
            self.board.set_point(i, BLACK, 2)
        # Put two whites somewhere they can't move (e.g. board entirely blocked).
        # In this scenario WHITE has no checkers at all, so 0 moves expected.
        # (matches the old test exactly — old code returned [] here too)
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertEqual(len(moves), 0)

    def test_two_half_moves_from_same_point_valid(self):
        clear(self.board)
        self.board.set_point(1, WHITE, 2)
        moves = legal_moves(self.board, WHITE, self.dice)
        # There exists a move whose two halves both start at 1.
        same_src = [m for m in moves if len(m.halves) == 2
                    and m.halves[0].src == 1 and m.halves[1].src == 1]
        self.assertTrue(same_src)

    def test_two_half_moves_from_same_point_invalid(self):
        clear(self.board)
        self.board.set_point(1, WHITE, 1)
        # Only one checker at 1; dice 1,2. Available: (1->2) and (1->3) and merged (1->4).
        # But same-source pair (1->2, 1->3) requires 2 checkers — illegal.
        # The merged 1->4 IS legal (intermediate 2 or 3 is open).
        # Also Rule 2 doesn't fire here (merge makes both dice playable).
        # Old test expects exactly 1 move emitted.
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertEqual(len(moves), 1)

    def test_pasch_generates_four_half_moves(self):
        with_dice(self.dice, 1, 1)
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertTrue(any(len(m.halves) == 4 for m in moves))

    def test_capture_move_is_allowed(self):
        clear(self.board)
        self.board.set_point(1, WHITE, 2)
        self.board.set_point(2, BLACK, 1)  # blot at 2 — pinnable
        with_dice(self.dice, 1, 2)
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertTrue(any(
            any(h.dst == 2 for h in m.halves) for m in moves
        ))

    def test_black_can_bear_off_to_zero(self):
        clear(self.board)
        self.board.set_point(1, BLACK, 1)
        self.board.set_point(6, BLACK, 14)
        with_dice(self.dice, 1, 2)
        moves = legal_moves(self.board, BLACK, self.dice)
        self.assertTrue(any(
            any(h.dst == 0 for h in m.halves) for m in moves
        ))

    def test_black_cannot_bear_off_if_any_checker_is_outside_home(self):
        clear(self.board)
        self.board.set_point(1, BLACK, 1)
        self.board.set_point(6, BLACK, 13)
        self.board.set_point(9, BLACK, 1)  # outside-home; dice 1,2 can't bring it home this turn
        with_dice(self.dice, 1, 2)
        moves = legal_moves(self.board, BLACK, self.dice)
        self.assertFalse(any(
            any(h.dst == 0 for h in m.halves) for m in moves
        ))

    def test_white_can_bear_off_after_entering_home_in_same_turn(self):
        clear(self.board)
        self.board.set_point(18, WHITE, 1)
        self.board.set_point(24, WHITE, 14)
        with_dice(self.dice, 1, 6)
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertTrue(any(
            any(h.src == 18 and h.dst == 25 for h in m.halves) for m in moves
        ))

    def test_rule_2_single_die_emitted_when_first_choice_blocks_second(self):
        clear(self.board)
        self.board.set_point(5, WHITE, 1)
        self.board.set_point(12, WHITE, 1)
        self.board.set_point(7, BLACK, 2)
        self.board.set_point(15, BLACK, 2)
        self.board.set_point(24, BLACK, 2)
        with_dice(self.dice, 1, 2)
        moves = legal_moves(self.board, WHITE, self.dice)

        self.assertTrue(any(
            len(m.halves) == 1 and m.halves[0].src == 12 and m.halves[0].dst == 13
            for m in moves
        ), "Expected single-die Move([12->13]) under rule #2")
        self.assertTrue(any(
            len(m.halves) == 2
            and {(m.halves[0].src, m.halves[0].dst),
                 (m.halves[1].src, m.halves[1].dst)} == {(5, 6), (12, 14)}
            for m in moves
        ), "Existing two-half pair emission should not regress")

    def test_rule_2_no_pair_still_emits_single_die(self):
        clear(self.board)
        self.board.set_point(5, WHITE, 1)
        self.board.set_point(6, BLACK, 2)  # blocks 5->6
        self.board.set_point(8, BLACK, 2)  # blocks merged 5->8
        with_dice(self.dice, 1, 2)
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertEqual(len(moves), 1)
        self.assertEqual(len(moves[0].halves), 1)
        self.assertEqual(moves[0].halves[0].src, 5)
        self.assertEqual(moves[0].halves[0].dst, 7)

    def test_rule_2_does_not_emit_single_die_when_merge_continuation_is_legal(self):
        clear(self.board)
        self.board.set_point(5, WHITE, 1)
        self.board.set_point(24, BLACK, 2)
        with_dice(self.dice, 1, 2)
        moves = legal_moves(self.board, WHITE, self.dice)
        self.assertEqual(len(moves), 1)
        self.assertEqual(len(moves[0].halves), 1)
        self.assertEqual(moves[0].halves[0].src, 5)
        self.assertEqual(moves[0].halves[0].dst, 8)


if __name__ == "__main__":
    unittest.main()
