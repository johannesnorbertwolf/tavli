"""Portes encoder `portes_v1` (#137): layout, mirror symmetry, feature spot checks."""

import random
import unittest
from pathlib import Path

import numpy as np

from ai.portes_encoder import PortesEncoder, INPUT_SIZE
from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.portes_board import PortesBoard
from domain.portes_move_generation import legal_moves
from domain.ruleset import get_ruleset

CONFIG_PATH = str(Path(__file__).resolve().parents[2] / "config" / "config-portes.yml")
SMART = 396


def mirror(b: PortesBoard) -> PortesBoard:
    """Colour-mirrored twin: White's checker on slot i becomes Black's on 25 - i."""
    m = PortesBoard()
    m.p = [-b.p[25 - i] for i in range(26)]
    m.borne_off = {WHITE: b.borne_off[BLACK], BLACK: b.borne_off[WHITE]}
    return m


def random_game_positions(n_games=20, seed=5):
    rng = random.Random(seed)
    out = []
    for _ in range(n_games):
        b = PortesBoard.initial()
        c = WHITE
        dice = Dice()
        while not (b.has_won(WHITE) or b.has_won(BLACK)):
            out.append((b.clone(), c))
            dice.set(rng.randint(1, 6), rng.randint(1, 6))
            ms = legal_moves(b, c, dice)
            if ms:
                b.apply(rng.choice(ms), c)
            c = -c
    return out


class TestPortesEncoder(unittest.TestCase):
    def setUp(self):
        self.config = ConfigLoader(CONFIG_PATH)
        self.enc = get_ruleset("portes").make_encoder(self.config)

    def test_size_and_version(self):
        self.assertIsInstance(self.enc, PortesEncoder)
        self.assertEqual(self.enc.version, "portes_v1")
        self.assertEqual(self.enc.input_size, 414)
        self.assertEqual(INPUT_SIZE, 414)
        x = self.enc.encode_board(PortesBoard.initial(), True)
        self.assertEqual(x.shape, (414,))
        self.assertEqual(x.dtype, np.float32)

    def test_mirror_symmetry(self):
        for b, c in random_game_positions():
            x = self.enc.encode_board(b, c == WHITE)
            y = self.enc.encode_board(mirror(b), c != WHITE)
            np.testing.assert_array_equal(x, y)
            self.assertTrue(np.all(x >= 0.0) and np.all(x <= 1.0))

    def test_mirror_symmetry_of_legal_moves(self):
        dice = Dice()
        for b, c in random_game_positions(n_games=5, seed=11)[::7]:
            for d1 in range(1, 7):
                for d2 in range(d1, 7):
                    dice.set(d1, d2)
                    a = set()
                    for m in legal_moves(b, c, dice):
                        t = b.apply(m, c); a.add(mirror(b).key()); b.undo(t)
                    mb = mirror(b)
                    z = set()
                    for m in legal_moves(mb, -c, dice):
                        t = mb.apply(m, -c); z.add(mb.key()); mb.undo(t)
                    self.assertEqual(a, z)

    def test_initial_features(self):
        x = self.enc.encode_board(PortesBoard.initial(), True)
        # White's r=6 is slot 19 with 5 own checkers.
        base = (6 - 1) * 16
        self.assertEqual(x[base], 1.0)
        np.testing.assert_array_equal(x[base + 1: base + 16], [1] * 5 + [0] * 10)
        # r=19 (slot 6) holds 5 opponent checkers: owner bit 0, unary 5.
        base = (19 - 1) * 16
        self.assertEqual(x[base], 0.0)
        self.assertEqual(x[base + 1: base + 16].sum(), 5)
        s = x[SMART:]
        self.assertAlmostEqual(s[0], 167 / 375, places=6)
        self.assertAlmostEqual(s[2], 0.5)
        self.assertEqual(s[3], 0.0)                        # no blots
        self.assertAlmostEqual(s[5], 4 / 7, places=6)      # made points 1, 12, 17, 19
        self.assertAlmostEqual(s[9], 1 / 6, places=6)      # 1 home-board point
        self.assertAlmostEqual(s[11], 2 / 15, places=6)    # back checkers
        self.assertEqual(s[15], 0.0)                       # contact

    def test_bar_race_and_exposure(self):
        # White: 1 on bar, a blot on slot 20; Black's blot on slot 22 hits it with a 2.
        b = PortesBoard.from_counts({0: 1, 20: 1, 24: 13}, {22: 1, 1: 14})
        x = self.enc.encode_board(b, True)
        s = x[SMART:]
        np.testing.assert_array_equal(x[384:389], [1, 0, 0, 0, 0])     # own bar 1
        self.assertAlmostEqual(s[13], 1 / 15, places=6)
        self.assertAlmostEqual(s[16], 1 / 15, places=6)   # White blot on 20 exposed to 22
        self.assertAlmostEqual(s[3], 1 / 15, places=6)    # own blots (bar excluded)
        self.assertEqual(s[15], 0.0)                      # bar checker still has contact
        race = PortesBoard.from_counts({20: 15}, {4: 15})
        self.assertEqual(self.enc.encode_board(race, True)[SMART + 15], 1.0)

    def test_bar_overflow(self):
        b = PortesBoard.from_counts({0: 6, 24: 9}, {1: 15})
        x = self.enc.encode_board(b, True)
        np.testing.assert_allclose(x[384:389], [1, 1, 1, 1, 2 / 11], rtol=1e-6)


if __name__ == "__main__":
    unittest.main()
