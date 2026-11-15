"""Standard Plakoto (#139): worked examples from docs/variants/plakoto-standard.md
(pinning both the current-engine and the standard result), random-game invariants,
and a differential fuzz against a brute-force reference + the current engine."""

import random
import unittest
from pathlib import Path

from config.config_loader import ConfigLoader
from domain import Board, Dice, HalfMove, Move, WHITE, BLACK, legal_moves
from domain.plakoto_standard_board import StandardPlakotoBoard
from domain.plakoto_standard_rules import StandardPlakotoRules
from domain.ruleset import get_ruleset

CONFIG_PATH = str(Path(__file__).resolve().parents[2] / "config-test.yml")
STD = get_ruleset("plakoto_standard")


def dice(d1, d2):
    d = Dice(6)
    d.set(d1, d2)
    return d


def board(points, cls=StandardPlakotoBoard):
    b = cls()
    for p in points:
        i, c, k = p[:3]
        b.set_point(i, c, k, pinned=len(p) > 3 and p[3])
    return b


def key(move):
    """Order-independent move identity (halves as an unordered multiset)."""
    return tuple(sorted((h.src, h.dst) for h in move.halves))


def keys(moves):
    return {key(m) for m in moves}


def both(points, color, d1, d2):
    """(current-engine keys, standard keys) — current engine on a plain Board."""
    cur = keys(legal_moves(board(points, Board), color, dice(d1, d2)))
    std = keys(STD.legal_moves(board(points), color, dice(d1, d2)))
    return cur, std


# --------------------------------------------------------------------------- #
# Brute-force reference: every legal half-move sequence under the standard rules,
# applied for real on a board clone. Slow but obviously faithful to the spec.
# --------------------------------------------------------------------------- #

def _step_ok(b, c, src, d):
    if b.n[src] == 0 or b.color[src] != c:
        return None
    off = b.board_size + 1 if c == WHITE else 0
    dst = src + c * d
    if 1 <= dst <= b.board_size:
        return dst if b.is_open_for(dst, c) else None
    if b.count_outside_home(c):
        return None
    if dst == off:
        return off
    # larger die: no own checker (owned or pinned) farther from off than src
    farther = range(1, src) if c == WHITE else range(src + 1, b.board_size + 1)
    for q in farther:
        if b.n[q] and (b.color[q] == c or b.pinned[q]):
            return None
    return off


def reference(b, c, d1, d2):
    """{key: max dice used realising it}, plus M and die-of-single for M==1."""
    out = {}
    seqs = []

    def rec(remaining, seq):
        extended = False
        tried = set()
        for idx, d in enumerate(remaining):
            if d in tried:
                continue
            tried.add(d)
            rest = remaining[:idx] + remaining[idx + 1:]
            for src in range(1, b.board_size + 1):
                dst = _step_ok(b, c, src, d)
                if dst is None:
                    continue
                extended = True
                e = b.apply_half(src, dst, c)
                rec(rest, seq + [(src, dst, d)])
                b.undo_half(e)
        if seq:
            seqs.append(seq)

    rec([d1, d2] if d1 != d2 else [d1] * 4, [])
    for seq in seqs:
        halves = [(s, t) for s, t, _ in seq]
        if d1 != d2 and len(seq) == 2 and seq[1][0] == seq[0][1]:
            halves = [(seq[0][0], seq[1][1])]  # merged single-checker notation
        elif d1 != d2 and len(seq) == 2 and seq[1][1] == seq[0][0]:
            halves = [(seq[1][0], seq[0][1])]  # same net effect, other order
        k = tuple(sorted(halves))
        out[k] = max(out.get(k, 0), len(seq))
    M = max((len(s) for s in seqs), default=0)
    legal = {k for k, n in out.items() if n == M}
    if d1 != d2 and M == 1:
        big = max(d1, d2)
        big_keys = {tuple(sorted([(s[0][0], s[0][1])])) for s in seqs if s[0][2] == big}
        if big_keys:
            legal = big_keys
    return legal, out, M


def checker_total(b, c):
    total = b.borne_off[c]
    for i in range(1, b.board_size + 1):
        if b.n[i] and b.color[i] == c:
            total += b.n[i]
        if b.pinned[i] and b.color[i] == -c:
            total += 1
    return total


