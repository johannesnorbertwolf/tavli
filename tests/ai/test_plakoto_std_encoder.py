import random
import unittest
from pathlib import Path

import numpy as np

from ai.board_encoder import BoardEncoder, UNARY_V3
from ai.plakoto_std_encoder import PLAKOTO_STD_V1, PlakotoStdEncoder, STD_EXTRA_FEATURES
from config.config_loader import ConfigLoader
from domain import Dice, WHITE, BLACK
from domain.plakoto_standard_board import StandardPlakotoBoard
from domain.ruleset import get_ruleset

CONFIG_PATH = str(Path(__file__).resolve().parents[2] / "config-test.yml")


def board(points):
    b = StandardPlakotoBoard()
    for p in points:
        b.set_point(p[0], p[1], p[2], pinned=len(p) > 3 and p[3])
    return b


def mirror(b):
    """Colour-swapped, reflected position (White<->Black)."""
    m = StandardPlakotoBoard()
    last = b.board_size + 1
    for i in range(last + 1):
        j = last - i
        m.n[j], m.color[j], m.pinned[j] = b.n[i], -b.color[i], b.pinned[i]
    m.borne_off = {WHITE: b.borne_off[BLACK], BLACK: b.borne_off[WHITE]}
    return m


class TestPlakotoStdEncoder(unittest.TestCase):
    def setUp(self):
        self.cfg = ConfigLoader(CONFIG_PATH)
        self.enc = get_ruleset("plakoto_standard").make_encoder(self.cfg)
        self.base = BoardEncoder(self.cfg, version=UNARY_V3)

    def test_version_and_size(self):
        self.assertIsInstance(self.enc, PlakotoStdEncoder)
        self.assertEqual(self.enc.version, PLAKOTO_STD_V1)
        self.assertEqual(self.enc.input_size, 486 + STD_EXTRA_FEATURES)
        self.assertEqual(self.enc.input_size, 494)
        with self.assertRaises(ValueError):
            PlakotoStdEncoder(self.cfg, version=UNARY_V3)

    def test_initial_position(self):
        b = get_ruleset("plakoto_standard").initial_board(self.cfg)
        v = self.enc.encode_board(b, True)
        self.assertEqual(v.dtype, np.float32)
        np.testing.assert_array_equal(v[:486], self.base.encode_board(b, True))
        np.testing.assert_array_equal(v[486:], [1, 1, 0, 0, 1, 1, 0, 0])

    def test_mother_features_e5(self):
        # After E5: both mothers pinned; White has borne off 1.
        b = board([(1, BLACK, 1, True), (20, WHITE, 13), (24, WHITE, 1, True),
                   (3, BLACK, 1), (5, BLACK, 13)])
        b.borne_off[WHITE] = 1
        w = self.enc.encode_board(b, True)[486:]
        np.testing.assert_allclose(w, [1, 1, 1, 1, 1 / 15, 1 / 15, 1, 0])
        k = self.enc.encode_board(b, False)[486:]
        np.testing.assert_allclose(k, [1, 1, 1, 1, 1 / 15, 1 / 15, 0, 1])

    def test_mother_left_start(self):
        b = board([(3, WHITE, 15), (24, BLACK, 4), (10, BLACK, 11)])
        np.testing.assert_allclose(self.enc.encode_board(b, True)[486:],
                                   [0, 1, 0, 0, 0, 4 / 15, 0, 0])

    def test_perspective_symmetry_and_prefix(self):
        rules = get_ruleset("plakoto_standard")
        rng = random.Random(5)
        b = rules.initial_board(self.cfg)
        c = WHITE
        d = Dice(6)
        for _ in range(300):
            d.roll(rng)
            ms = rules.legal_moves(b, c, d)
            if ms:
                b.apply(rng.choice(ms), c)
            if rules.is_over(b):
                b = rules.initial_board(self.cfg)
            c = -c
            v = self.enc.encode_board(b, c == WHITE)
            np.testing.assert_array_equal(v[:486], self.base.encode_board(b, c == WHITE))
            np.testing.assert_array_equal(v, self.enc.encode_board(mirror(b), c != WHITE))


if __name__ == "__main__":
    unittest.main()
