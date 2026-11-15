"""Fevga rules (docs/variants/fevga.md): worked examples, apply/undo, random-game invariants,
and a cross-check of the fast generator against a slow reference built straight from the spec."""

import random
import unittest
from pathlib import Path

from config.config_loader import ConfigLoader
from domain.constants import WHITE as W, BLACK as B
from domain.dice import Dice
from domain.fevga_board import FevgaBoard, SLOT_OF, PATH_OF, OFF_SLOT
from domain.fevga_rules import FevgaRules, fevga_legal_moves
from domain.move import HalfMove, Move
from domain.ruleset import get_ruleset, registered_variants

CONFIG = str(Path(__file__).resolve().parents[2] / "config" / "config-fevga.yml")


def mk(points, off_w=0, off_b=0):
    b = FevgaBoard()
    for s, (c, n) in points.items():
        b.set_point(s, c, n)
    if off_w:
        b.set_borne_off(W, off_w)
    if off_b:
        b.set_borne_off(B, off_b)
    return b


def moves(board, color, d1, d2):
    dice = Dice()
    dice.set(d1, d2)
    return fevga_legal_moves(board, color, dice)


def mv(*halves):
    return Move(tuple(HalfMove(s, d) for s, d in halves))


def sig(board):
    return (tuple(board.n), tuple(board.color), board.borne_off[W], board.borne_off[B])


def result_sig(board, move, color):
    tok = board.apply(move, color)
    s = sig(board)
    board.undo(tok)
    return s


START = {1: (W, 15), 13: (B, 15)}


class TestCoordinates(unittest.TestCase):
    def test_black_path(self):
        self.assertEqual(SLOT_OF[B][1], 13)
        self.assertEqual(SLOT_OF[B][12], 24)
        self.assertEqual(SLOT_OF[B][13], 1)
        self.assertEqual(SLOT_OF[B][24], 12)
        self.assertEqual(SLOT_OF[B][25], 0)
        for p in range(1, 25):
            self.assertEqual(PATH_OF[B][SLOT_OF[B][p]], p)
            self.assertEqual(PATH_OF[W][SLOT_OF[W][p]], p)

    def test_registered(self):
        self.assertIn("fevga", registered_variants())
        rules = get_ruleset("Fevga")
        self.assertIsInstance(rules, FevgaRules)
        self.assertIs(rules.legal_moves, fevga_legal_moves)
        self.assertEqual(rules.max_points, 2)
        self.assertTrue(rules.random_starting_player)
        self.assertFalse(rules.supports_bearoff_db)

    def test_initial_board_and_result_points(self):
        rules = get_ruleset("fevga")
        b = rules.initial_board(ConfigLoader(CONFIG))
        self.assertEqual((b.n[1], b.color[1], b.n[13], b.color[13]), (15, W, 15, B))
        b2 = mk({10: (B, 1)}, off_w=15, off_b=14)
        self.assertTrue(rules.has_won(b2, W))
        self.assertEqual(rules.result_points(b2, W), 1)
        b3 = mk({10: (B, 15)}, off_w=15)
        self.assertEqual(rules.result_points(b3, W), 2)
        self.assertTrue(rules.is_open_for(b3, 9, W))
        self.assertFalse(rules.is_open_for(b3, 10, W))
        self.assertTrue(rules.is_open_for(b3, 10, B))