def random_game(rules, cfg, rng, max_plies=2000, on_position=None):
    b = rules.initial_board(cfg)
    c = rng.choice((WHITE, BLACK))
    d = Dice(6)
    for ply in range(max_plies):
        d.roll(rng)
        if on_position is not None:
            on_position(b, c, d.die1.value, d.die2.value)
        ms = rules.legal_moves(b, c, d)
        if ms:
            b.apply(rng.choice(ms), c)
        if b.has_won(WHITE) or b.has_won(BLACK) or getattr(b, "is_draw", lambda: False)():
            return b, ply + 1
        c = -c
    raise AssertionError("game did not terminate")


class TestWorkedExamples(unittest.TestCase):
    def test_e1_larger_die_bear_off(self):
        cur, std = both([(23, WHITE, 10), (24, WHITE, 5), (3, BLACK, 15)], WHITE, 6, 5)
        self.assertEqual(cur, set())
        self.assertEqual(std, {((23, 25), (23, 25))})

    def test_e2_must_use_both_dice(self):
        pts = [(24, WHITE, 13), (5, WHITE, 1), (10, WHITE, 1),
               (9, BLACK, 2), (20, BLACK, 2), (3, BLACK, 11)]
        cur, std = both(pts, WHITE, 6, 4)
        self.assertEqual(cur, {((5, 11), (10, 14)), ((5, 15),), ((10, 16),)})
        self.assertEqual(std, {((5, 11), (10, 14)), ((5, 15),)})

    def test_e3_larger_die(self):
        pts = [(24, WHITE, 14), (10, WHITE, 1), (19, BLACK, 2), (3, BLACK, 13)]
        for d1, d2 in ((6, 3), (3, 6)):
            cur, std = both(pts, WHITE, d1, d2)
            self.assertEqual(cur, {((10, 13),), ((10, 16),)})
            self.assertEqual(std, {((10, 16),)})

    def test_e3_smaller_die_when_larger_unplayable(self):
        # Same as E3 but 16 blocked too: only the 3 can be played.
        pts = [(24, WHITE, 13), (10, WHITE, 1), (19, BLACK, 2), (16, BLACK, 2), (3, BLACK, 11)]
        _, std = both(pts, WHITE, 6, 3)
        self.assertEqual(std, {((10, 13),)})

    def test_e4_mother_exception(self):
        pts = [(1, WHITE, 3), (20, WHITE, 11), (24, WHITE, 1, True), (5, BLACK, 14)]
        cur = board(pts, Board)
        self.assertTrue(cur.has_won(WHITE))
        std = board(pts)
        self.assertFalse(std.has_won(WHITE))
        self.assertFalse(STD.is_over(std))
        # White empties slot 1 with the pin intact -> White wins 2.
        std.set_point(1, WHITE, 0)
        std.set_point(21, WHITE, 3)
        self.assertTrue(STD.is_over(std))
        self.assertEqual(STD.outcome(std), (WHITE, 2))
        self.assertEqual(STD.result_points(std, WHITE), 2)

    def test_e5_both_mothers_pinned_draw(self):
        pts = [(1, WHITE, 1), (20, WHITE, 13), (24, WHITE, 1, True),
               (2, BLACK, 1), (5, BLACK, 13)]
        mv = Move((HalfMove(2, 1), HalfMove(5, 3)))
        self.assertIn(key(mv), keys(STD.legal_moves(board(pts), BLACK, dice(1, 2))))
        cur = board(pts, Board)
        cur.apply(mv, BLACK)
        self.assertTrue(cur.has_won(WHITE) and cur.has_won(BLACK))
        std = board(pts)
        std.apply(mv, BLACK)
        self.assertTrue(std.is_draw())
        self.assertFalse(std.has_won(WHITE) or std.has_won(BLACK))
        self.assertTrue(STD.is_over(std))
        self.assertEqual(STD.outcome(std), (None, 0))

    def test_e6_gammon(self):
        pts = [(24, WHITE, 1), (5, BLACK, 15)]
        b = board(pts)
        b.borne_off[WHITE] = 14
        b.apply(Move((HalfMove(24, 25),)), WHITE)
        self.assertEqual(STD.outcome(b), (WHITE, 2))
        cur = board(pts, Board)  # current engine: a plain (binary) win
        cur.borne_off[WHITE] = 14
        cur.apply(Move((HalfMove(24, 25),)), WHITE)
        self.assertTrue(cur.has_won(WHITE))
        self.assertEqual(get_ruleset("plakoto").result_points(cur, WHITE), 1)
        b2 = board([(24, WHITE, 1), (5, BLACK, 14)])
        b2.borne_off[WHITE] = 14
        b2.borne_off[BLACK] = 1
        b2.apply(Move((HalfMove(24, 25),)), WHITE)
        self.assertEqual(STD.outcome(b2), (WHITE, 1))

    def test_e7_mother_win_start_empty(self):
        pts = [(20, WHITE, 14), (24, WHITE, 1, True), (4, BLACK, 14)]
        self.assertTrue(board(pts, Board).has_won(WHITE))   # current: plain win
        b = board(pts)
        self.assertTrue(b.has_won(WHITE))
        self.assertEqual(STD.outcome(b), (WHITE, 2))

    def test_e8_transient_pin_no_diff(self):
        pts = [(10, WHITE, 1), (24, WHITE, 14), (11, BLACK, 2), (13, BLACK, 1), (3, BLACK, 12)]
        cur, std = both(pts, WHITE, 3, 1)
        self.assertEqual(cur, {((10, 14),)})
        self.assertEqual(std, {((10, 14),)})
        b = board(pts)
        b.apply(STD.legal_moves(b, WHITE, dice(3, 1))[0], WHITE)
        self.assertEqual((b.n[13], b.color[13], b.pinned[13]), (1, BLACK, False))

    def test_e9_pinned_own_checker_in_home(self):
        pts = [(23, WHITE, 14), (20, BLACK, 1, True), (2, BLACK, 14)]
        cur, std = both(pts, WHITE, 2, 1)
        self.assertEqual(cur, {((23, 24), (23, 25))})
        self.assertEqual(std, {((23, 24), (23, 25))})

    def test_e10_higher_die_from_farther_point(self):
        pts = [(20, WHITE, 1), (23, WHITE, 14), (3, BLACK, 15)]
        cur, std = both(pts, WHITE, 6, 5)
        self.assertEqual(cur, {((20, 25),)})
        self.assertEqual(std, {((20, 25), (23, 25))})

    def test_pinned_own_checker_counts_for_highest_point(self):
        # White 14@23, one White pinned by Black on 20 (inside home): a 6 may not
        # bear off from 23 because the pinned checker on 20 is farther.
        pts = [(23, WHITE, 14), (20, BLACK, 1, True), (2, BLACK, 14)]
        _, std = both(pts, WHITE, 6, 6)
        self.assertEqual(std, set())
        _, std = both(pts, WHITE, 2, 2)
        self.assertEqual(std, {((23, 25),) * 4})

    def test_black_mirror_of_e1_and_e10(self):
        _, std = both([(2, BLACK, 10), (1, BLACK, 5), (22, WHITE, 15)], BLACK, 6, 5)
        self.assertEqual(std, {((2, 0), (2, 0))})
        _, std = both([(5, BLACK, 1), (2, BLACK, 14), (22, WHITE, 15)], BLACK, 6, 5)
        self.assertEqual(std, {((2, 0), (5, 0))})

    def test_pinned_outside_home_blocks_bear_off(self):
        pts = [(23, WHITE, 14), (10, BLACK, 1, True), (2, BLACK, 14)]
        # White's checker pinned on 10 (outside home) forbids bearing off; 23+2 is off -> pass.
        cur, std = both(pts, WHITE, 2, 2)
        self.assertEqual(std, set())
        self.assertEqual(cur, set())
        cur, std = both(pts, WHITE, 1, 1)
        self.assertEqual(std, {((23, 24),) * 4})


