"""Handicap-aware model (#148 E3): unary_v3_hc1 encoder, warm start from gold_v11,
checkpoint compatibility, self-play mix, handicapped paired eval, tier-2 sweep cells."""

import os
import random
import tempfile
import unittest
from pathlib import Path

import numpy as np
import torch
import yaml

from ai.board_encoder import BoardEncoder, UNARY_V3
from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import (
    VariantMismatchError, check_checkpoint_variant, load_agent_from_checkpoint, load_state_dict,
    save_checkpoint,
)
from ai.handicap_encoder import HandicapEncoder, SIDE_FEATURES, UNARY_V3_HC1
from ai.handicap_model import init_handicap_model, widen_input
from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.handicap import HandicapBoard, parse_spec, sample_tier2_specs, tier2_board
from game.game import Game

ROOT = Path(__file__).resolve().parents[2]
GOLD = ROOT / "models" / "gold_v11.pth"
PLAIN = ConfigLoader(str(ROOT / "config-test.yml"))


def hc_config(d, **extra):
    """A plakoto_hc copy of config-test.yml in tmp dir `d`."""
    with open(ROOT / "config-test.yml") as fh:
        cfg = yaml.safe_load(fh)
    cfg.update(variant="plakoto_hc", hidden_sizes=[16, 8])
    cfg.update(extra)
    path = os.path.join(d, "hc.yml")
    with open(path, "w") as fh:
        yaml.safe_dump(cfg, fh)
    return ConfigLoader(path)


def random_positions(n_games=4, seed=0, board_factory=None):
    """Positions from random play (house rules), both perspectives."""
    rng = random.Random(seed)
    out = []
    for g in range(n_games):
        b = board_factory(g) if board_factory else Board.initial(PLAIN)
        from domain.handicap_moves import legal_moves_tier2
        p, d = BLACK, Dice()
        for _ in range(200):
            d.set(rng.randint(1, 6), rng.randint(1, 6))
            ms = legal_moves_tier2(b, p, d)
            if ms:
                b.apply(rng.choice(ms), p)
            if b.has_won(WHITE) or b.has_won(BLACK):
                break
            out.append(b.clone())
            p = -p
    return out


