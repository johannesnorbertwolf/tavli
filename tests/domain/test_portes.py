"""Portes rules (#137): worked examples from docs/variants/portes.md, an
independent brute-force cross-check of the move generator, apply/undo fuzz,
and full-game invariants."""

import random
import unittest
from pathlib import Path

from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.move import HalfMove, Move
from domain.portes_board import PortesBoard
from domain.portes_move_generation import legal_moves
from domain.ruleset import get_ruleset

CONFIG_PATH = str(Path(__file__).resolve().parents[2] / "config" / "config-portes.yml")


def board(white, black, white_off=0, black_off=0):
    b = PortesBoard.from_counts(white, black, white_off, black_off)
    assert b.total(WHITE) == 15 and b.total(BLACK) == 15, b
    return b


def moves(b, c, d1, d2):
    d = Dice()
    d.set(d1, d2)
    return legal_moves(b, c, d)


def mv(*pairs):
    return Move(tuple(HalfMove(s, t) for s, t in pairs))


def result_keys(b, c, ms):
    out = []
    for m in ms:
        t = b.apply(m, c)
        out.append(b.key())
        b.undo(t)
    return out


# --- independent reference generator (absolute coords, all orderings) ---

def _ref_steps(b, c, d):
    p = b.p
    bar_slot = 0 if c == WHITE else 25
    if p[bar_slot] * c > 0:
        dst = bar_slot + c * d
        return [(bar_slot, dst)] if p[dst] * c >= -1 else []
    outside = 0
    for i in range(26):
        home = 19 <= i <= 24 if c == WHITE else 1 <= i <= 6
        if not home and p[i] * c > 0:
            outside += p[i] * c
    res = []
    for src in range(1, 25):
        if p[src] * c <= 0:
            continue
        dst = src + c * d
        if 1 <= dst <= 24:
            if p[dst] * c >= -1:
                res.append((src, dst))
            continue
        if outside:
            continue
        off = 25 if c == WHITE else 0
        if dst == off:
            res.append((src, off))
        else:
            farther = range(19, src) if c == WHITE else range(src + 1, 7)
            if all(p[k] * c <= 0 for k in farther):
                res.append((src, off))
    return res


def ref_positions(b, c, d1, d2):
    seqs = [(d1,) * 4] if d1 == d2 else [(d1, d2), (d2, d1)]
    found = {}  # (n, die_if_single, key)

    def rec(seq, i, used):
        steps = _ref_steps(b, c, seq[i]) if i < len(seq) else []
        if not steps:
            if used:
                found[(used, seq[0] if used == 1 else 0, b.key())] = True
            return
        for s, t in steps:
            e = b.apply_half(s, t, c)
            rec(seq, i + 1, used + 1)
            b.undo_half(e)

    for seq in seqs:
        rec(seq, 0, 0)
    if not found:
        return set()
    m = max(k[0] for k in found)
    keep = [k for k in found if k[0] == m]
    if m == 1 and d1 != d2:
        big = max(d1, d2)
        if any(k[1] == big for k in keep):
            keep = [k for k in keep if k[1] == big]
    return {k[2] for k in keep}


def random_position(rng):
    """Scattered position (incl. bar / borne-off / bear-off phases), 15 per side."""
    p = [0] * 26
    off = {WHITE: 0, BLACK: 0}
    for c in (WHITE, BLACK):
        phase = rng.random()
        for _ in range(15):
            for _attempt in range(50):
                r = rng.random()
                if r < 0.06:
                    slot = 0 if c == WHITE else 25
                elif r < 0.14:
                    off[c] += 1
                    break
                elif phase < 0.3:
                    slot = rng.randint(19, 24) if c == WHITE else rng.randint(1, 6)
                else:
                    slot = rng.randint(1, 24)
                if p[slot] * c >= 0:
                    p[slot] += c
                    break
            else:
                off[c] += 1
    b = PortesBoard()
    b.p = p
    b.borne_off = off
    return b


