import unittest
from pathlib import Path

from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from domain.move import HalfMove, Move
from play.session import PlaySession, DiceMode, Snapshot


def _config():
    return ConfigLoader(str(Path(__file__).resolve().parents[2] / "config-test.yml"))


def _new_session(dice_mode=DiceMode.AUTO, human_color=WHITE, starting_player=WHITE):
    return PlaySession(
        config=_config(),
        agent=None,
        ai_checkpoint_path="trained_model.pth",
        dice_mode=dice_mode,
        human_color=human_color,
        eval_depth=4,
        starting_player=starting_player,
    )


class TestSessionInitial(unittest.TestCase):
    def test_initial_history_has_one_snapshot(self):
        s = _new_session()
        self.assertEqual(len(s.history), 1)
        self.assertEqual(s.ply_count(), 0)
        self.assertIsInstance(s.history[0], Snapshot)
        self.assertEqual(s.history[0].next_player, WHITE)
        self.assertEqual(s.history[0].move_played, None)
        self.assertIsNone(s.current_dice())

    def test_white_starts(self):
        s = _new_session()
        self.assertEqual(s.current_player(), WHITE)


class TestUndoBasic(unittest.TestCase):
    def test_commit_then_undo_restores_board(self):
        s = _new_session()
        before = str(s.game.board)
        s.set_dice(3, 5)
        moves = s.possible_moves()
        self.assertGreater(len(moves), 0)
        s.commit_move(moves[0])
        self.assertNotEqual(str(s.game.board), before)
        popped = s.undo()
        self.assertEqual(popped, 1)
        self.assertEqual(str(s.game.board), before)
        self.assertEqual(s.current_player(), WHITE)
        self.assertEqual(s.ply_count(), 0)

    def test_undo_at_initial_is_noop(self):
        s = _new_session()
        self.assertEqual(s.undo(), 0)
        self.assertEqual(s.undo(5), 0)
        self.assertEqual(s.ply_count(), 0)

    def test_undo_caps_at_available(self):
        s = _new_session()
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])
        s.set_dice(4, 2)
        s.commit_move(s.possible_moves()[0])
        self.assertEqual(s.ply_count(), 2)
        popped = s.undo(5)
        self.assertEqual(popped, 2)
        self.assertEqual(s.ply_count(), 0)

    def test_multi_undo_pops_in_order(self):
        s = _new_session()
        boards = [str(s.game.board)]
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])
        boards.append(str(s.game.board))
        s.set_dice(4, 2)
        s.commit_move(s.possible_moves()[0])
        boards.append(str(s.game.board))

        popped = s.undo(2)
        self.assertEqual(popped, 2)
        self.assertEqual(str(s.game.board), boards[0])

    def test_commit_pass_then_undo_symmetric(self):
        s = _new_session()
        before = str(s.game.board)
        before_player = s.current_player()
        s.set_dice(3, 5)
        s.commit_pass()
        self.assertEqual(str(s.game.board), before)
        self.assertNotEqual(s.current_player(), before_player)
        self.assertEqual(s.ply_count(), 1)
        s.undo()
        self.assertEqual(s.ply_count(), 0)
        self.assertEqual(s.current_player(), before_player)


class TestUndoDicePreservation(unittest.TestCase):
    def test_auto_undo_restores_dice(self):
        s = _new_session(dice_mode=DiceMode.AUTO)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])
        self.assertIsNone(s.current_dice())
        s.undo()
        self.assertEqual(s.current_dice(), (3, 5))
        self.assertEqual(s.game.dice.die1.value, 3)
        self.assertEqual(s.game.dice.die2.value, 5)

    def test_manual_undo_clears_dice(self):
        s = _new_session(dice_mode=DiceMode.MANUAL)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])
        s.undo()
        self.assertIsNone(s.current_dice())


