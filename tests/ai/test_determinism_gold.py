"""Determinism regression for the RuleSet seam (#136).

Expected values were computed on origin/main *before* the refactor (commit
342f219) with the exact same code below; the refactor must reproduce them
bit-for-bit: same 1-ply move choices from gold_v11 and the same seeded
greedy self-play game (move sequence hash, length, winner)."""

import hashlib
import random
import unittest
from pathlib import Path

from ai.checkpoint_io import load_agent_from_checkpoint
from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from game.game import Game

ROOT = Path(__file__).resolve().parents[2]
GOLD = ROOT / "models" / "gold_v11.pth"

EXPECTED_OPENINGS = {
    (6, 5): ("(1->7, 1->6)", 0.52343),
    (3, 1): ("(1->4, 1->2)", 0.51291),
    (4, 4): ("(1->5, 1->5, 5->9, 9->13)", 0.55786),
    (2, 6): ("(1->3, 1->7)", 0.52436),
}
EXPECTED_GAME = (114, WHITE, "4253bcc234b5996f869f1f6624f8c281d2f4b08c1feaea1ec24c74b97b9451af")


@unittest.skipUnless(GOLD.exists(), "gold_v11 checkpoint not present")
class TestGoldDeterminism(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader(str(ROOT / "config-test.yml"))  # no bear-off DB
        cls.agent, _ = load_agent_from_checkpoint(str(GOLD), cls.config)

    def test_opening_move_choices(self):
        game = Game(self.config)
        dice = Dice(6)
        for (d1, d2), (exp_move, exp_score) in EXPECTED_OPENINGS.items():
            dice.set(d1, d2)
            moves = game.ruleset.legal_moves(game.board, WHITE, dice)
            move, score = self.agent.get_best_move(game.board, moves, WHITE, lookahead_plies=1)
            self.assertEqual(repr(move), exp_move, (d1, d2))
            self.assertAlmostEqual(score, exp_score, places=4)

    def test_seeded_greedy_game(self):
        random.seed(2024)
        game = Game(self.config)
        seq = []
        while not game.is_over():
            c = game.current_player
            game.dice.roll()
            moves = game.legal_moves()
            if moves:
                move, _ = self.agent.get_best_move(game.board, moves, c, lookahead_plies=1)
                seq.append(repr(move))
                game.board.apply(move, c)
            else:
                seq.append("pass")
            game.switch_turn()
        digest = hashlib.sha256("|".join(seq).encode()).hexdigest()
        self.assertEqual((len(seq), game.get_winner(), digest), EXPECTED_GAME)


if __name__ == "__main__":
    unittest.main()