class TestWorkedExamples(unittest.TestCase):
    def assertMoves(self, got, expected):
        self.assertEqual(sorted(got), sorted(expected), f"got {got}")

    def test_f1_opening_non_double(self):
        self.assertMoves(moves(mk(START), W, 6, 5), [mv((1, 12))])

    def test_f2_opening_six_six(self):
        self.assertMoves(moves(mk(START), W, 6, 6), [mv((1, 7))])
        self.assertMoves(moves(mk(START), B, 6, 6), [mv((13, 19))])

    def test_f3_opening_three_three(self):
        self.assertMoves(moves(mk(START), W, 3, 3), [mv((1, 4), (4, 7), (7, 10))])

    def test_f4_unlock_mid_turn(self):
        b = mk({1: (W, 14), 10: (W, 1), 13: (B, 15)})
        self.assertMoves(moves(b, W, 5, 2), [mv((10, 17)), mv((10, 15), (1, 3))])

    def test_f5_black_wraps(self):
        b = mk({13: (B, 14), 22: (B, 1), 1: (W, 15)})
        self.assertMoves(moves(b, B, 5, 3), [mv((22, 6)), mv((22, 3), (13, 16))])

    def test_f6_black_bears_off_with_larger_dice(self):
        b = mk({10: (B, 15), 22: (W, 15)})
        self.assertMoves(moves(b, B, 6, 4), [mv((10, 0), (10, 0))])

    def test_f7_locked_and_blocked_pass(self):
        b = mk({1: (W, 14), 7: (W, 1), 13: (B, 13), 9: (B, 2)})
        self.assertEqual(moves(b, W, 6, 2), [])

    def test_f8_starting_table(self):
        b = mk({1: (W, 9), 2: (W, 1), 3: (W, 1), 4: (W, 1), 5: (W, 1), 10: (W, 1),
                14: (W, 1), 13: (B, 15)})
        sigs = {result_sig(b, m, W) for m in moves(b, W, 5, 2)}
        self.assertNotIn(result_sig(b, mv((1, 6), (14, 16)), W), sigs)
        self.assertIn(result_sig(b, mv((1, 6), (4, 6)), W), sigs)

    def _f9(self, black):
        pts = {1: (W, 9), 11: (W, 1), 16: (W, 1), 17: (W, 1), 18: (W, 1), 19: (W, 1), 20: (W, 1)}
        pts.update(black)
        b = mk(pts)
        sigs = {result_sig(b, m, W) for m in moves(b, W, 4, 1)}
        return result_sig(b, mv((11, 15), (1, 2)), W) in sigs

    def test_f9a_six_prime_all_behind_illegal(self):
        self.assertFalse(self._f9({13: (B, 14), 14: (B, 1)}))

    def test_f9b_six_prime_with_checker_ahead_legal(self):
        self.assertTrue(self._f9({13: (B, 14), 22: (B, 1)}))

    def test_f10_larger_die(self):
        b = mk({10: (W, 1), 24: (W, 14), 19: (B, 1), 13: (B, 14)})
        self.assertMoves(moves(b, W, 5, 4), [mv((10, 15))])

    def test_r2_off_borne_opponent_allows_prime(self):
        # Same as F9a but Black has borne a checker off => "ahead" => prime allowed.
        pts = {1: (W, 9), 11: (W, 1), 16: (W, 1), 17: (W, 1), 18: (W, 1), 19: (W, 1),
               20: (W, 1), 13: (B, 13), 14: (B, 1)}
        b = mk(pts, off_b=1)
        sigs = {result_sig(b, m, W) for m in moves(b, W, 4, 1)}
        self.assertIn(result_sig(b, mv((11, 15), (1, 2)), W), sigs)


# ---------------------------------------------------------------------------
# Slow reference generator, written directly from the spec on physical boards.
# ---------------------------------------------------------------------------

def _ref_path_counts(board, c):
    return {p: board.n[SLOT_OF[c][p]] for p in range(1, 25)
            if board.n[SLOT_OF[c][p]] and board.color[SLOT_OF[c][p]] == c}


def _ref_unlocked(board, c):
    return board.borne_off[c] > 0 or any(p >= 14 for p in _ref_path_counts(board, c))


def _ref_half_moves(board, c, d):
    own = _ref_path_counts(board, c)
    out = []
    all_home = all(p >= 19 for p in own)
    for p in sorted(own):
        if not _ref_unlocked(board, c):
            all_on_start = own.get(1, 0) == board.pieces_per_player
            if p == 1 and not all_on_start:
                continue
        t = p + d
        if t <= 24:
            s = SLOT_OF[c][t]
            if board.n[s] and board.color[s] != c:
                continue
            out.append((SLOT_OF[c][p], s))
        elif all_home and (t == 25 or p == min(own)):
            out.append((SLOT_OF[c][p], OFF_SLOT[c]))
    return out


def ref_forbidden(board, c):
    """R1 or R2 holds for colour c on board."""
    own = _ref_path_counts(board, c)
    if all(p in own for p in range(1, 7)):
        return True
    o = -c
    if board.borne_off[o] > 0:
        return False
    opp_paths = [PATH_OF[o][s] for s in range(1, 25) if board.n[s] and board.color[s] == o]
    front = max(opp_paths)
    for q in range(1, 20):
        pts = [SLOT_OF[o][q + k] for k in range(6)]
        if all(board.n[s] and board.color[s] == c for s in pts) and front < q:
            return True
    return False