class TestWorkedExamples(unittest.TestCase):
    def assertMoveSet(self, b, c, d1, d2, expected):
        got = moves(b, c, d1, d2)
        self.assertEqual(sorted(map(repr, got)), sorted(map(repr, expected)), (d1, d2))
        keys = result_keys(b, c, got)
        self.assertEqual(len(keys), len(set(keys)), "duplicate resulting positions")

    def test_p1_dance(self):
        b = board({0: 1, 24: 14}, {3: 2, 5: 2, 6: 11})
        self.assertMoveSet(b, WHITE, 5, 3, [])

    def test_p2_enter_with_open_die(self):
        b = board({0: 1, 24: 14}, {3: 2, 5: 2, 6: 11})
        self.assertMoveSet(b, WHITE, 5, 2, [mv((0, 2), (2, 7))])

    def test_p3_two_on_bar_doubles(self):
        b = board({0: 2, 24: 13}, {3: 2, 5: 2, 6: 11})
        self.assertMoveSet(b, WHITE, 4, 4, [mv((0, 4), (0, 4), (4, 8), (4, 8)),
                                            mv((0, 4), (0, 4), (4, 8), (8, 12))])

    def test_p4_intermediate_hit_matters(self):
        b = board({10: 1, 24: 14}, {14: 1, 3: 14})
        got = moves(b, WHITE, 4, 1)
        self.assertMoveSet(b, WHITE, 4, 1, [mv((10, 14), (14, 15)), mv((10, 11), (11, 15))])
        hit = [m for m in got if m.halves[0] == HalfMove(10, 14)][0]
        t = b.apply(hit, WHITE)
        self.assertEqual((b.p[15], b.p[14], b.p[25]), (1, 0, -1))
        b.undo(t)
        quiet = [m for m in got if m.halves[0] == HalfMove(10, 11)][0]
        b.apply(quiet, WHITE)
        self.assertEqual((b.p[15], b.p[14], b.p[25]), (1, -1, 0))

    def test_p5_black_entry(self):
        b = board({24: 14, 15: 1}, {25: 1, 3: 14})
        self.assertMoveSet(b, BLACK, 1, 1, [])
        self.assertMoveSet(b, BLACK, 6, 1, [mv((25, 19), (19, 18)), mv((25, 19), (3, 2))])

    def test_p6_larger_die_bear_off(self):
        b = board({23: 10, 24: 5}, {3: 15})
        self.assertMoveSet(b, WHITE, 6, 5, [mv((23, 25), (23, 25))])

    def test_p7_larger_die_only_from_highest_point(self):
        b = board({20: 1, 23: 14}, {3: 15})
        self.assertMoveSet(b, WHITE, 6, 5, [mv((20, 25), (23, 25))])

    def test_p8_larger_die_obligation(self):
        b = board({10: 1, 24: 14}, {19: 2, 3: 13})
        self.assertMoveSet(b, WHITE, 6, 3, [mv((10, 16))])

    def test_p9_no_bear_off_with_checker_on_bar(self):
        b = board({0: 1, 22: 14}, {4: 2, 1: 13})
        got = moves(b, WHITE, 6, 3)
        self.assertEqual(len(got), 1)
        self.assertIn(repr(got[0]), {"(0->6, 6->9)", "(0->3, 3->9)"})
        for m in got:
            self.assertNotIn(25, [h.dst for h in m.halves])
        b.apply(got[0], WHITE)
        self.assertEqual((b.p[9], b.p[22], b.p[0]), (1, 14, 0))

    def test_p10_initial_position(self):
        b = PortesBoard.initial()
        got = moves(b, WHITE, 3, 1)
        keys = set(result_keys(b, WHITE, got))
        for want in (mv((17, 20), (19, 20)), mv((1, 4), (1, 2))):
            t = b.apply(want, WHITE)
            self.assertIn(b.key(), keys, repr(want))
            b.undo(t)
        for m in got:
            t = b.apply(m, WHITE)
            self.assertLessEqual(b.p[13], 0, repr(m))
            b.undo(t)


