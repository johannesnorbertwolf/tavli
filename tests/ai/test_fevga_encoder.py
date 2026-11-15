import random
import unittest
from pathlib import Path

import numpy as np

from config.config_loader import ConfigLoader
from domain.constants import WHITE as W, BLACK as B
from domain.dice import Dice
from domain.fevga_board import FevgaBoard, SLOT_OF, PATH_OF
from domain.fevga_rules import fevga_legal_moves
from domain.ruleset import get_ruleset
from ai.fevga_encoder import FevgaEncoder, FEVGA_V1

CONFIG = str(Path(__file__).resolve().parents[2] / "config" / "config-fevga.yml")


def swapped(b: FevgaBoard) -> FevgaBoard:
    """Colour-swapped twin: every checker changes colour and moves to the slot with
    the same path index for the other colour (rotation by 12)."""
    t = FevgaBoard(pieces_per_player=b.pieces_per_player)
    for s in range(1, 25):
        if b.n[s]:
            c = b.color[s]
            t.set_point(SLOT_OF[-c][PATH_OF[c][s]], -c, b.n[s])
    t.set_borne_off(W, b.borne_off[B])
    t.set_borne_off(B, b.borne_off[W])
    return t


class TestFevgaEncoder(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader(CONFIG)
        cls.enc = get_ruleset("fevga").make_encoder(cls.config)

    def test_version_and_size(self):
        self.assertIsInstance(self.enc, FevgaEncoder)
        self.assertEqual(self.enc.version, FEVGA_V1)
        self.assertEqual(self.enc.input_size, 406)
        with self.assertRaises(ValueError):
            FevgaEncoder(self.config, version="unary_v3")

    def test_initial_position(self):
        b = FevgaBoard.initial(self.config)
        x = self.enc.encode_board(b, True)
        self.assertEqual(x.dtype, np.float32)
        self.assertEqual(x.shape, (406,))
        # mover (White) 15 on path 1: owner bit 0, 15 unary ones
        self.assertEqual(x[0], 0.0)
        self.assertTrue(np.all(x[1:16] == 1.0))
        # opponent on our path 13 (slot 13)
        base = 12 * 16
        self.assertEqual(x[base], 1.0)
        self.assertTrue(np.all(x[base + 1: base + 16] == 1.0))
        f = 386
        self.assertAlmostEqual(x[f + 0], 15 * 24 / 360)   # our pips
        self.assertAlmostEqual(x[f + 2], 0.5)             # pip diff
        self.assertEqual(x[f + 3], 1.0)                   # all on start
        self.assertEqual(x[f + 5], 0.0)                   # locked
        self.assertEqual(x[f + 19], 0.0)                  # contact
        self.assertTrue(np.all((x >= 0.0) & (x <= 1.0)))
        # Starting position is colour-symmetric.
        np.testing.assert_array_equal(x, self.enc.encode_board(b, False))

    def test_colour_swap_symmetry_random_positions(self):
        rng = random.Random(5)
        dice = Dice(rng=rng)
        positions = 0
        for _ in range(20):
            b = FevgaBoard.initial(self.config)
            color = W
            while not (b.has_won(W) or b.has_won(B)):
                dice.roll()
                ms = fevga_legal_moves(b, color, dice)
                if ms:
                    b.apply(rng.choice(ms), color)
                color = -color
                tw = swapped(b)
                for white_to_move in (True, False):
                    a = self.enc.encode_board(b, white_to_move)
                    s = self.enc.encode_board(tw, not white_to_move)
                    np.testing.assert_array_equal(a, s)
                    self.assertTrue(np.all((a >= 0.0) & (a <= 1.0)))
                positions += 1
        self.assertGreater(positions, 1000)

    def test_race_flag(self):
        b = FevgaBoard(pieces_per_player=15)
        b.set_point(20, W, 15)   # White home
        b.set_point(8, B, 15)    # Black home (path 20)
        x = self.enc.encode_board(b, True)
        self.assertEqual(x[386 + 19], 1.0)
        self.assertEqual(x[386 + 17], 1.0)  # our checkers all in final quadrant


if __name__ == "__main__":
    unittest.main()