def ref_legal_results(board, c, d1, d2):
    """Set of resulting position signatures of all legal plays (empty = pass)."""
    orders = [(d1,) * 4] if d1 == d2 else [(d1, d2), (d2, d1)]
    cands = []   # (n_dice, first_die, sig)

    def rec(b, rem, used, first):
        if not ref_forbidden(b, c):
            cands.append((used, first, sig(b)))
        if not rem:
            return
        for s, t in _ref_half_moves(b, c, rem[0]):
            b2 = b.clone()
            b2.apply_half(s, t, c)
            rec(b2, rem[1:], used + 1, first or rem[0])

    for order in orders:
        rec(board.clone(), order, 0, 0)
    m = max(u for u, _, _ in cands) if cands else 0
    if m == 0:
        return set()
    best = [x for x in cands if x[0] == m]
    if m == 1 and d1 != d2:
        big = max(d1, d2)
        if any(f == big for _, f, _ in best):
            best = [x for x in best if x[1] == big]
    return {s for _, _, s in best}


def random_game(rng, max_plies=20000, check=None):
    b = FevgaBoard.initial(pieces_per_player=15)
    color = rng.choice((W, B))
    dice = Dice(rng=rng)
    plies = passes = 0
    while not (b.has_won(W) or b.has_won(B)):
        if plies >= max_plies:
            return b, plies, passes, False
        dice.roll()
        ms = fevga_legal_moves(b, color, dice)
        if check:
            check(b, color, dice, ms)
        if ms:
            b.apply(rng.choice(ms), color)
        else:
            passes += 1
        plies += 1
        color = -color
    return b, plies, passes, True


class TestRandomGames(unittest.TestCase):
    def test_invariants_over_random_games(self):
        rng = random.Random(1234)
        stats = {"lengths": [], "moves_checked": 0}

        def check(b, color, dice, ms):
            before = sig(b)
            seen = set()
            for m in ms:
                tok = b.apply(m, color)
                # 15 checkers per side conserved, one colour per point.
                for c in (W, B):
                    on = sum(b.n[s] for s in range(1, 25) if b.color[s] == c)
                    self.assertEqual(on + b.borne_off[c], 15)
                for s in range(1, 25):
                    self.assertEqual(b.n[s] == 0, b.color[s] == 0)
                self.assertFalse(ref_forbidden(b, color), f"forbidden end position after {m}\n{b}")
                s_after = sig(b)
                self.assertNotIn(s_after, seen, "duplicate resulting position")
                seen.add(s_after)
                b.undo(tok)
                self.assertEqual(sig(b), before, f"apply/undo mismatch for {m}")
                stats["moves_checked"] += 1

        for _ in range(200):
            b, plies, passes, done = random_game(rng, check=check)
            self.assertTrue(done, f"game did not terminate within {plies} plies\n{b}")
            stats["lengths"].append(plies)
        self.assertGreater(stats["moves_checked"], 10000)

    def test_matches_reference_generator(self):
        rng = random.Random(99)
        checked = [0]

        def check(b, color, dice, ms):
            if rng.random() > 0.25:
                return
            got = {result_sig(b, m, color) for m in ms}
            want = ref_legal_results(b, color, dice.die1.value, dice.die2.value)
            self.assertEqual(got, want, f"color={color} dice={dice}\n{b}")
            self.assertEqual(len(ms), len(got))
            checked[0] += 1

        for _ in range(25):
            random_game(rng, check=check)
        self.assertGreater(checked[0], 500)

    def test_apply_undo_roundtrip_fuzz(self):
        rng = random.Random(7)
        b = FevgaBoard.initial(pieces_per_player=15)
        dice = Dice(rng=rng)
        history = []
        color = W
        for _ in range(300):
            if b.has_won(W) or b.has_won(B):
                break
            dice.roll()
            ms = fevga_legal_moves(b, color, dice)
            if ms:
                history.append((sig(b), b.apply(rng.choice(ms), color)))
            color = -color
        clone = b.clone()
        self.assertEqual(sig(clone), sig(b))
        for before, tok in reversed(history):
            b.undo(tok)
            self.assertEqual(sig(b), before)
        self.assertEqual(sig(b), sig(FevgaBoard.initial(pieces_per_player=15)))


if __name__ == "__main__":
    unittest.main()
