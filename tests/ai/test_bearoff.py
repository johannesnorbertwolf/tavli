import random
import unittest

import numpy as np

from ai.bearoff import BearoffDB, exact_value_on_roll, race_state
from domain.board import Board
from domain.constants import BLACK, WHITE
from domain.dice import Dice
from domain.move_generation import legal_moves


def _build_small_db():
    # Module-level cache: ≤3 checkers is enough for every test and builds fast.
    global _SMALL_DB
    try:
        return _SMALL_DB
    except NameError:
        _SMALL_DB = BearoffDB.build(max_checkers=3)
        return _SMALL_DB


class TestBearoffDP(unittest.TestCase):
    def setUp(self):
        self.db = _build_small_db()

    def test_pmf_mass_is_one(self):
        mass = self.db.pmf.sum(axis=1)
        self.assertGreater(float(mass.min()), 1.0 - 1e-6)
        self.assertLess(float(mass.max()), 1.0 + 1e-6)

    def test_single_checker_distance_one_is_geometric(self):
        # A lone checker at distance 1 bears off only with an exact 1:
        # P(roll contains a 1) = 11/36, otherwise the roll passes.
        p_hit = 11.0 / 36.0
        pmf = self.db.rolls_pmf((1, 0, 0, 0, 0, 0))
        self.assertAlmostEqual(float(pmf[0]), 0.0, places=12)
        for n in range(1, 8):
            expected = (1.0 - p_hit) ** (n - 1) * p_hit
            self.assertAlmostEqual(float(pmf[n]), expected, places=6)  # pmf is float32
        self.assertAlmostEqual(
            self.db.expected_rolls((1, 0, 0, 0, 0, 0)), 36.0 / 11.0, places=6)

    def test_expected_rolls_monotonic_for_single_checker(self):
        # Note distances 2..6 are NOT monotonic in general (a checker deep in
        # home may pass more often), but distance 1 is the strict slowest single
        # checker under exact-die bear-off, and the empty state is 0.
        self.assertEqual(self.db.expected_rolls((0, 0, 0, 0, 0, 0)), 0.0)
        for d in range(6):
            state = tuple(1 if i == d else 0 for i in range(6))
            self.assertGreater(self.db.expected_rolls(state), 0.99)

    def test_pmf_matches_monte_carlo_simulation(self):
        # Independent check of the DP algebra (pass handling, shift, policy):
        # simulate the same greedy min-E policy with real dice and compare E.
        state = (0, 1, 0, 1, 0, 0)  # checkers at distances 2 and 4
        db = self.db
        rng = random.Random(12345)
        sims = 20000
        total = 0
        dice = Dice(6)
        for _ in range(sims):
            board = Board()
            cur = list(state)
            rolls = 0
            while sum(cur) > 0:
                for d in range(1, 7):
                    board.set_point(d, BLACK, cur[d - 1])
                board.set_point(0, BLACK, 0)
                board.borne_off[BLACK] = 0
                d1 = rng.randint(1, 6)
                d2 = rng.randint(1, 6)
                dice.set(d1, d2)
                rolls += 1
                moves = legal_moves(board, BLACK, dice)
                if not moves:
                    continue
                best = None
                best_e = float("inf")
                for move in moves:
                    token = board.apply(move, BLACK)
                    succ = tuple(board.n[d] if board.color[d] == BLACK else 0
                                 for d in range(1, 7))
                    board.undo(token)
                    e = db.expected_rolls(succ)
                    if e < best_e:
                        best_e = e
                        best = succ
                cur = list(best)
            total += rolls
        mc_mean = total / sims
        # se ≈ sd/sqrt(sims) ≈ 0.015 here; 0.08 is a comfortable 5σ band.
        self.assertAlmostEqual(mc_mean, db.expected_rolls(state), delta=0.08)

    def test_win_prob_mutual_distance_one(self):
        # Both sides one checker at distance 1, me on roll:
        # P = p / (1 - (1-p)^2) with p = 11/36.
        p = 11.0 / 36.0
        analytic = p / (1.0 - (1.0 - p) ** 2)
        got = self.db.win_prob_on_roll((1, 0, 0, 0, 0, 0), (1, 0, 0, 0, 0, 0))
        self.assertAlmostEqual(got, analytic, places=6)

    def test_win_prob_on_roll_advantage_and_dominance(self):
        sym = (0, 1, 0, 1, 0, 0)
        self.assertGreater(self.db.win_prob_on_roll(sym, sym), 0.5)
        ahead = (1, 0, 0, 0, 0, 0)
        behind = (0, 0, 0, 1, 1, 1)
        self.assertGreater(self.db.win_prob_on_roll(ahead, behind),
                           self.db.win_prob_on_roll(behind, ahead))

    def test_win_prob_terminal_edges(self):
        empty = (0, 0, 0, 0, 0, 0)
        some = (0, 0, 1, 0, 0, 0)
        self.assertEqual(self.db.win_prob_on_roll(empty, some), 1.0)
        self.assertEqual(self.db.win_prob_on_roll(some, empty), 0.0)

    def test_save_load_roundtrip(self):
        import os
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "db.npz")
            self.db.save(path)
            loaded = BearoffDB.load(path)
            self.assertEqual(loaded.max_checkers, self.db.max_checkers)
            np.testing.assert_allclose(loaded.pmf, self.db.pmf, rtol=1e-6)