class TestUndoTerminal(unittest.TestCase):
    """undo from a terminal state un-ends the game (is_terminal flips false)."""

    def _setup_white_one_move_from_winning(self, s):
        """14 white already borne off, 1 white at point 23. White rolls (2,5):
        the move 23 -> 25 bears off the last piece and wins."""
        b = s.game.board
        for i in range(0, b.board_size + 2):
            b.set_point(i, 0, 0)
        b.borne_off[WHITE] = 14
        b.borne_off[BLACK] = 0
        b.set_point(23, WHITE, 1)
        b.set_point(1, BLACK, 5)

    def test_undo_unflips_terminal(self):
        s = _new_session()
        self._setup_white_one_move_from_winning(s)
        s.set_dice(2, 5)
        moves = s.possible_moves()
        winner_move = None
        for m in moves:
            token = s.game.board.apply(m, WHITE)
            won = s.game.board.has_won(WHITE)
            s.game.board.undo(token)
            if won:
                winner_move = m
                break
        self.assertIsNotNone(winner_move, "expected at least one winning move")
        s.commit_move(winner_move)
        self.assertTrue(s.is_terminal())
        self.assertEqual(s.winner(), WHITE)
        s.undo()
        self.assertFalse(s.is_terminal())
        self.assertIsNone(s.winner())


class TestUndoToMyDecision(unittest.TestCase):
    """Loop-level 'u' semantics: rewind to the human's previous decision point."""

    def test_after_human_and_ai_plies_pops_both(self):
        s = _new_session(dice_mode=DiceMode.AUTO, human_color=WHITE)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])  # human (W)
        s.set_dice(4, 6)
        s.commit_move(s.possible_moves()[0])  # AI (B)
        self.assertEqual(s.ply_count(), 2)
        popped = s.undo_to_my_decision()
        self.assertEqual(popped, 2)
        self.assertEqual(s.ply_count(), 0)
        self.assertEqual(s.current_player(), WHITE)
        # AUTO mode restores the human's original dice.
        self.assertEqual(s.current_dice(), (3, 5))

    def test_no_human_ply_yet_is_noop(self):
        # Human is BLACK; AI (white) has played one ply but the human hasn't decided.
        s = _new_session(human_color=BLACK)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])  # W (AI)
        self.assertEqual(s.ply_count(), 1)
        popped = s.undo_to_my_decision()
        self.assertEqual(popped, 0)
        self.assertEqual(s.ply_count(), 1)
        self.assertEqual(s.current_player(), BLACK)

    def test_initial_state_is_noop(self):
        s = _new_session(human_color=WHITE)
        self.assertEqual(s.undo_to_my_decision(), 0)
        self.assertEqual(s.undo_to_my_decision(5), 0)
        self.assertEqual(s.ply_count(), 0)

    def test_multi_step_unwinds_full_pairs(self):
        s = _new_session(dice_mode=DiceMode.AUTO, human_color=WHITE)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])  # W ply 1
        s.set_dice(4, 6)
        s.commit_move(s.possible_moves()[0])  # B ply 2
        s.set_dice(2, 1)
        s.commit_move(s.possible_moves()[0])  # W ply 3
        s.set_dice(5, 3)
        s.commit_move(s.possible_moves()[0])  # B ply 4
        self.assertEqual(s.ply_count(), 4)

        popped = s.undo_to_my_decision(2)
        # Two human-decision rewinds: pop (B4, W3), then (B2, W1). 4 plies total.
        self.assertEqual(popped, 4)
        self.assertEqual(s.ply_count(), 0)
        self.assertEqual(s.current_player(), WHITE)
        self.assertEqual(s.current_dice(), (3, 5))

class TestUndoPin(unittest.TestCase):
    """Undo restores a pinned checker correctly (release on top.pop)."""

    def test_undo_releases_pinned_checker(self):
        s = _new_session()
        b = s.game.board
        for i in range(0, b.board_size + 2):
            b.set_point(i, 0, 0)
        b.set_point(18, WHITE, 1)
        b.set_point(21, BLACK, 1)
        # Park more pieces so the game isn't trivially over either side.
        b.set_point(1, WHITE, 14)
        b.set_point(24, BLACK, 14)

        pin_move = Move((HalfMove(18, 21),))
        s.set_dice(3, 4)
        s.commit_move(pin_move)

        # Pin applied: point 21 owned by WHITE with a trapped BLACK; point 18 empty.
        self.assertEqual(b.n[18], 0)
        self.assertEqual((b.n[21], b.color[21], b.pinned[21]), (1, WHITE, True))

        s.undo()
        # Pin released; original layout restored.
        self.assertEqual((b.n[18], b.color[18], b.pinned[18]), (1, WHITE, False))
        self.assertEqual((b.n[21], b.color[21], b.pinned[21]), (1, BLACK, False))


if __name__ == "__main__":
    unittest.main()
