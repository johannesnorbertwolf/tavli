"""Tier-2 handicap rules (#148 E3): overshoot bear-off, safe point, checker count, smaller home,
the plakoto_hc RuleSet and the tier-2 sampler."""

import random
import unittest
from collections import Counter
from pathlib import Path

from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.handicap import (
    DEFAULT_LEVER_PROBS, SAFE_POINT_CANDIDATES, TIER2_GRID, HandicapBoard, HandicapSpec,
    make_handicapped_rules, parse_spec, sample_tier2_specs, tier2_board,
)
from domain.handicap_moves import _normal_moves_ov, _pasch_moves_ov, legal_moves_tier2
from domain.move import HalfMove, Move
from domain.move_generation import legal_moves
from domain.ruleset import get_ruleset

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ConfigLoader(str(ROOT / "config-test.yml"))


def dice(a, b):
    d = Dice()
    d.set(a, b)
    return d


def keys(moves):
    return sorted(tuple(sorted(m.halves)) for m in moves)


def empty_board(**kw):
    return HandicapBoard(24, 6, 15, **kw)


def H(a, b):
    return HalfMove(a, b)


class TestOvershoot(unittest.TestCase):
    def test_bears_off_with_higher_dice(self):
        b = empty_board(overshoot={WHITE: True})
        b.set_point(22, WHITE, 1)
        b.set_point(23, WHITE, 1)
        b.set_point(3, BLACK, 15)
        self.assertEqual(legal_moves(b, WHITE, dice(6, 5)), [])  # exact-die: no move
        moves = legal_moves_tier2(b, WHITE, dice(6, 5))
        self.assertEqual(keys(moves), [(H(22, 25), H(23, 25))])

    def test_only_from_the_farthest_point(self):
        b = empty_board(overshoot={WHITE: True})
        b.set_point(20, WHITE, 1)
        b.set_point(23, WHITE, 1)
        b.set_point(3, BLACK, 15)
        moves = keys(legal_moves_tier2(b, WHITE, dice(6, 1)))
        self.assertIn((H(20, 25), H(23, 24)), moves)        # farthest checker overshoots
        self.assertIn((H(20, 25),), moves)                  # merged 20->21->off
        self.assertNotIn((H(20, 21), H(23, 25)), moves)     # 21 still farther than 23
        self.assertFalse(any(h == H(23, 25) for m in moves for h in m))

    def test_farther_checker_moving_first_allows_overshoot(self):
        b = empty_board(overshoot={WHITE: True})
        b.set_point(21, WHITE, 1)
        b.set_point(23, WHITE, 1)
        b.set_point(3, BLACK, 15)
        # 21 bears off exactly with 4, then 23 may overshoot with 6 (nothing farther).
        self.assertIn((H(21, 25), H(23, 25)), keys(legal_moves_tier2(b, WHITE, dice(6, 4))))

    def test_pinned_own_checker_counts_as_farther(self):
        b = empty_board(overshoot={WHITE: True})
        b.set_point(20, BLACK, 2, pinned=True)   # a White checker trapped on 20 (in home)
        b.set_point(23, WHITE, 1)
        b.set_point(3, BLACK, 13)
        moves = legal_moves_tier2(b, WHITE, dice(6, 5))
        self.assertFalse(any(h.dst == 25 for m in moves for h in m.halves))
        self.assertIn(Move((H(23, 25),)), legal_moves_tier2(b, WHITE, dice(2, 6)))  # exact ok

    def test_not_while_a_checker_is_outside_home(self):
        b = empty_board(overshoot={WHITE: True})
        b.set_point(10, WHITE, 1)
        b.set_point(23, WHITE, 1)
        b.set_point(3, BLACK, 15)
        moves = legal_moves_tier2(b, WHITE, dice(6, 5))
        self.assertFalse(any(h.dst == 25 for m in moves for h in m.halves))

    def test_doubles(self):
        b = empty_board(overshoot={WHITE: True})
        b.set_point(22, WHITE, 2)
        b.set_point(3, BLACK, 15)
        self.assertEqual(keys(legal_moves_tier2(b, WHITE, dice(5, 5))),
                         [(H(22, 25), H(22, 25))])
        # Bring the last outside checker home with the first steps, then overshoot.
        b = empty_board(overshoot={BLACK: True})
        b.set_point(17, BLACK, 1)
        b.set_point(1, BLACK, 5)
        b.set_point(24, WHITE, 15)
        moves = keys(legal_moves_tier2(b, BLACK, dice(5, 5)))
        self.assertEqual(moves, [(H(2, 0), H(7, 2), H(12, 7), H(17, 12))])

    def test_black_mirror_and_other_side_keeps_exact(self):
        b = empty_board(overshoot={BLACK: True})
        b.set_point(3, BLACK, 1)
        b.set_point(2, BLACK, 1)
        b.set_point(22, WHITE, 1)
        b.set_point(23, WHITE, 1)
        self.assertEqual(keys(legal_moves_tier2(b, BLACK, dice(6, 5))), [(H(2, 0), H(3, 0))])
        self.assertEqual(legal_moves_tier2(b, WHITE, dice(6, 5)), [])  # White: exact-die

    def test_matches_house_generator_when_overshoot_impossible(self):
        """With more than 4 own checkers outside home no turn can reach a bear-off, so the
        overshoot generator must reproduce the house generator exactly (same move lists)."""
        rng = random.Random(7)
        checked = 0
        for _ in range(6):
            b, p, d = Board.initial(CONFIG), BLACK, Dice()
            for _ in range(300):
                d.set(rng.randint(1, 6), rng.randint(1, 6))
                ms = legal_moves(b, p, d)
                if ms:
                    b.apply(rng.choice(ms), p)
                if b.has_won(WHITE) or b.has_won(BLACK):
                    break
                p = -p
                if b.count_outside_home(p) <= 4:
                    continue
                for d1 in range(1, 7):
                    for d2 in range(d1, 7):
                        dd = dice(d1, d2)
                        ov = (_pasch_moves_ov(b, p, d1) if d1 == d2
                              else _normal_moves_ov(b, p, d1, d2))
                        self.assertEqual(keys(ov), keys(legal_moves(b, p, dd)))
                        checked += 1
        self.assertGreater(checked, 1000)

    def test_overshoot_moves_are_playable_half_by_half(self):
        """Every generated move applies cleanly (no illegal destination) from bear-in races."""
        rng = random.Random(11)
        for _ in range(200):
            b = empty_board(overshoot={WHITE: True})
            for _ in range(rng.randint(1, 6)):
                b.set_point(rng.randint(19, 24), WHITE, rng.randint(1, 3))
            b.set_point(2, BLACK, 15)
            d1, d2 = rng.randint(1, 6), rng.randint(1, 6)
            for m in legal_moves_tier2(b, WHITE, dice(d1, d2)):
                c = b.clone()
                c.apply(m, WHITE)
                self.assertGreater(c.borne_off[WHITE] + 1, 0)

    def test_without_overshoot_dispatches_to_house_generator(self):
        b = Board.initial(CONFIG)
        for d1 in range(1, 7):
            for d2 in range(1, 7):
                self.assertEqual(legal_moves_tier2(b, WHITE, dice(d1, d2)),
                                 legal_moves(b, WHITE, dice(d1, d2)))


