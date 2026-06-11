import os
import tempfile
import unittest

import numpy as np
import torch

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import ENCODER_VERSION_CURRENT
from ai.seed_pool import SeedPool, board_from_arrays, board_to_arrays
from ai.self_play_worker import play_one_game_record
from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK


def _make_agent(config):
    encoder = BoardEncoder(config, version=ENCODER_VERSION_CURRENT)
    evaluator = BoardEvaluator(encoder.input_size, hidden_sizes=[16, 8])
    evaluator.eval()
    return Agent(evaluator, encoder, bearoff=None)


def _midgame_board_with_pin(config):
    board = Board.initial(config)
    # White: 13 at slot 1, 1 at slot 5 pinning a black checker, 1 borne off.
    # Black: 14 at the start point, 1 pinned at slot 5.
    board.n[1] = 13
    board.n[5] = 1
    board.color[5] = WHITE
    board.pinned[5] = True
    board.n[board.board_size] = 14
    board.borne_off[WHITE] = 1
    return board


def _save_pool(path, boards_with_movers):
    ns, colors, pinneds, bo_ws, bo_bs, movers = [], [], [], [], [], []
    for board, mover in boards_with_movers:
        n, c, pin, bo_w, bo_b = board_to_arrays(board)
        ns.append(n)
        colors.append(c)
        pinneds.append(pin)
        bo_ws.append(bo_w)
        bo_bs.append(bo_b)
        movers.append(mover == WHITE)
    np.savez_compressed(
        path,
        n=np.stack(ns), color=np.stack(colors), pinned=np.stack(pinneds),
        bo_white=np.array(bo_ws, dtype=np.int16), bo_black=np.array(bo_bs, dtype=np.int16),
        mover_is_white=np.array(movers, dtype=bool),
        residuals=np.zeros(len(ns), dtype=np.float32),
    )


class TestSeedPool(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader("config-test.yml")
        torch.manual_seed(0)
        cls.agent = _make_agent(cls.config)

    def test_board_arrays_round_trip(self):
        board = _midgame_board_with_pin(self.config)
        restored = board_from_arrays(*board_to_arrays(board), config=self.config)
        self.assertEqual(restored.n, board.n)
        self.assertEqual(restored.color, board.color)
        self.assertEqual(restored.pinned, board.pinned)
        self.assertEqual(restored.borne_off, board.borne_off)
        self.assertEqual(restored.board_size, board.board_size)

    def test_seed_pool_load_and_sample(self):
        board = _midgame_board_with_pin(self.config)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "pool.npz")
            _save_pool(path, [(board, BLACK)])
            pool = SeedPool(path)
            self.assertEqual(len(pool), 1)
            sampled, mover = pool.sample(self.config)
            self.assertEqual(mover, BLACK)
            self.assertEqual(sampled.n, board.n)
            self.assertEqual(sampled.pinned, board.pinned)
            self.assertEqual(sampled.borne_off, board.borne_off)

    def test_seeded_game_starts_from_seed_and_finishes(self):
        # Near-terminal seed: one checker each, 14 borne off per side.
        board = Board.initial(self.config)
        board.n[board.board_size] = 1
        board.color[board.board_size] = WHITE
        board.n[1] = 1
        board.color[1] = BLACK
        board.borne_off = {WHITE: 14, BLACK: 14}
        encoder = self.agent.board_encoder
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "pool.npz")
            _save_pool(path, [(board, WHITE)])
            pool = SeedPool(path)
            traj = play_one_game_record(self.agent, encoder, self.config,
                                        epsilon=0.0, exploration_temperature=1.0,
                                        seed_pool=pool, seeded_fraction=1.0)
        expected_first = encoder.encode_board(board, True)
        np.testing.assert_array_equal(traj["states"][0], expected_first)
        self.assertEqual(len(traj["states"]), len(traj["movers"]) + 1)
        self.assertLess(traj["plies"], 40)  # near-terminal seed, not a full ~55-ply game
        self.assertIsInstance(traj["terminal_winner_white"], bool)

    def test_unseeded_game_starts_from_initial_position(self):
        encoder = self.agent.board_encoder
        board = _midgame_board_with_pin(self.config)
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "pool.npz")
            _save_pool(path, [(board, WHITE)])
            pool = SeedPool(path)
            traj = play_one_game_record(self.agent, encoder, self.config,
                                        epsilon=0.0, exploration_temperature=1.0,
                                        seed_pool=pool, seeded_fraction=0.0)
        # Game starts Black-to-move from the initial position by convention.
        expected_first = encoder.encode_board(Board.initial(self.config), False)
        np.testing.assert_array_equal(traj["states"][0], expected_first)