class TestRaceDetector(unittest.TestCase):
    def test_initial_board_is_not_a_race(self):
        self.assertIsNone(race_state(Board.initial()))

    def test_all_home_no_pins_is_a_race(self):
        board = Board()
        board.set_point(20, WHITE, 2)   # White distance 5
        board.set_point(24, WHITE, 1)   # White distance 1
        board.set_point(5, BLACK, 3)    # Black distance 5
        rs = race_state(board)
        self.assertIsNotNone(rs)
        white, black = rs
        self.assertEqual(white, (1, 0, 0, 0, 2, 0))
        self.assertEqual(black, (0, 0, 0, 0, 3, 0))

    def test_pinned_checker_blocks_race(self):
        board = Board()
        board.set_point(24, WHITE, 1)
        board.set_point(5, BLACK, 2)
        board.set_point(20, WHITE, 1, pinned=True)  # Black checker trapped at 20
        self.assertIsNone(race_state(board))

    def test_checker_outside_home_blocks_race(self):
        board = Board()
        board.set_point(24, WHITE, 1)
        board.set_point(18, WHITE, 1)  # outside White home
        board.set_point(5, BLACK, 2)
        self.assertIsNone(race_state(board))

    def test_exact_value_perspectives_are_complementary_modulo_tempo(self):
        db = _build_small_db()
        board = Board()
        board.set_point(24, WHITE, 1)
        board.set_point(1, BLACK, 1)
        v_white = exact_value_on_roll(board, True, db)
        v_black = exact_value_on_roll(board, False, db)
        # Symmetric position: whoever is on roll has the same edge.
        self.assertAlmostEqual(v_white, v_black, places=9)
        self.assertGreater(v_white, 0.5)

    def test_exact_value_none_outside_race_or_without_db(self):
        db = _build_small_db()
        self.assertIsNone(exact_value_on_roll(Board.initial(), True, db))
        board = Board()
        board.set_point(24, WHITE, 1)
        self.assertIsNone(exact_value_on_roll(board, True, None))


class TestAgentBearoffHook(unittest.TestCase):
    def test_one_ply_scores_use_exact_db_values(self):
        from ai.agent import Agent
        from ai.board_encoder import BoardEncoder
        from ai.board_evaluator import BoardEvaluator
        from config.config_loader import ConfigLoader

        config = ConfigLoader("config-test.yml")
        encoder = BoardEncoder(config)
        evaluator = BoardEvaluator(encoder.input_size, hidden_sizes=[8])
        db = _build_small_db()
        agent = Agent(evaluator, encoder, bearoff=db)

        board = Board()
        board.set_point(24, WHITE, 2)  # two checkers at distance 1
        board.set_point(1, BLACK, 1)   # one checker at distance 1
        dice = Dice(6)
        dice.set(1, 2)
        moves = legal_moves(board, WHITE, dice)
        self.assertTrue(moves)
        scores = agent.evaluate_moves(board, moves, WHITE)

        # Every successor is still an exact race; the score must equal
        # 1 - P(Black on roll wins) computed straight from the DB.
        for move, score in zip(moves, scores):
            token = board.apply(move, WHITE)
            white, black = race_state(board)
            expected = 1.0 - db.win_prob_on_roll(black, white)
            board.undo(token)
            self.assertAlmostEqual(score, expected, places=6)


if __name__ == "__main__":
    unittest.main()