class TestRuleSetSurface(unittest.TestCase):
    def setUp(self):
        self.cfg = ConfigLoader(CONFIG_PATH)

    def test_registration_and_attributes(self):
        self.assertIsInstance(STD, StandardPlakotoRules)
        self.assertEqual(STD.name, "plakoto_standard")
        self.assertEqual(STD.max_points, 2)
        self.assertTrue(STD.random_starting_player)
        self.assertFalse(STD.supports_bearoff_db)
        self.assertEqual(STD.default_encoder_version, "plakoto_std_v1")
        self.assertIs(STD.legal_moves, StandardPlakotoRules.__dict__["legal_moves"].__func__)

    def test_board_type_and_clone(self):
        b = STD.initial_board(self.cfg)
        self.assertIsInstance(b, StandardPlakotoBoard)
        self.assertEqual((b.n[1], b.color[1]), (15, WHITE))
        self.assertEqual((b.n[24], b.color[24]), (15, BLACK))
        c = b.clone()
        self.assertIsInstance(c, StandardPlakotoBoard)
        c.n[1] = 3
        self.assertEqual(b.n[1], 15)
        self.assertFalse(STD.is_over(b))

    def test_plakoto_variant_unchanged(self):
        self.assertIs(type(get_ruleset("plakoto").initial_board(self.cfg)), Board)


