"""Draw-safe terminal detection (#137 follow-up): search leaves and self-play end the
game via `ruleset.is_over` / `outcome`, never `board.has_won(mover)` alone.

Standard Plakoto positions where White's every legal move with (1, 3) pins Black's
mother (a lone checker on slot 24, Black's start):
  * DRAW   — White's own mother is already pinned on slot 1 -> both mothers pinned.
  * MOTHER — White has no checker on slot 1 -> White wins 2 points.
"""

import random
import unittest
from pathlib import Path
from unittest import mock

import numpy as np
import torch

from ai.agent import Agent
from ai.board_evaluator import BoardEvaluator
from ai.self_play_worker import play_one_game_record
from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.plakoto_standard_board import StandardPlakotoBoard

ROOT = Path(__file__).resolve().parents[2]
CONFIG = str(ROOT / "config" / "config-plakoto-standard.yml")


def draw_position(config):
    b = StandardPlakotoBoard.from_config(config)
    b.set_point(1, BLACK, 1, pinned=True)   # White's mother pinned by Black
    b.set_point(23, WHITE, 14)
    b.set_point(24, BLACK, 1)               # Black's mother, a lone blot
    b.set_point(10, BLACK, 13)
    return b


def mother_win_position(config):
    b = StandardPlakotoBoard.from_config(config)
    b.set_point(20, WHITE, 1)
    b.set_point(23, WHITE, 14)
    b.set_point(24, BLACK, 1)
    b.set_point(10, BLACK, 14)
    return b


class _Constant(torch.nn.Module):
    """Evaluator stub: every non-terminal position is worth `v` to the side to move."""

    def __init__(self, v):
        super().__init__()
        self.v = v
        self.dummy = torch.nn.Parameter(torch.zeros(1))

    def forward(self, x):
        return torch.full((x.shape[0], 1), self.v)


class _OnePosition:
    """Seed-pool stand-in: every game starts from `board` with `player` to move."""

    def __init__(self, board, player):
        self.board, self.player = board, player

    def sample(self, _config):
        return self.board.clone(), self.player


def _roll_1_3(self, rng=None):
    self.set(1, 3)
    return (self.die1, self.die2)


class TestStandardPlakotoTerminals(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader(CONFIG)
        cls.rules = cls.config.get_ruleset()
        enc = cls.rules.make_encoder(cls.config)
        cls.agent = Agent(BoardEvaluator(enc.input_size, hidden_sizes=[8]), enc,
                          ruleset=cls.rules)
        cls.encoder = enc
        cls.dice = Dice()
        cls.dice.set(1, 3)

    def _check(self, board, want_value, want_outcome):
        moves = self.rules.legal_moves(board, WHITE, self.dice)
        self.assertTrue(moves)
        for m in moves:
            t = board.apply(m, WHITE)
            self.assertTrue(self.rules.is_over(board), m)
            self.assertEqual(self.rules.outcome(board), want_outcome, m)
            board.undo(t)
        for plies in (1, 2):
            scores = self.agent.evaluate_moves(board, moves, WHITE, lookahead_plies=plies)
            self.assertEqual(scores, [want_value] * len(moves), plies)
        nply = self.agent._evaluate_moves_nply(board, moves, WHITE, 3, 0.08)
        self.assertEqual(nply, [want_value] * len(moves))

        # Self-play from this position stops right after White's move.
        random.seed(0); np.random.seed(0)
        with mock.patch.object(Dice, "roll", _roll_1_3):
            traj = play_one_game_record(self.agent, self.encoder, self.config, 0.0, 1.0,
                                        seed_pool=_OnePosition(board, WHITE), seeded_fraction=1.0)
        self.assertEqual(traj["plies"], 1)
        self.assertEqual(traj["terminal_value_white"], want_value)

    def test_draw_leaf_is_half(self):
        b = draw_position(self.config)
        self.assertFalse(self.rules.is_over(b))
        self._check(b, 0.5, (None, 0))

    def test_mother_win_leaf_is_one(self):
        b = mother_win_position(self.config)
        self.assertFalse(self.rules.is_over(b))
        self._check(b, 1.0, (WHITE, 2))

    def test_opponent_draw_reply_is_fixed_leaf(self):
        """2-ply: a Black reply that draws is a fixed 0.5 leaf for White (not the net's
        value of the drawn position, and not a loss)."""
        b = StandardPlakotoBoard.from_config(self.config)
        b.set_point(24, WHITE, 1, pinned=True)   # Black's mother pinned by White
        b.set_point(1, WHITE, 1)                 # White's mother: a lone checker on 1
        b.set_point(12, WHITE, 13)
        b.set_point(3, BLACK, 14)                # Black pins slot 1 with a 2 (or 1-1)
        self.assertFalse(self.rules.is_over(b))
        agent = Agent(_Constant(0.9), self.encoder, ruleset=self.rules)
        moves = self.rules.legal_moves(b, WHITE, self.dice)
        scores = agent.evaluate_moves(b, moves, WHITE, lookahead_plies=2)
        drawable = 12.0 / 36.0                   # Black rolls a 2, or 1-1
        for m, s in zip(moves, scores):
            t = b.apply(m, WHITE)
            mother_home = b.checkers_on_start(WHITE) > 0
            b.undo(t)
            if mother_home:
                self.assertAlmostEqual(s, drawable * 0.5 + (1 - drawable) * 0.9, places=5, msg=m)
            else:                                # vacating the start wins on the spot
                self.assertEqual(s, 1.0, m)
        self.assertTrue(any(s < 1.0 for s in scores))


if __name__ == "__main__":
    unittest.main()