class TestSetupAndScoring(unittest.TestCase):
    def test_initial_setup(self):
        b = get_ruleset("portes").initial_board(ConfigLoader(CONFIG_PATH))
        self.assertEqual(b.total(WHITE), 15)
        self.assertEqual(b.total(BLACK), 15)
        self.assertEqual((b.p[1], b.p[12], b.p[17], b.p[19]), (2, 5, 3, 5))
        self.assertEqual((b.p[24], b.p[13], b.p[8], b.p[6]), (-2, -5, -3, -5))
        self.assertEqual(b.pip_count(WHITE), 167)
        self.assertEqual(b.pip_count(BLACK), 167)

    def test_result_points(self):
        rules = get_ruleset("portes")
        b = board({}, {1: 15}, white_off=15)
        self.assertTrue(rules.is_over(b))
        self.assertEqual(rules.outcome(b), (WHITE, 2))          # gammon
        self.assertEqual(rules.terminal_value(b, WHITE), 1.0)
        self.assertEqual(rules.terminal_value(b, BLACK), 0.0)
        b = board({}, {1: 14}, white_off=15, black_off=1)
        self.assertEqual(rules.outcome(b), (WHITE, 1))          # single
        self.assertEqual(rules.terminal_value(b, WHITE), 0.75)
        self.assertEqual(rules.terminal_value(b, BLACK), 0.25)
        b = board({0: 1}, {}, white_off=14, black_off=15)        # straggler on bar: still 1
        self.assertEqual(rules.outcome(b), (BLACK, 1))
        b = board({0: 3, 20: 12}, {}, black_off=15)              # none off: 2 (no triple)
        self.assertEqual(rules.outcome(b), (BLACK, 2))

    def test_metadata(self):
        rules = get_ruleset("portes")
        self.assertEqual(rules.name, "portes")
        self.assertEqual(rules.max_points, 2)
        self.assertFalse(rules.supports_bearoff_db)
        self.assertTrue(rules.random_starting_player)
        self.assertIs(rules.legal_moves, legal_moves)
        self.assertEqual(rules.default_encoder_version, "portes_v1")


class TestAgainstReference(unittest.TestCase):
    def _check(self, b, c, d1, d2):
        got = moves(b, c, d1, d2)
        keys = result_keys(b, c, got)
        self.assertEqual(len(keys), len(set(keys)), (b, c, d1, d2))
        self.assertEqual(set(keys), ref_positions(b, c, d1, d2), (repr(b), c, d1, d2, got))

    def test_scattered_positions(self):
        rng = random.Random(137)
        for _ in range(400):
            b = random_position(rng)
            if b.has_won(WHITE) or b.has_won(BLACK):
                continue
            c = rng.choice((WHITE, BLACK))
            self._check(b, c, rng.randint(1, 6), rng.randint(1, 6))

    def test_game_positions_all_rolls(self):
        rng = random.Random(7)
        rules = get_ruleset("portes")
        b = PortesBoard.initial()
        c = WHITE
        dice = Dice()
        checked = 0
        while not rules.is_over(b) and checked < 60:
            for d1 in range(1, 7):
                for d2 in range(d1, 7):
                    self._check(b, c, d1, d2)
            checked += 1
            dice.set(rng.randint(1, 6), rng.randint(1, 6))
            ms = legal_moves(b, c, dice)
            if ms:
                b.apply(rng.choice(ms), c)
            c = -c


class TestRandomGames(unittest.TestCase):
    def test_invariants_and_apply_undo(self):
        rules = get_ruleset("portes")
        rng = random.Random(2026)
        points_seen = set()
        for g in range(200):
            b = PortesBoard.initial()
            c = rules.starting_player(WHITE, rng)
            dice = Dice()
            plies = 0
            while not rules.is_over(b):
                plies += 1
                self.assertLess(plies, 5000, "game did not terminate")
                dice.set(rng.randint(1, 6), rng.randint(1, 6))
                ms = legal_moves(b, c, dice)
                if ms:
                    before = b.key()
                    for m in ms[:3]:
                        t = b.apply(m, c)
                        b.undo(t)
                        self.assertEqual(b.key(), before)
                    clone = b.clone()
                    m = rng.choice(ms)
                    t = b.apply(m, c)
                    self.assertNotEqual(b.key(), before)
                    n_dice = 4 if dice.die1.value == dice.die2.value else 2
                    self.assertLessEqual(len(m.halves), n_dice)
                    b.undo(t)
                    self.assertEqual(b.key(), clone.key())
                    b.apply(m, c)
                self.assertEqual(b.total(WHITE), 15)
                self.assertEqual(b.total(BLACK), 15)
                self.assertGreaterEqual(b.p[0], 0)
                self.assertLessEqual(b.p[25], 0)
                c = -c
            winner, pts = rules.outcome(b)
            self.assertIn(winner, (WHITE, BLACK))
            self.assertIn(pts, (1, 2))
            points_seen.add(pts)
        self.assertEqual(points_seen, {1, 2})


if __name__ == "__main__":
    unittest.main()