class TestSafePoint(unittest.TestCase):
    def test_lone_favoured_checker_cannot_be_pinned(self):
        b = empty_board(safe_point={WHITE: 6})
        b.set_point(1, WHITE, 14)
        b.set_point(6, WHITE, 1)     # White's safe point (White numbering = slot 6)
        b.set_point(9, WHITE, 1)     # an ordinary blot
        b.set_point(8, BLACK, 2)
        b.set_point(24, BLACK, 13)
        moves = legal_moves_tier2(b, BLACK, dice(2, 1))
        self.assertFalse(any(h.dst == 6 for m in moves for h in m.halves))
        self.assertTrue(any(h.dst == 7 for m in moves for h in m.halves))
        plain = Board(24, 6, 15)
        plain.n, plain.color, plain.pinned = b.n[:], b.color[:], b.pinned[:]
        self.assertTrue(any(h.dst == 6 for m in legal_moves(plain, BLACK, dice(2, 1))
                            for h in m.halves))
        self.assertFalse(b.is_open_for(6, BLACK))
        self.assertTrue(b.is_open_for(9, BLACK))      # an ordinary blot stays pinnable
        self.assertTrue(b.is_open_for(6, WHITE))

    def test_safe_point_does_not_protect_the_other_side_or_stacks(self):
        b = empty_board(safe_point={WHITE: 6})
        b.set_point(6, BLACK, 1)     # a Black blot on White's safe point: White may pin it
        self.assertTrue(b.is_open_for(6, WHITE))
        b.set_point(6, WHITE, 2)     # a White stack is closed anyway
        self.assertFalse(b.is_open_for(6, BLACK))
        b.set_point(6, WHITE, 1)
        b.set_safe_point(WHITE, 0)
        self.assertTrue(b.is_open_for(6, BLACK))

    def test_black_numbering_and_pasch(self):
        b = empty_board(safe_point={BLACK: 6})   # Black's point 6 = slot 19
        b.set_point(19, BLACK, 1)
        b.set_point(17, WHITE, 2)
        b.set_point(24, BLACK, 14)
        moves = legal_moves_tier2(b, WHITE, dice(2, 2))
        self.assertFalse(any(h.dst == 19 for m in moves for h in m.halves))

    def test_rules_spec(self):
        spec = HandicapSpec("safe_point", 6, BLACK)   # Black handicapped -> White favoured
        self.assertEqual(spec.target, WHITE)
        b = make_handicapped_rules([spec]).initial_board(CONFIG)
        self.assertIsInstance(b, HandicapBoard)
        self.assertEqual(b.safe_point, {WHITE: 6, BLACK: 0})
        with self.assertRaises(ValueError):
            HandicapSpec("safe_point", 1)    # mother protection: rejected lever


