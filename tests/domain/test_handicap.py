"""Handicap layer (#148 phase 1): dice, tempo, positions and per-side home geometry."""

import random
import unittest
from collections import Counter
from pathlib import Path

from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.handicap import (
    HandicapBoard, HandicapSpec, HandicappedPlakotoRules, KINDS, face,
    make_handicapped_rules, parse_spec, pass_schedule,
)
from domain.move import HalfMove, Move
from domain.move_generation import legal_moves
from domain.ruleset import get_ruleset

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ConfigLoader(str(ROOT / "config-test.yml"))


def rules(*texts, side=WHITE):
    return make_handicapped_rules([parse_spec(t, side) for t in texts])


def roll_hist(r, color, n=20000, seed=1):
    rng = random.Random(seed)
    faces, pasch = Counter(), 0
    for _ in range(n):
        d = r.roll(color, rng.random(), rng.random(), rng.random(), rng.random())
        faces[d.die1.value] += 1
        faces[d.die2.value] += 1
        pasch += d.is_pasch()
    return faces, pasch / n


class TestSpec(unittest.TestCase):
    def test_no_handicap_is_plain_singleton(self):
        self.assertIs(make_handicapped_rules([]), get_ruleset("plakoto"))

    def test_bonus_kinds_target_opponent(self):
        self.assertEqual(HandicapSpec("pre_borne", 2, WHITE).target, BLACK)
        self.assertEqual(HandicapSpec("dice_ceiling", 5, WHITE).target, WHITE)

    def test_invalid(self):
        with self.assertRaises(ValueError):
            HandicapSpec("nope", 1)
        with self.assertRaises(ValueError):
            HandicapSpec("dice_ceiling", 7)
        with self.assertRaises(ValueError):
            HandicapSpec("no_doubles", 1.5)

    def test_parse(self):
        s = parse_spec("dice_ceiling:5", BLACK)
        self.assertEqual((s.kind, s.intensity, s.side), ("dice_ceiling", 5, BLACK))
        self.assertEqual(parse_spec("first_mover").intensity, 1)

    def test_every_kind_builds(self):
        for kind, info in KINDS.items():
            for x in info.intensities:
                r = make_handicapped_rules([HandicapSpec(kind, x, BLACK)])
                b = r.initial_board(CONFIG)
                for c in (WHITE, BLACK):
                    on = sum(b.n[i] for i in range(1, 25) if b.color[i] == c)
                    self.assertEqual(on + b.borne_off[c], 15, (kind, x))


class TestDice(unittest.TestCase):
    def test_face_mapping(self):
        self.assertEqual([face(u) for u in (0.0, 0.17, 0.5, 0.999)], [1, 2, 4, 6])
        self.assertEqual(face(0.999, 1, 4), 4)
        self.assertEqual(face(0.0, 3, 6), 3)

    def test_unhandicapped_side_is_fair(self):
        faces, pasch = roll_hist(rules("dice_ceiling:4"), BLACK)
        self.assertEqual(sorted(faces), [1, 2, 3, 4, 5, 6])
        self.assertAlmostEqual(pasch, 1 / 6, delta=0.015)

    def test_ceiling(self):
        faces, pasch = roll_hist(rules("dice_ceiling:4"), WHITE)
        self.assertEqual(sorted(faces), [1, 2, 3, 4])
        for f in range(1, 5):
            self.assertAlmostEqual(faces[f] / 40000, 0.25, delta=0.015)
        self.assertAlmostEqual(pasch, 0.25, delta=0.015)

    def test_floor_applies_to_opponent(self):
        r = rules("dice_floor:3")  # handicapped White -> Black gets the floor
        self.assertEqual(sorted(roll_hist(r, BLACK)[0]), [3, 4, 5, 6])
        self.assertEqual(sorted(roll_hist(r, WHITE)[0]), [1, 2, 3, 4, 5, 6])

    def test_forced_low(self):
        r = rules("forced_low:0.5")
        rng = random.Random(3)
        ones = 0
        for _ in range(20000):
            d = r.roll(WHITE, rng.random(), rng.random(), rng.random(), rng.random())
            ones += d.die2.value == 1
        # P(die2 == 1) = 0.5 + 0.5/6
        self.assertAlmostEqual(ones / 20000, 0.5 + 0.5 / 6, delta=0.015)
        d = r.roll(WHITE, 0.99, 0.99, 0.0, 0.9)
        self.assertEqual((d.die1.value, d.die2.value), (6, 1))

    def test_no_doubles(self):
        r = rules("no_doubles:1.0")
        _, pasch = roll_hist(r, WHITE)
        self.assertEqual(pasch, 0.0)
        d = r.roll(WHITE, 0.5, 0.5, 0.9, 0.9)
        self.assertEqual((d.die1.value, d.die2.value), (4, 4))
        self.assertFalse(d.is_pasch())
        self.assertAlmostEqual(roll_hist(rules("no_doubles:0.5"), WHITE)[1], 1 / 12, delta=0.01)

    def test_demoted_double_plays_two_dice(self):
        r = rules("no_doubles:1.0")
        board = Board.initial(CONFIG)
        d = r.roll(WHITE, 0.5, 0.5, 0.9, 0.0)  # 4-4 demoted
        moves = r.legal_moves(board, WHITE, d)
        self.assertEqual(sorted(map(repr, moves)), ["(1->5, 1->5)", "(1->9)"])
        self.assertTrue(all(len(m.halves) <= 2 for m in moves))
        # Mid-game: no duplicates, every move uses at most two dice of 4.
        board.set_point(1, WHITE, 10)
        board.set_point(7, WHITE, 3)
        board.set_point(11, BLACK, 1)
        board.set_point(15, WHITE, 2)
        board.set_point(24, BLACK, 15)
        moves = r.legal_moves(board, WHITE, d)
        keys = [tuple(sorted(m.halves)) for m in moves]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertIn(Move((HalfMove(7, 11), HalfMove(15, 19))), moves)

    def test_plain_doubles_unchanged_without_demotion(self):
        r = rules("no_doubles:0.0")
        d = r.roll(WHITE, 0.5, 0.5, 0.9, 0.0)
        self.assertTrue(d.is_pasch())
        board = Board.initial(CONFIG)
        self.assertEqual(r.legal_moves(board, WHITE, d), legal_moves(board, WHITE, d))