class TestRandomGames(unittest.TestCase):
    def test_invariants_over_random_games(self):
        cfg = ConfigLoader(CONFIG_PATH)
        rng = random.Random(139)
        seen = set()
        for _ in range(200):
            def check(b, c, d1, d2):
                for col in (WHITE, BLACK):
                    self.assertEqual(checker_total(b, col), 15)
            b, plies = random_game(STD, cfg, rng, on_position=check)
            self.assertLess(plies, 2000)
            w, pts = STD.outcome(b)
            self.assertIn((w is None, pts), {(True, 0), (False, 1), (False, 2)})
            if w is None:
                self.assertTrue(b.is_draw())
            else:
                self.assertTrue(STD.has_won(b, w))
                self.assertFalse(STD.has_won(b, -w))
                self.assertEqual(STD.result_points(b, w), pts)
            seen.add("draw" if w is None else ("mother" if b.mother_win(w) else f"off{pts}"))
        # 200 random games reach every kind of ending.
        self.assertEqual(seen, {"draw", "mother", "off1", "off2"})


class TestDifferentialFuzz(unittest.TestCase):
    def test_standard_vs_reference_and_current(self):
        cfg = ConfigLoader(CONFIG_PATH)
        rng = random.Random(7)
        positions = []

        def grab(b, c, d1, d2):
            if rng.random() < 0.15:
                positions.append((b.clone(), c))

        for rules in (STD, get_ruleset("plakoto")):
            for _ in range(15):
                try:
                    random_game(rules, cfg, rng, on_position=grab)
                except AssertionError:
                    pass
        self.assertGreater(len(positions), 150)

        rolls = [(a, b) for a in range(1, 7) for b in range(1, 7)]
        diffs = 0
        for pos, c in positions:
            sb = StandardPlakotoBoard()
            sb.n, sb.color, sb.pinned = pos.n[:], pos.color[:], pos.pinned[:]
            sb.borne_off = dict(pos.borne_off)
            for d1, d2 in rng.sample(rolls, 6):
                std_moves = STD.legal_moves(sb, c, dice(d1, d2))
                std = keys(std_moves)
                self.assertEqual(len(std), len(std_moves), "duplicate moves emitted")
                ref, ref_all, M = reference(sb, c, d1, d2)
                self.assertEqual(std, ref, f"{sb}\n{c} {d1}-{d2}")
                # every std move is applicable half-by-half in its emitted order
                for m in std_moves:
                    tok = sb.apply(m, c)
                    sb.undo(tok)
                # current-engine differences are only the documented ones
                cur = keys(legal_moves(sb, c, dice(d1, d2)))
                for k in cur - std:
                    self.assertIn(k, ref_all, "current move illegal under standard sequencing")
                    used = ref_all[k]
                    smaller_single = (d1 != d2 and M == 1 and used == 1)
                    self.assertTrue(used < M or smaller_single, (k, used, M))
                for k in std - cur:
                    # only via a larger-die bear-off (diff #1)
                    off = 25 if c == WHITE else 0
                    self.assertTrue(any(dst == off for _, dst in k), k)
                diffs += cur != std
        self.assertGreater(diffs, 0)

    def test_no_play_uses_fewer_dice_than_another(self):
        cfg = ConfigLoader(CONFIG_PATH)
        rng = random.Random(11)
        checked = 0

        def check(b, c, d1, d2):
            nonlocal checked
            ms = STD.legal_moves(b, c, dice(d1, d2))
            if d1 == d2:
                self.assertLessEqual(len({len(m.halves) for m in ms}), 1)
            else:
                if any(len(m.halves) == 2 for m in ms):
                    # both dice usable -> every single-half play is a merged d1+d2 jump
                    for m in ms:
                        if len(m.halves) == 1:
                            h = m.halves[0]
                            self.assertTrue(h.dst in (0, 25) or abs(h.dst - h.src) == d1 + d2, m)
            checked += 1

        for _ in range(30):
            random_game(STD, cfg, rng, on_position=check)
        self.assertGreater(checked, 1000)


if __name__ == "__main__":
    unittest.main()