class TestCheckers(unittest.TestCase):
    def test_more_checkers_for_the_handicapped_side(self):
        b = make_handicapped_rules([parse_spec("checkers:17", WHITE)]).initial_board(CONFIG)
        self.assertEqual(b.checkers, {WHITE: 17, BLACK: 15})
        self.assertEqual((b.n[1], b.n[24]), (17, 15))
        b.set_point(1, 0, 0)
        b.set_point(25, WHITE, 15)
        b.borne_off[WHITE] = 15
        self.assertFalse(b.has_won(WHITE))
        b.set_point(25, WHITE, 17)
        b.borne_off[WHITE] = 17
        self.assertTrue(b.has_won(WHITE))

    def test_fewer_checkers_for_the_favoured_side(self):
        spec = parse_spec("checkers:13", WHITE)
        self.assertEqual(spec.target, BLACK)
        b = make_handicapped_rules([spec]).initial_board(CONFIG)
        self.assertEqual((b.checkers[BLACK], b.n[24], b.n[1]), (13, 13, 15))
        b.set_point(24, 0, 0)
        b.set_point(0, BLACK, 13)
        b.borne_off[BLACK] = 13
        self.assertTrue(b.has_won(BLACK))

    def test_range(self):
        for bad in (12, 18):
            with self.assertRaises(ValueError):
                HandicapSpec("checkers", bad)

    def test_clone_and_game_play_through(self):
        r = make_handicapped_rules([parse_spec("checkers:16", BLACK),
                                    parse_spec("overshoot", BLACK)])
        b = r.initial_board(CONFIG)
        c = b.clone()
        self.assertEqual((c.checkers, c.overshoot), (b.checkers, b.overshoot))
        rng = random.Random(2)
        hc = get_ruleset("plakoto_hc")
        p = WHITE
        for _ in range(2000):
            ms = hc.legal_moves(b, p, dice(rng.randint(1, 6), rng.randint(1, 6)))
            if ms:
                b.apply(rng.choice(ms), p)
            if hc.is_over(b):
                break
            p = -p
        self.assertTrue(hc.is_over(b))
        for c in (WHITE, BLACK):
            on = sum(b.n[i] for i in range(1, 25) if b.color[i] == c)
            on += sum(1 for i in range(1, 25) if b.pinned[i] and b.color[i] == -c)
            self.assertEqual(on + b.borne_off[c], b.checkers[c])


