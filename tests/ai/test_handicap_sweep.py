"""Handicap harness (#148): no-handicap equivalence, determinism, pairing, stats."""

import unittest
from pathlib import Path

from ai.checkpoint_io import load_agent_from_checkpoint
from ai.handicap_sweep import (
    cell_label, default_cells, parse_cell, play_game, play_pair, rules_for,
    summarize_cell, to_markdown,
)
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


if __name__ == "__main__":
    unittest.main()