class TestEncoder(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = hc_config(self.tmp.name)
        self.enc = HandicapEncoder(self.cfg)
        self.base = BoardEncoder(self.cfg, version=UNARY_V3)

    def tearDown(self):
        self.tmp.cleanup()

    def test_size_and_ruleset_wiring(self):
        self.assertEqual(self.enc.input_size, 486 + 26 * 2 + 2 * SIDE_FEATURES)
        self.assertEqual(self.enc.input_size, 606)
        rs = self.cfg.get_ruleset()
        self.assertEqual(rs.make_encoder(self.cfg).version, UNARY_V3_HC1)
        self.assertEqual(rs.make_encoder(self.cfg, version="unary_v3").input_size, 486)

    def test_normal_positions_are_unary_v3_plus_zeros(self):
        for b in random_positions(3):
            for w in (True, False):
                x = self.enc.encode_board(b, w)
                np.testing.assert_array_equal(x[:486], self.base.encode_board(b, w))
                self.assertFalse(x[486:].any())
        # A HandicapBoard without any active lever encodes like a plain board too.
        hb = HandicapBoard(24, 6, 15)
        hb.set_point(1, WHITE, 15)
        hb.set_point(24, BLACK, 15)
        np.testing.assert_array_equal(self.enc.encode_board(hb, True),
                                      self.enc.encode_board(Board.initial(PLAIN), True))

    def test_handicap_block_mover_perspective(self):
        # White handicapped: Black favoured with overshoot + safe point 6; White plays 17
        # checkers from a 4-point home.
        specs = [parse_spec(t, WHITE) for t in
                 ("overshoot", "safe_point:6", "checkers:17", "smaller_house:4")]
        b = tier2_board(specs, self.cfg)
        o = 486 + 52
        for white_to_move, own, opp in ((True, WHITE, BLACK), (False, BLACK, WHITE)):
            x = self.enc.encode_board(b, white_to_move)
            blocks = {own: x[o:o + SIDE_FEATURES], opp: x[o + SIDE_FEATURES:]}
            fav, hcp = blocks[BLACK], blocks[WHITE]
            self.assertEqual(fav[0], 1.0)                      # overshoot
            self.assertEqual(fav[6], 1.0)                      # safe point 6 one-hot
            self.assertEqual(fav[1:25].sum(), 1.0)
            self.assertFalse(fav[25:].any())                   # 15 checkers, 6-point home
            self.assertEqual(hcp[0], 0.0)
            self.assertFalse(hcp[1:25].any())
            self.assertAlmostEqual(hcp[25], 1.0)               # (17 - 15) / 2
            self.assertEqual(hcp[26 + 3], 1.0)                 # one-hot 17
            self.assertAlmostEqual(hcp[30], 2 / 3)             # (6 - 4) / 3
            self.assertEqual(hcp[31 + 1], 1.0)                 # one-hot 4

    def test_seventeen_checker_stack_overflow(self):
        b = tier2_board([parse_spec("checkers:17", WHITE)], self.cfg)
        # unary_v3 saturates at 15 without spilling into the next slot's colour bit.
        x = self.base.encode_board(b, True)
        ps = 18
        self.assertEqual(x[1 * ps + 3: 1 * ps + 18].sum(), 15)
        self.assertEqual(x[2 * ps], 0.0)
        y = self.enc.encode_board(b, True)
        self.assertEqual(list(y[486 + 2 * 1: 486 + 2 * 1 + 2]), [1.0, 1.0])   # slot 1, White view
        z = self.enc.encode_board(b, False)                                  # Black view: slot 24
        self.assertEqual(list(z[486 + 2 * 24: 486 + 2 * 24 + 2]), [1.0, 1.0])
        self.assertEqual(y[486:538].sum(), 2.0)
        b16 = tier2_board([parse_spec("checkers:16", WHITE)], self.cfg)
        self.assertEqual(self.enc.encode_board(b16, True)[486:538].sum(), 1.0)


class TestWarmStart(unittest.TestCase):
    def test_widen_input_is_exact_on_normal_positions(self):
        torch.manual_seed(0)
        with tempfile.TemporaryDirectory() as d:
            cfg = hc_config(d)
            enc = HandicapEncoder(cfg)
            base = BoardEncoder(cfg, version=UNARY_V3)
            old = BoardEvaluator(486, hidden_sizes=[16, 8]).eval()
            new = widen_input(old, enc.input_size)
            self.assertEqual(new.layers[0].in_features, 606)
            self.assertFalse(new.layers[0].weight[:, 486:].any())
            with torch.no_grad():
                for b in random_positions(3, seed=1):
                    for w in (True, False):
                        a = old(torch.from_numpy(base.encode_board(b, w))[None]).item()
                        c = new(torch.from_numpy(enc.encode_board(b, w))[None]).item()
                        self.assertAlmostEqual(a, c, delta=1e-6)

    @unittest.skipUnless(GOLD.exists(), "gold_v11 not present")
    def test_gold_v11_warm_start_equality(self):
        """The acceptance check: the widened gold_v11 evaluates every normal position like
        gold_v11 itself (float32 rounding only)."""
        with tempfile.TemporaryDirectory() as d:
            cfg = hc_config(d, hidden_sizes=[256, 128, 64])
            out = os.path.join(d, "hc_v1.pth")
            init_handicap_model(str(GOLD), out, cfg)
            _, meta = load_state_dict(out)
            self.assertEqual((meta["variant"], meta["encoder_version"]), ("plakoto_hc", UNARY_V3_HC1))
            self.assertIsNone(meta["optimizer_state_dict"])
            gold, _ = load_agent_from_checkpoint(str(GOLD), cfg)
            hc, _ = load_agent_from_checkpoint(out, cfg)
            self.assertEqual(gold.board_encoder.version, "unary_v3")
            self.assertEqual(hc.board_encoder.input_size, 606)
            dev = 0.0
            with torch.no_grad():
                for b in random_positions(6, seed=2):
                    for w in (True, False):
                        a = gold.board_evaluator(
                            torch.from_numpy(gold.board_encoder.encode_board(b, w))[None]).item()
                        c = hc.board_evaluator(
                            torch.from_numpy(hc.board_encoder.encode_board(b, w))[None]).item()
                        dev = max(dev, abs(a - c))
            self.assertLess(dev, 1e-6)
            # ... and therefore picks the same moves.
            b = Board.initial(cfg)
            for d1 in range(1, 7):
                for d2 in range(d1, 7):
                    dd = Dice(); dd.set(d1, d2)
                    ms = hc.ruleset.legal_moves(b, WHITE, dd)
                    self.assertEqual(gold.get_best_move(b, ms, WHITE)[0],
                                     hc.get_best_move(b, ms, WHITE)[0])

    def test_refuses_wrong_sources(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(ValueError):
                init_handicap_model("x.pth", os.path.join(d, "o.pth"), PLAIN)   # not plakoto_hc


class TestCheckpointCompat(unittest.TestCase):
    def test_plakoto_loads_under_hc_but_not_reverse(self):
        with tempfile.TemporaryDirectory() as d:
            cfg = hc_config(d)
            check_checkpoint_variant({"variant": "plakoto"}, cfg)        # compatible: no raise
            check_checkpoint_variant({"variant": "plakoto_hc"}, cfg)
            with self.assertRaises(VariantMismatchError):
                check_checkpoint_variant({"variant": "plakoto_hc"}, PLAIN)
            with self.assertRaises(VariantMismatchError):
                check_checkpoint_variant({"variant": "portes"}, cfg)
            # A plakoto checkpoint under plakoto_hc plays by the superset's rules.
            p = os.path.join(d, "plain.pth")
            save_checkpoint(p, BoardEvaluator(486, hidden_sizes=[16, 8]), PLAIN)
            agent, meta = load_agent_from_checkpoint(p, cfg)
            self.assertEqual(agent.ruleset.name, "plakoto_hc")
            self.assertEqual(agent.board_encoder.version, "unary_v3")


class TestSelfPlay(unittest.TestCase):
    def test_mix_fraction_and_game_record(self):
        from ai.agent import Agent
        from ai.self_play_worker import maybe_handicap_board, play_one_game_record
        with tempfile.TemporaryDirectory() as d:
            cfg = hc_config(d, handicap_selfplay_fraction=1.0, bootstrap_depth=2)
            enc = cfg.get_ruleset().make_encoder(cfg)
            agent = Agent(BoardEvaluator(enc.input_size, hidden_sizes=[16, 8]).eval(), enc,
                          ruleset=cfg.get_ruleset())
            random.seed(3); np.random.seed(3)
            traj = play_one_game_record(agent, enc, cfg, 0.0, 1.0, bootstrap_depth=2)
            self.assertGreater(traj["plies"], 0)
            self.assertEqual(len(traj["states"]), traj["plies"] + 1)
            self.assertEqual(traj["states"][0].shape, (606,))
            self.assertTrue(traj["states"][0][538:].any())         # a handicapped start
            # fraction 0 never touches the rng and keeps the plain board
            plain_cfg = hc_config(d)
            g = Game(plain_cfg)
            state = random.getstate()
            self.assertEqual(maybe_handicap_board(g, plain_cfg), ())
            self.assertEqual(random.getstate(), state)
            self.assertIs(type(g.board), Board)
            # fraction share
            random.seed(1)
            hits = sum(bool(maybe_handicap_board(Game(plain_cfg), plain_cfg, fraction=0.7))
                       for _ in range(2000))
            self.assertAlmostEqual(hits / 2000, 0.7, delta=0.04)

    def test_trainer_rejects_mix_without_hc_variant(self):
        from ai.td_lambda_training import TdLambdaTraining
        with tempfile.TemporaryDirectory() as d:
            with open(ROOT / "config-test.yml") as fh:
                c = yaml.safe_load(fh)
            c.update(handicap_selfplay_fraction=0.5, hidden_sizes=[8],
                     training_state_path=os.path.join(d, "ts.json"))
            p = os.path.join(d, "c.yml")
            with open(p, "w") as fh:
                yaml.safe_dump(c, fh)
            cfg = ConfigLoader(p)
            enc = cfg.get_ruleset().make_encoder(cfg)
            with self.assertRaises(ValueError):
                TdLambdaTraining(BoardEvaluator(enc.input_size, hidden_sizes=[8]), enc, cfg)


class TestHandicappedPairedEval(unittest.TestCase):
    def test_setup_per_seed_and_self_comparison(self):
        from ai.agent import Agent
        from ai.paired_eval import handicap_specs_for_seed, run_pairs
        self.assertEqual(handicap_specs_for_seed(5), handicap_specs_for_seed(5))
        self.assertNotEqual([handicap_specs_for_seed(s) for s in range(10)],
                            [handicap_specs_for_seed(5)] * 10)
        with tempfile.TemporaryDirectory() as d:
            cfg = hc_config(d)
            enc = cfg.get_ruleset().make_encoder(cfg)
            torch.manual_seed(1)
            agent = Agent(BoardEvaluator(enc.input_size, hidden_sizes=[16, 8]).eval(), enc,
                          ruleset=cfg.get_ruleset())
            res = run_pairs(agent, agent, cfg, [0, 1, 2], 1, handicap=True)
            self.assertEqual([r[0] for r in res], [0, 0, 0])


class TestTier2Sweep(unittest.TestCase):
    def test_cells_and_rules(self):
        from ai.handicap_sweep import (
            DEFAULT_TIER2_COMBOS, cell_uses_bearoff_db, default_cells, is_estimable, parse_cell,
            play_pair, rules_for,
        )
        cell = parse_cell("overshoot:1+safe_point:6+checkers:14+smaller_house:4")
        r = rules_for(cell, WHITE)       # White handicapped
        b = r.initial_board(PLAIN)
        self.assertEqual((b.overshoot[BLACK], b.safe_point[BLACK], b.checkers[BLACK],
                          b.home_white), (True, 6, 14, 4))
        tier2 = default_cells(tier2=True)
        self.assertIn((("safe_point", 6),), tier2)
        self.assertNotIn((("dice_ceiling", 5),), tier2)
        self.assertNotIn((("overshoot", 1),), default_cells())  # plain sweeps unchanged
        for c in DEFAULT_TIER2_COMBOS:
            parse_cell(c)
        self.assertTrue(is_estimable(cell, handicap_model=True))
        self.assertFalse(is_estimable(cell))
        self.assertTrue(cell_uses_bearoff_db(parse_cell("smaller_house:4"), True))
        self.assertFalse(cell_uses_bearoff_db(parse_cell("smaller_house:4")))
        with tempfile.TemporaryDirectory() as d:
            cfg = hc_config(d)
            from ai.agent import Agent
            enc = cfg.get_ruleset().make_encoder(cfg)
            agent = Agent(BoardEvaluator(enc.input_size, hidden_sizes=[16, 8]).eval(), enc,
                          ruleset=cfg.get_ruleset())
            out = play_pair(agent, cfg, parse_cell("overshoot:1+checkers:16"), seed=3)
            self.assertIn(out["h"], (0.0, 0.5, 1.0, 1.5, 2.0))


if __name__ == "__main__":
    unittest.main()
