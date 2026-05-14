import unittest
from pathlib import Path
from domain.board import GameBoard
from domain.color import Color
from domain.dice import Dice, Die
from domain.possible_moves import PossibleMoves
from domain.move import Move
from domain.point import Point
from config.config_loader import ConfigLoader


class TestPossibleMoves(unittest.TestCase):
    def setUp(self) -> None:
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))
        self.board = GameBoard(self.config)
        self.board.initialize_board()
        self.dice = Dice(self.config.get_die_sides())
        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 2)
        self.color_white = Color.WHITE
        self.color_black = Color.BLACK

    def clear_board(self) -> None:
        for i in range(0, self.board.board_size + 2):
            self.board.points[i] = Point(i)

    def test_single_valid_move(self) -> None:
        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Check that there are valid moves for the initial setup and dice roll
        self.assertTrue(any(isinstance(move, Move) for move in possible_moves))
        self.assertTrue(all(move.is_valid() for move in possible_moves))

    def test_combined_valid_moves(self) -> None:
        # Manually setting up board state for more controlled tests
        self.board.points[1] = Point(1, self.color_white, 2)
        self.board.points[2] = Point(2)
        self.board.points[3] = Point(3)

        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Expect moves from point 1 to point 2 (die 1), then point 2 to point 3 (die 2)
        self.assertTrue(any(isinstance(move, Move) for move in possible_moves))
        self.assertTrue(all(move.is_valid() for move in possible_moves))

    def test_no_moves_for_blocked_path(self) -> None:
        # Block all points so no moves can be made
        for i in range(1, 25):
            self.board.points[i] = Point(i, self.color_black, 2)

        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Check that there are no valid moves when all paths are blocked
        self.assertFalse(any(isinstance(move, Move) for move in possible_moves))

    def test_two_half_moves_from_same_point_valid(self) -> None:
        # Set up the board with two checkers at point 1 for a valid double move
        self.board.points[1] = Point(1, self.color_white, 2)
        self.board.points[2] = Point(2)
        self.board.points[3] = Point(3)

        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Expect a valid move involving both half-moves starting from the same point
        self.assertTrue(any(isinstance(move, Move) for move in possible_moves))
        self.assertTrue(all(move.is_valid() for move in possible_moves))

    def test_two_half_moves_from_same_point_invalid(self) -> None:
        # Set up the board with only one checker at point 1 for an invalid double move
        self.board.points[1] = Point(1, self.color_white, 1)
        self.board.points[2] = Point(2)
        self.board.points[3] = Point(3)
        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 2)


        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()

        # Expect no valid move involving both half-moves starting from the same point
        self.assertEqual(len(possible_moves), 1)

    def test_pasch_generates_four_half_moves(self) -> None:
        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 1)
        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()
        self.assertTrue(any(len(move.half_moves) == 4 for move in possible_moves))

    def test_capture_move_is_allowed(self) -> None:
        # White can capture a single black checker
        self.board.points[1] = Point(1, self.color_white, 2)
        self.board.points[2] = Point(2, self.color_black, 1)
        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 2)

        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()
        self.assertTrue(any(
            any(half_move.to_point.position == 2 for half_move in move.half_moves)
            for move in possible_moves
        ))

    def test_black_can_bear_off_to_zero(self) -> None:
        # Black can bear off when all black checkers are in black's home board (points 1-6).
        self.clear_board()
        self.board.points[1] = Point(1, self.color_black, 1)
        self.board.points[6] = Point(6, self.color_black, 14)
        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 2)

        possible_moves_generator = PossibleMoves(self.board, self.color_black, self.dice)
        possible_moves = possible_moves_generator.find_moves()
        self.assertTrue(any(
            any(half_move.to_point.position == 0 for half_move in move.half_moves)
            for move in possible_moves
        ))

    def test_black_cannot_bear_off_if_any_checker_is_outside_home(self) -> None:
        self.clear_board()
        self.board.points[1] = Point(1, self.color_black, 1)
        self.board.points[6] = Point(6, self.color_black, 13)
        # With dice 1 and 2, a checker on 9 cannot enter home this turn (for black, home is 1-6),
        # so bearing off must remain illegal.
        self.board.points[9] = Point(9, self.color_black, 1)
        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 2)

        possible_moves_generator = PossibleMoves(self.board, self.color_black, self.dice)
        possible_moves = possible_moves_generator.find_moves()
        self.assertFalse(any(
            any(half_move.to_point.position == 0 for half_move in move.half_moves)
            for move in possible_moves
        ))

    def test_white_can_bear_off_after_entering_home_in_same_turn(self) -> None:
        self.clear_board()
        self.board.points[18] = Point(18, self.color_white, 1)
        self.board.points[24] = Point(24, self.color_white, 14)
        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 6)

        possible_moves_generator = PossibleMoves(self.board, self.color_white, self.dice)
        possible_moves = possible_moves_generator.find_moves()
        self.assertTrue(any(
            any(half_move.from_point.position == 18 and half_move.to_point.position == 25 for half_move in move.half_moves)
            for move in possible_moves
        ))

    def test_rule_2_single_die_emitted_when_first_choice_blocks_second(self) -> None:
        """Player chooses which die to play first; if that choice leaves the other
        die unplayable, the single-die move is legal — even when a different first
        choice would have allowed both dice."""
        self.clear_board()
        # Two white pieces, each one a candidate die1 source.
        self.board.points[5] = Point(5, self.color_white, 1)
        self.board.points[12] = Point(12, self.color_white, 1)
        # 7 closed kills 5->7 (die2=2). 15 closed kills 13->15 (the merge
        # continuation after playing 12->13). Result: the only valid die2 source
        # is 12, so playing 12->13 leaves die2 with no legal move anywhere.
        self.board.points[7] = Point(7, self.color_black, 2)
        self.board.points[15] = Point(15, self.color_black, 2)
        # Park black far away so the game isn't already won.
        self.board.points[24] = Point(24, self.color_black, 2)

        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 2)
        possible_moves = PossibleMoves(self.board, self.color_white, self.dice).find_moves()

        # Move([12->13]) alone must be legal under rule #2.
        self.assertTrue(any(
            len(m.half_moves) == 1
            and m.half_moves[0].from_point.position == 12
            and m.half_moves[0].to_point.position == 13
            for m in possible_moves
        ), "Expected single-die Move([12->13]) under rule #2")

        # Sanity: the existing two-half pair (5->6, 12->14) is still emitted.
        self.assertTrue(any(
            len(m.half_moves) == 2
            and {(m.half_moves[0].from_point.position, m.half_moves[0].to_point.position),
                 (m.half_moves[1].from_point.position, m.half_moves[1].to_point.position)}
                == {(5, 6), (12, 14)}
            for m in possible_moves
        ), "Existing two-half pair emission should not regress")

    def test_rule_2_no_pair_still_emits_single_die(self) -> None:
        """Regression: when no two-die sequence and no merged jump is legal but a
        single half-move is, that single-die move must still be emitted (the role
        the old `len(possible_moves) == 0` fallback used to play)."""
        self.clear_board()
        self.board.points[5] = Point(5, self.color_white, 1)
        self.board.points[6] = Point(6, self.color_black, 2)  # blocks 5->6 (die1=1)
        self.board.points[8] = Point(8, self.color_black, 2)  # blocks merged 5->8 destination

        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 2)
        possible_moves = PossibleMoves(self.board, self.color_white, self.dice).find_moves()

        self.assertEqual(len(possible_moves), 1)
        self.assertEqual(len(possible_moves[0].half_moves), 1)
        self.assertEqual(possible_moves[0].half_moves[0].from_point.position, 5)
        self.assertEqual(possible_moves[0].half_moves[0].to_point.position, 7)

    def test_rule_2_does_not_emit_single_die_when_merge_continuation_is_legal(self) -> None:
        """Regression: when the merged (die1+die2) jump is the only two-die play,
        single-die Move([5->6]) and Move([5->7]) must NOT be emitted, because the
        merge continuation makes the other die playable after either single half."""
        self.clear_board()
        self.board.points[5] = Point(5, self.color_white, 1)
        # Park black far away so the game isn't already won.
        self.board.points[24] = Point(24, self.color_black, 2)

        self.dice.die1 = Die(self.config.get_die_sides(), 1)
        self.dice.die2 = Die(self.config.get_die_sides(), 2)
        possible_moves = PossibleMoves(self.board, self.color_white, self.dice).find_moves()

        # Only the merged 5->8 jump should be returned.
        self.assertEqual(len(possible_moves), 1)
        self.assertEqual(len(possible_moves[0].half_moves), 1)
        self.assertEqual(possible_moves[0].half_moves[0].from_point.position, 5)
        self.assertEqual(possible_moves[0].half_moves[0].to_point.position, 8)


if __name__ == '__main__':
    unittest.main()
