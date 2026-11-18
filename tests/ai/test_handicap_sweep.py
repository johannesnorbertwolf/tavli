"""Handicap harness (#148): no-handicap equivalence, determinism, pairing, stats."""

import unittest
from pathlib import Path

from ai.checkpoint_io import load_agent_from_checkpoint
import json
import subprocess
import sys
import tempfile

from ai.handicap_sweep import (
    REROLL_MARGIN, cell_label, cell_uses_bearoff_db, default_cells, is_estimable, parse_cell,
    play_game, play_pair, rules_for, start_estimate, summarize_cell, to_markdown, wants_reroll,
)
from domain.handicap import ROLLS, roll_index
from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from game.game import Game

ROOT = Path(__file__).resolve().parents[2]
GOLD = ROOT / "models" / "gold_v11.pth"


class TestCells(unittest.TestCase):
    def test_parse_and_label(self):
        c = parse_cell("dice_ceiling:5+first_mover")
        self.assertEqual(c, (("dice_ceiling", 5), ("first_mover", 1)))
        self.assertEqual(cell_label(c), "dice_ceiling:5 + first_mover:1")
        self.assertEqual(cell_label(()), "baseline")
        self.assertEqual(default_cells(["first_mover"]), [(), (("first_mover", 1),)])

    def test_parse_tier1_combo(self):
        c = parse_cell("weighted_dice:2+rerolls:1+first_mover:1")
        self.assertEqual(c, (("weighted_dice", 2), ("rerolls", 1), ("first_mover", 1)))
        self.assertEqual(cell_label(c), "weighted_dice:2 + rerolls:1 + first_mover:1")
        self.assertEqual(parse_cell("weighted_dice:0.5"), (("weighted_dice", 0.5),))
        r = rules_for(c, WHITE)
        self.assertEqual((r.reroll_tokens(BLACK), r.roll_beta(BLACK), r.first_mover(WHITE)),
                         (1, 2.0, BLACK))
        self.assertTrue(is_estimable(parse_cell("pip_headstart:4+first_mover")))
        self.assertFalse(is_estimable(c))

    def test_reroll_policy(self):
        vals = [0.5] * 21
        vals[roll_index(1, 2)] = 0.40     # bad roll
        vals[roll_index(6, 6)] = 0.90     # great roll
        e = sum(w * v for (_, _, w), v in zip(ROLLS, vals))
        self.assertTrue(wants_reroll(vals, 2, 1))
        self.assertFalse(wants_reroll(vals, 6, 6))
        self.assertFalse(wants_reroll(vals, 3, 4))              # 0.5 is above E - margin
        self.assertTrue(wants_reroll(vals, 3, 4, margin=-0.02))  # margin is honoured
        self.assertLess(abs(e - 0.5), REROLL_MARGIN)
        # Expectation under weighted dice: a strong tilt towards 6-6 raises the bar.
        self.assertTrue(wants_reroll(vals, 3, 4, beta=30.0))
        # Pure function of its inputs.
        self.assertEqual([wants_reroll(vals, a, b) for a in range(1, 7) for b in range(1, 7)],
                         [wants_reroll(list(vals), a, b) for a in range(1, 7) for b in range(1, 7)])

    def test_bearoff_db_only_off_for_geometry(self):
        self.assertTrue(cell_uses_bearoff_db(()))
        self.assertTrue(cell_uses_bearoff_db(parse_cell("dice_ceiling:4+pre_borne:2")))
        self.assertFalse(cell_uses_bearoff_db(parse_cell("smaller_house:4+first_mover")))

    def test_summary_stats(self):
        mk = lambda s, h, wa: {"seed": s, "h": h,
                               "a": {"winner": wa, "plies": 100, "pin": False},
                               "b": {"winner": WHITE, "plies": 80, "pin": True}}
        pairs = [mk(0, 0.0, BLACK), mk(1, 1.0, WHITE), mk(2, 2.0, WHITE), mk(3, 1.0, BLACK)]
        s = summarize_cell((("pass_turns", 2),), pairs)
        self.assertAlmostEqual(s["rate"], 0.5)
        self.assertLess(s["ci_lo"], 0.5)
        self.assertGreater(s["ci_hi"], 0.5)
        self.assertEqual(s["games"], 8)
        self.assertAlmostEqual(s["pin_win_frac"], 0.5)
        self.assertAlmostEqual(s["first_mover_win"], 0.5)
        base = summarize_cell((), [mk(0, 1.0, WHITE)])
        self.assertIn("`pass_turns:2`", to_markdown([base, s]))