class TestSmallerHome(unittest.TestCase):
    def test_bear_off_only_from_last_k_points_and_db_gate(self):
        b = make_handicapped_rules([parse_spec("smaller_house:4", WHITE)]).initial_board(CONFIG)
        b.set_point(1, 0, 0)
        b.set_point(20, WHITE, 1)    # outside the 4-point home 21..24
        b.set_point(23, WHITE, 14)
        b.set_point(24, 0, 0)
        b.set_point(3, BLACK, 15)
        moves = legal_moves_tier2(b, WHITE, dice(1, 2))
        for m in moves:   # a bear-off needs the 20 -> 21 step in the same move
            if any(h.dst == 25 for h in m.halves):
                self.assertIn(H(20, 21), m.halves)
        self.assertIn(Move((H(20, 21), H(23, 25))), moves)   # 20->21 brings it home first
        self.assertTrue(b.bearoff_exact)
        from ai.bearoff import race_state
        self.assertIsNone(race_state(b))                  # 20 is not home yet: no DB race
        b.set_point(20, 0, 0)
        b.set_point(21, WHITE, 1)
        self.assertIsNotNone(race_state(b))

    def test_db_gate_off_for_overshoot_and_extra_checkers(self):
        from ai.bearoff import race_state
        b = empty_board(overshoot={WHITE: True})
        b.set_point(23, WHITE, 3)
        b.set_point(2, BLACK, 3)
        self.assertFalse(b.bearoff_exact)
        self.assertIsNone(race_state(b))
        b = empty_board(checkers={BLACK: 16})
        self.assertFalse(b.bearoff_exact)
        self.assertTrue(empty_board(checkers={BLACK: 14}).bearoff_exact)


class TestPlakotoHcRuleset(unittest.TestCase):
    def test_registered_and_plain_on_normal_games(self):
        hc = get_ruleset("plakoto_hc")
        self.assertEqual(hc.default_encoder_version, "unary_v3_hc1")
        self.assertIn("plakoto", hc.compatible_checkpoint_variants)
        b = hc.initial_board(CONFIG)
        self.assertIs(type(b), Board)
        rng = random.Random(4)
        p = BLACK
        for _ in range(150):
            d = dice(rng.randint(1, 6), rng.randint(1, 6))
            ms = hc.legal_moves(b, p, d)
            self.assertEqual(ms, legal_moves(b, p, d))
            if ms:
                b.apply(rng.choice(ms), p)
            if hc.is_over(b):
                break
            p = -p


class TestSampler(unittest.TestCase):
    def test_one_side_at_least_one_lever_deterministic(self):
        rng = random.Random(0)
        draws = [sample_tier2_specs(rng) for _ in range(4000)]
        self.assertEqual(sample_tier2_specs(random.Random(9)), sample_tier2_specs(random.Random(9)))
        kinds = Counter()
        sides = Counter()
        for specs in draws:
            self.assertGreaterEqual(len(specs), 1)
            self.assertEqual(len({s.side for s in specs}), 1)        # one handicapped colour
            sides[specs[0].side] += 1
            for s in specs:
                kinds[s.kind] += 1
                self.assertIn(s.intensity, TIER2_GRID[s.kind])
                if s.kind in ("overshoot", "safe_point"):
                    self.assertEqual(s.target, -s.side)              # favoured side
                if s.kind == "smaller_house":
                    self.assertEqual(s.target, s.side)               # the other side
                if s.kind == "safe_point":
                    self.assertIn(s.intensity, SAFE_POINT_CANDIDATES)
            b = tier2_board(specs, CONFIG)
            self.assertIsInstance(b, HandicapBoard)
            self.assertTrue(b.is_handicapped())
        self.assertAlmostEqual(sides[WHITE] / len(draws), 0.5, delta=0.03)
        # P(lever | at least one) = p / (1 - prod(1 - p_i)); defaults -> 1 - 0.5*0.5*0.6*0.6
        z = 1 - 0.5 * 0.5 * 0.6 * 0.6
        for k, p in DEFAULT_LEVER_PROBS.items():
            self.assertAlmostEqual(kinds[k] / len(draws), p / z, delta=0.03)

    def test_custom_probs_and_validation(self):
        specs = sample_tier2_specs(random.Random(1), {"overshoot": 1.0, "safe_point": 0.0,
                                                      "checkers": 0.0, "smaller_house": 0.0})
        self.assertEqual([s.kind for s in specs], ["overshoot"])
        with self.assertRaises(ValueError):
            sample_tier2_specs(random.Random(1), {"nope": 1.0})


if __name__ == "__main__":
    unittest.main()
