import unittest
from pathlib import Path

from config.config_loader import ConfigLoader
from domain.color import Color
from play.session import PlaySession, DiceMode


def _config():
    return ConfigLoader(str(Path(__file__).resolve().parents[2] / "config-test.yml"))


def _new_session(dice_mode):
    return PlaySession(
        config=_config(),
        agent=None,
        ai_checkpoint_path="trained_model.pth",
        dice_mode=dice_mode,
        human_color=Color.WHITE,
        eval_depth=4,
        starting_player=Color.WHITE,
    )


class TestAutoDiceMode(unittest.TestCase):
    def test_roll_populates_dice(self):
        s = _new_session(DiceMode.AUTO)
        self.assertIsNone(s.current_dice())
        d1, d2 = s.roll_dice()
        self.assertIn(d1, range(1, 7))
        self.assertIn(d2, range(1, 7))
        self.assertEqual(s.current_dice(), (d1, d2))

    def test_commit_clears_dice(self):
        s = _new_session(DiceMode.AUTO)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])
        self.assertIsNone(s.current_dice())

    def test_next_ply_rolls_again(self):
        s = _new_session(DiceMode.AUTO)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])
        d1, d2 = s.roll_dice()
        self.assertEqual(s.current_dice(), (d1, d2))


class TestManualDiceMode(unittest.TestCase):
    def test_set_dice_populates(self):
        s = _new_session(DiceMode.MANUAL)
        s.set_dice(5, 2)
        self.assertEqual(s.current_dice(), (5, 2))
        self.assertEqual(s.game.dice.die1.value, 5)
        self.assertEqual(s.game.dice.die2.value, 2)

    def test_set_dice_rejects_out_of_range(self):
        s = _new_session(DiceMode.MANUAL)
        with self.assertRaises(ValueError):
            s.set_dice(7, 2)
        with self.assertRaises(ValueError):
            s.set_dice(0, 3)

    def test_commit_clears_dice(self):
        s = _new_session(DiceMode.MANUAL)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])
        self.assertIsNone(s.current_dice())

    def test_possible_moves_requires_dice(self):
        s = _new_session(DiceMode.MANUAL)
        with self.assertRaises(RuntimeError):
            s.possible_moves()


class TestMixedSequence(unittest.TestCase):
    def test_commit_undo_resetdice_recommit_preserves_invariants(self):
        """After undo in manual mode, user enters DIFFERENT dice and plays again — the
        snapshot/dice invariant must hold (no carryover from the undone ply)."""
        s = _new_session(DiceMode.MANUAL)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])
        s.undo()
        self.assertIsNone(s.current_dice())
        # Same player to move (white, since we're back at ply 0)
        self.assertEqual(s.current_player(), Color.WHITE)

        s.set_dice(6, 1)
        moves = s.possible_moves()
        self.assertGreater(len(moves), 0)
        s.commit_move(moves[0])
        self.assertEqual(s.history[-1].dice_for_this_ply, (6, 1))
        self.assertEqual(s.ply_count(), 1)


if __name__ == "__main__":
    unittest.main()