@unittest.skipUnless(GOLD.exists(), "gold_v11 checkpoint not present")
class TestHarness(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader(str(ROOT / "config-test.yml"))
        cls.agent, _ = load_agent_from_checkpoint(str(GOLD), cls.config)

    def test_no_handicap_matches_plain_game(self):
        """The harness with no handicap plays exactly the plain Game on the same dice."""
        trace = []
        g = play_game(self.agent, self.config, rules_for((), WHITE), seed=7, trace=trace)
        game = Game(self.config, starting_player=WHITE)
        dice = Dice(6)
        for player, (d1, d2, _), move in trace:
            self.assertEqual(game.current_player, player)
            dice.set(d1, d2)
            moves = game.ruleset.legal_moves(game.board, player, dice)
            if moves:
                ref, _ = self.agent.get_best_move(game.board, moves, player, lookahead_plies=1)
                self.assertEqual(ref, move)
                game.board.apply(ref, player)
            else:
                self.assertIsNone(move)
            game.switch_turn()
        self.assertTrue(game.is_over())
        self.assertEqual(game.get_winner(), g["winner"])

    def test_baseline_pair_is_symmetric(self):
        for s in range(3):
            r = play_pair(self.agent, self.config, (), s)
            self.assertEqual(r["h"], 1.0)
            self.assertEqual(r["a"]["plies"], r["b"]["plies"])

    def test_deterministic_under_seed(self):
        cell = parse_cell("dice_ceiling:4+no_doubles:0.5")
        a = play_pair(self.agent, self.config, cell, 11)
        b = play_pair(self.agent, self.config, cell, 11)
        self.assertEqual(a, b)

    def test_pass_turns_skip_logged(self):
        trace = []
        play_game(self.agent, self.config, rules_for(parse_cell("pass_turns:2"), BLACK), 3, trace)
        own = [t for t in trace if t[0] == BLACK]
        skipped = [i + 1 for i, t in enumerate(own) if t[2] == "skip"]
        self.assertEqual(skipped, [13, 27][:len(skipped)])
        self.assertTrue(all(t[2] != "skip" for t in trace if t[0] == WHITE))

    def test_weighted_beta_zero_is_fair_game(self):
        """β = 0 (exact fair path) and a vanishing β (the tilted-CDF path, valuer consulted
        every favoured turn) both replay the plain game move for move."""
        for seed in (2, 5):
            t0 = []
            g0 = play_game(self.agent, self.config, rules_for((), WHITE), seed, t0)
            for text in ("weighted_dice:0", "weighted_dice:1e-9"):
                t1 = []
                g1 = play_game(self.agent, self.config, rules_for(parse_cell(text), WHITE),
                               seed, t1)
                self.assertEqual(t0, t1, text)
                self.assertEqual(g0, g1, text)

    def test_weighted_dice_deterministic_and_aligned(self):
        cell = parse_cell("weighted_dice:8")
        a = play_pair(self.agent, self.config, cell, 4)
        b = play_pair(self.agent, self.config, cell, 4)
        self.assertEqual(a, b)
        # The handicapped side's own rolls are the plain stream's: its first roll matches.
        t_plain, t_w = [], []
        play_game(self.agent, self.config, rules_for((), WHITE), 4, t_plain)
        play_game(self.agent, self.config, rules_for(cell, WHITE), 4, t_w)
        self.assertEqual(t_plain[0][:2], t_w[0][:2])

    def test_reroll_token_accounting(self):
        for n in (1, 3):
            for seed in range(3):
                trace = []
                g = play_game(self.agent, self.config, rules_for(parse_cell(f"rerolls:{n}"), WHITE),
                              seed, trace)
                rr = [t for t in trace if t[2] == "reroll"]
                self.assertLessEqual(len(rr), n)
                self.assertEqual(len(rr), g["rerolls"])
                self.assertTrue(all(t[0] == BLACK for t in rr))  # only the favoured side
        # Policy determinism: same seed, same rerolls and game.
        cell = parse_cell("rerolls:2+weighted_dice:2")
        self.assertEqual(play_pair(self.agent, self.config, cell, 8),
                         play_pair(self.agent, self.config, cell, 8))

    def test_main_stream_alignment_under_rerolls(self):
        """A reroll never consumes main-stream uniforms: the unfavoured side's first roll
        after the favoured side's first (possibly rerolled) turn is the plain one."""
        trace_p, trace_r = [], []
        play_game(self.agent, self.config, rules_for((), WHITE), 1, trace_p)
        play_game(self.agent, self.config, rules_for(parse_cell("rerolls:4"), WHITE), 1, trace_r)
        first_white = lambda tr: [t[1] for t in tr if t[0] == WHITE and t[2] != "reroll"][0]
        self.assertEqual(first_white(trace_p), first_white(trace_r))

    def test_start_estimate(self):
        self.assertEqual(start_estimate(self.agent, self.config, ()), 0.5)
        fm = start_estimate(self.agent, self.config, parse_cell("first_mover"))
        self.assertLess(fm, 0.5)
        h4 = start_estimate(self.agent, self.config, parse_cell("pip_headstart:4"))
        self.assertLess(h4, 0.5)
        self.assertIsNone(start_estimate(self.agent, self.config, parse_cell("rerolls:1")))


@unittest.skipUnless(GOLD.exists(), "gold_v11 checkpoint not present")
class TestCliSmoke(unittest.TestCase):
    def test_cli_two_games_per_cell(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "sweep.json"
            cmd = [sys.executable, "main.py", "--config", "config-test.yml", "handicap-sweep",
                   "--model", str(GOLD), "--games", "2", "--workers", "1", "--only", "first_mover",
                   "--combos", "weighted_dice:2+rerolls:1+first_mover:1,pip_headstart:2",
                   "--out", str(out)]
            subprocess.run(cmd, cwd=ROOT, check=True, capture_output=True, timeout=300)
            payload = json.loads(out.read_text())
            labels = [c["label"] for c in payload["cells"]]
            self.assertEqual(labels, ["baseline", "first_mover:1",
                                      "weighted_dice:2 + rerolls:1 + first_mover:1",
                                      "pip_headstart:2"])
            est = {c["label"]: c["net_estimate"] for c in payload["cells"]}
            self.assertEqual(est["baseline"], 0.5)
            self.assertIsNotNone(est["pip_headstart:2"])
            self.assertIsNone(est["weighted_dice:2 + rerolls:1 + first_mover:1"])
            self.assertIn("net est. %", out.with_suffix(".md").read_text())


if __name__ == "__main__":
    unittest.main()