class TestTempo(unittest.TestCase):
    def test_pass_schedule_even(self):
        self.assertEqual(pass_schedule(1, 40), {20})
        self.assertEqual(pass_schedule(4, 40), {8, 16, 24, 32})
        r = rules("pass_turns:2", side=BLACK)
        skipped = [t for t in range(1, 60) if r.skips_turn(BLACK, t)]
        self.assertEqual(skipped, sorted(pass_schedule(2)))
        self.assertFalse(any(r.skips_turn(WHITE, t) for t in range(1, 60)))

    def test_first_mover(self):
        self.assertEqual(rules("first_mover", side=WHITE).first_mover(WHITE), BLACK)
        self.assertEqual(rules("first_mover", side=BLACK).first_mover(WHITE), WHITE)
        self.assertEqual(rules("dice_ceiling:5").first_mover(BLACK), BLACK)


class TestPositions(unittest.TestCase):
    def test_pre_borne(self):
        b = rules("pre_borne:3", side=WHITE).initial_board(CONFIG)  # Black gets it
        self.assertEqual(b.borne_off, {WHITE: 0, BLACK: 3})
        self.assertEqual((b.n[0], b.color[0]), (3, BLACK))
        self.assertEqual((b.n[24], b.color[24]), (12, BLACK))
        self.assertEqual((b.n[1], b.color[1]), (15, WHITE))
        # Win = the remaining 12 off: undo/apply round-trip keeps the count.
        b2 = b.clone()
        b2.set_point(24, 0, 0)
        b2.set_point(0, BLACK, 15)
        b2.borne_off[BLACK] = 15
        self.assertTrue(b2.has_won(BLACK))

    def test_pip_headstart(self):
        b = rules("pip_headstart:2", side=BLACK).initial_board(CONFIG)  # White gets it
        self.assertEqual((b.n[1], b.n[7], b.color[7]), (13, 2, WHITE))
        b = rules("pip_headstart:1", side=WHITE).initial_board(CONFIG)  # Black gets it
        self.assertEqual((b.n[24], b.n[18], b.color[18]), (14, 1, BLACK))


class TestHouseSize(unittest.TestCase):
    def _race(self, board):
        board.set_point(3, BLACK, 15)  # Black out of the way
        return board

    def test_smaller_house_blocks_bear_off(self):
        r = rules("smaller_house:4", side=WHITE)
        b = self._race(r.initial_board(CONFIG))
        self.assertIsInstance(b, HandicapBoard)
        b.set_point(1, 0, 0)
        b.set_point(19, WHITE, 1)   # outside a 4-point home (21..24)
        b.set_point(23, WHITE, 14)
        dice = Dice(); dice.set(2, 1)
        moves = r.legal_moves(b, WHITE, dice)
        self.assertNotIn(Move((HalfMove(23, 25), HalfMove(19, 20))), moves)
        self.assertTrue(all(h.dst != 25 for m in moves for h in m.halves))
        # On the plain board the same position may bear off.
        p = Board.initial(CONFIG); self._race(p); p.set_point(1, 0, 0)
        p.set_point(19, WHITE, 1); p.set_point(23, WHITE, 14)
        self.assertIn(Move((HalfMove(23, 25), HalfMove(19, 20))), legal_moves(p, WHITE, dice))
        self.assertEqual(b.home_black, 6)

    def test_larger_house_allows_bear_off(self):
        r = rules("larger_house:8", side=BLACK)  # White gets an 8-point home (17..24)
        target = Move((HalfMove(24, 25), HalfMove(17, 19)))
        dice = Dice(); dice.set(1, 2)
        b = self._race(r.initial_board(CONFIG))
        p = self._race(Board.initial(CONFIG))
        for board in (b, p):
            board.set_point(1, 0, 0)
            board.set_point(17, WHITE, 2)   # two checkers on the 8-point
            board.set_point(24, WHITE, 13)
        self.assertIn(target, r.legal_moves(b, WHITE, dice))
        # Plain 6-point home: the other 17 checker is still outside -> no bear-off.
        self.assertNotIn(target, legal_moves(p, WHITE, dice))

    def test_clone_keeps_geometry(self):
        b = HandicapBoard(home_white=4, home_black=8)
        c = b.clone()
        self.assertEqual((type(c), c.home_white, c.home_black), (HandicapBoard, 4, 8))
        self.assertTrue(c.is_home(BLACK, 8) and not c.is_home(WHITE, 20))


if __name__ == "__main__":
    unittest.main()
