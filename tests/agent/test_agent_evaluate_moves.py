import unittest
import torch
from pathlib import Path

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice, Die
from domain.move_generation import legal_moves


class DummyEvaluator(torch.nn.Module):
    def __init__(self, target_encoding, target_value=0.0, default_value=0.5):
        super().__init__()
        self.register_buffer("target_encoding", torch.from_numpy(target_encoding).float().unsqueeze(0))
        self._device_anchor = torch.nn.Parameter(torch.zeros(1), requires_grad=False)
        self.target_value = float(target_value)
        self.default_value = float(default_value)

    def forward(self, x):
        out = torch.full((x.shape[0], 1), self.default_value, dtype=x.dtype, device=x.device)
        target = self.target_encoding[0]
        for row in range(x.shape[0]):
            if torch.allclose(x[row], target):
                out[row, 0] = self.target_value
        return out


class ConstantEvaluator(torch.nn.Module):
    def __init__(self, value=0.3):
        super().__init__()
        self._device_anchor = torch.nn.Parameter(torch.zeros(1), requires_grad=False)
        self.value = float(value)

    def forward(self, x):
        return torch.full((x.shape[0], 1), self.value, dtype=x.dtype, device=x.device)


class TestAgentEvaluateMoves(unittest.TestCase):
    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))
        self.board = Board.from_config(self.config)
        self.encoder = BoardEncoder(self.config)

    def test_winning_capture_move_scores_highest(self):
        # White at 23, black singleton at 24 (white can pin/capture to win), plus another legal move.
        self.board.set_point(23, WHITE, 1)
        self.board.set_point(24, BLACK, 1)
        self.board.set_point(5, WHITE, 2)

        dice = Dice(self.config.get_die_sides())
        dice.set(1, 2)

        possible_moves = legal_moves(self.board, WHITE, dice)

        winning_move = None
        winning_encoded = None
        for move in possible_moves:
            token = self.board.apply(move, WHITE)
            if self.board.has_won(WHITE):
                winning_move = move
                winning_encoded = self.encoder.encode_board(self.board, is_whites_turn=False)
                self.board.undo(token)
                break
            self.board.undo(token)

        self.assertIsNotNone(winning_move, "Expected at least one winning move")

        dummy_eval = DummyEvaluator(winning_encoded, target_value=0.0, default_value=0.5)
        agent = Agent(dummy_eval, self.encoder)

        scores = agent.evaluate_moves(self.board, possible_moves, WHITE)

        winning_index = possible_moves.index(winning_move)
        self.assertEqual(scores[winning_index], max(scores))
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)

    def _setup_white_bears_off_last_piece(self):
        """14 white pieces borne off, 1 white at slot 23. White rolls (2, _) to win."""
        board_size = self.config.get_board_size()
        self.board.set_point(board_size + 1, WHITE, 14)
        self.board.borne_off[WHITE] = 14
        self.board.set_point(23, WHITE, 1)
        self.board.set_point(1, BLACK, 5)

        dice = Dice(self.config.get_die_sides())
        dice.set(2, 5)
        possible_moves = legal_moves(self.board, WHITE, dice)

        winning_index = None
        for idx, move in enumerate(possible_moves):
            token = self.board.apply(move, WHITE)
            if self.board.has_won(WHITE):
                winning_index = idx
                self.board.undo(token)
                break
            self.board.undo(token)
        self.assertIsNotNone(winning_index, "Expected at least one winning bear-off move")
        return possible_moves, winning_index

    def test_bear_off_last_piece_scores_1_at_1ply(self):
        possible_moves, winning_index = self._setup_white_bears_off_last_piece()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        scores = agent.evaluate_moves(self.board, possible_moves, WHITE, lookahead_plies=1)
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)

    def test_bear_off_last_piece_scores_1_at_2ply(self):
        possible_moves, winning_index = self._setup_white_bears_off_last_piece()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        scores = agent.evaluate_moves(self.board, possible_moves, WHITE, lookahead_plies=2)
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)


class PositionDependentEvaluator(torch.nn.Module):
    """Deterministic value in (0,1) that varies with the encoding — a constant evaluator
    would mask perspective/tempo bugs, since every leaf would score the same."""

    def __init__(self, input_size):
        super().__init__()
        gen = torch.Generator().manual_seed(42)
        w = (torch.rand((input_size, 1), generator=gen) - 0.5) * 0.2
        self.register_buffer("w", w)
        self._device_anchor = torch.nn.Parameter(torch.zeros(1), requires_grad=False)

    def forward(self, x):
        return torch.sigmoid(x @ self.w)


class Test2PlyMatchesNPlyDepth2(unittest.TestCase):
    """Regression for the 2-ply tempo bug: `_evaluate_moves_2ply_batch` must agree with
    `_evaluate_moves_nply(depth=2)` when pruning is disabled. The fixed-2ply path used to
    encode opponent-reply afterstates from the opponent's perspective (a tempo-shifted
    question, since after the reply it is the original player's turn) while the n-ply path
    encoded them from the to-move player's perspective."""

    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))
        self.encoder = BoardEncoder(self.config)
        self.agent = Agent(PositionDependentEvaluator(self.encoder.input_size), self.encoder)

    def _assert_paths_agree(self, board, color, d1, d2):
        dice = Dice(self.config.get_die_sides())
        dice.set(d1, d2)
        moves = legal_moves(board, color, dice)
        self.assertGreater(len(moves), 1)

        scores_2ply = self.agent._evaluate_moves_2ply_batch(board, moves, color)
        # Pruning disabled: absolute beam wider than the score range, no cutoff, no cap.
        scores_nply = self.agent._evaluate_moves_nply(
            board, moves, color, depth=2,
            beam_threshold=10.0, relative_cutoff=None, max_branch=None,
        )

        self.assertEqual(len(scores_2ply), len(scores_nply))
        for s2, sn in zip(scores_2ply, scores_nply):
            self.assertAlmostEqual(s2, sn, places=5)

    def test_midgame_white(self):
        board = Board.from_config(self.config)
        board.set_point(5, WHITE, 2)
        board.set_point(10, WHITE, 1)
        board.set_point(15, WHITE, 1)
        board.set_point(8, BLACK, 1)
        board.set_point(12, BLACK, 1)
        board.set_point(20, BLACK, 2)
        self._assert_paths_agree(board, WHITE, 2, 4)

    def test_midgame_black(self):
        board = Board.from_config(self.config)
        board.set_point(5, WHITE, 2)
        board.set_point(10, WHITE, 1)
        board.set_point(15, WHITE, 1)
        board.set_point(8, BLACK, 1)
        board.set_point(12, BLACK, 1)
        board.set_point(20, BLACK, 2)
        self._assert_paths_agree(board, BLACK, 6, 3)

    def test_race_with_opponent_winning_replies(self):
        # Black can bear off their last piece on many replies, exercising the
        # opponent-win short-circuit in both paths.
        board = Board.from_config(self.config)
        board_size = self.config.get_board_size()
        board.set_point(board_size + 1, WHITE, 13)
        board.borne_off[WHITE] = 13
        board.set_point(20, WHITE, 1)
        board.set_point(23, WHITE, 1)
        board.set_point(0, BLACK, 14)
        board.borne_off[BLACK] = 14
        board.set_point(3, BLACK, 1)
        self._assert_paths_agree(board, WHITE, 2, 5)


class TestAgentNPly(unittest.TestCase):
    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))
        self.board = Board.from_config(self.config)
        self.encoder = BoardEncoder(self.config)

    def _setup_bear_off(self):
        """14 white pieces borne off, 1 white at slot 23. White rolls (2, 5)."""
        board_size = self.config.get_board_size()
        self.board.set_point(board_size + 1, WHITE, 14)
        self.board.borne_off[WHITE] = 14
        self.board.set_point(23, WHITE, 1)
        self.board.set_point(1, BLACK, 5)
        dice = Dice(self.config.get_die_sides())
        dice.set(2, 5)
        possible_moves = legal_moves(self.board, WHITE, dice)
        winning_index = None
        for idx, move in enumerate(possible_moves):
            token = self.board.apply(move, WHITE)
            if self.board.has_won(WHITE):
                winning_index = idx
                self.board.undo(token)
                break
            self.board.undo(token)
        self.assertIsNotNone(winning_index)
        return possible_moves, winning_index

    def _make_agent(self, value=0.3):
        return Agent(ConstantEvaluator(value=value), self.encoder)

    def test_nply_depth1_matches_batch(self):
        possible_moves, _ = self._setup_bear_off()
        agent = self._make_agent()
        batch_scores = agent._evaluate_moves_batch(self.board, possible_moves, WHITE)
        nply_scores = agent._evaluate_moves_nply(self.board, possible_moves, WHITE, depth=1, beam_threshold=0.08)
        self.assertEqual(len(batch_scores), len(nply_scores))
        for a, b in zip(batch_scores, nply_scores):
            self.assertAlmostEqual(a, b, places=6)

    def test_nply_win_scores_1_at_depth2(self):
        possible_moves, winning_index = self._setup_bear_off()
        agent = self._make_agent()
        scores = agent._evaluate_moves_nply(self.board, possible_moves, WHITE, depth=2, beam_threshold=0.08)
        self.assertAlmostEqual(scores[winning_index], 1.0, places=6)

    def test_single_move_fast_path(self):
        possible_moves, _ = self._setup_bear_off()
        single_move = [possible_moves[0]]
        agent = self._make_agent()
        move, score = agent.get_best_move(self.board, single_move, WHITE, time_budget_s=5.0)
        self.assertEqual(move, single_move[0])

    def test_iterative_deepening_expired_deadline_returns_depth1(self):
        possible_moves, _ = self._setup_bear_off()
        agent = self._make_agent()
        # Negative budget expires immediately; must equal depth-1 result
        move_timed, _ = agent.get_best_move(self.board, possible_moves, WHITE, time_budget_s=-1.0)
        move_fixed, _ = agent.get_best_move(self.board, possible_moves, WHITE, lookahead_plies=1)
        self.assertEqual(move_timed, move_fixed)

    def test_board_not_corrupted_after_timeout(self):
        possible_moves, _ = self._setup_bear_off()
        agent = self._make_agent()
        board_repr_before = repr(self.board)
        # Very short budget to trigger timeout inside recursion
        agent.get_best_move(self.board, possible_moves, WHITE, time_budget_s=0.00001, beam_threshold=0.08)
        self.assertEqual(repr(self.board), board_repr_before)


class TestPruneBranches(unittest.TestCase):
    def test_relative_cutoff_keeps_moves_within_fraction(self):
        moves = ["a", "b", "c", "d"]
        scores = [1.0, 0.95, 0.9, 0.5]
        # rel 0.10 -> keep >= 0.90 -> a,b,c (best-first), no cap
        idx = Agent._prune_branches(moves, scores, beam_threshold=0.08, relative_cutoff=0.10, max_branch=None)
        self.assertEqual(idx, [0, 1, 2])

    def test_max_branch_caps_after_cutoff(self):
        moves = ["a", "b", "c", "d"]
        scores = [1.0, 0.95, 0.9, 0.89]
        # rel 0.20 -> keep >= 0.80 -> all four, but cap to top 2 by score
        idx = Agent._prune_branches(moves, scores, beam_threshold=0.08, relative_cutoff=0.20, max_branch=2)
        self.assertEqual(idx, [0, 1])

    def test_always_keeps_at_least_one(self):
        idx = Agent._prune_branches(["a", "b"], [0.4, 0.1], beam_threshold=0.0, relative_cutoff=0.0, max_branch=6)
        self.assertEqual(idx, [0])

    def test_falls_back_to_beam_when_relative_cutoff_none(self):
        moves = ["a", "b", "c"]
        scores = [1.0, 0.95, 0.5]
        # absolute beam 0.08 -> keep >= 0.92 -> a,b
        idx = Agent._prune_branches(moves, scores, beam_threshold=0.08, relative_cutoff=None, max_branch=None)
        self.assertEqual(idx, [0, 1])


class TestLastSearchDepth(unittest.TestCase):
    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        self.config = ConfigLoader(str(config_path))
        self.board = Board.from_config(self.config)
        self.encoder = BoardEncoder(self.config)

    def _setup_multi_move(self):
        """A position with several legal white moves (so the single-move fast path is avoided)."""
        for p in range(0, self.config.get_board_size() + 2):
            self.board.set_point(p, WHITE, 0)
            self.board.set_point(p, BLACK, 0)
        self.board.set_point(5, WHITE, 1)
        self.board.set_point(10, WHITE, 1)
        self.board.set_point(20, BLACK, 2)
        dice = Dice(self.config.get_die_sides())
        dice.set(2, 4)
        moves = legal_moves(self.board, WHITE, dice)
        self.assertGreater(len(moves), 1)
        return moves

    def test_fixed_path_records_depth(self):
        moves = self._setup_multi_move()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        agent.get_best_move(self.board, moves, WHITE, lookahead_plies=1)
        self.assertEqual(agent.last_search_depth, 1)
        agent.get_best_move(self.board, moves, WHITE, lookahead_plies=2)
        self.assertEqual(agent.last_search_depth, 2)

    def test_time_budget_path_records_depth_at_least_2(self):
        moves = self._setup_multi_move()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        agent.get_best_move(self.board, moves, WHITE, time_budget_s=5.0, relative_cutoff=0.10, max_branch=6)
        self.assertGreaterEqual(agent.last_search_depth, 2)

    def test_max_depth_caps_deepening(self):
        moves = self._setup_multi_move()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        # Generous budget but max_depth=3 must stop the search at depth 3.
        agent.get_best_move(
            self.board, moves, WHITE, time_budget_s=10.0,
            relative_cutoff=0.08, max_branch=5, max_depth=3,
        )
        self.assertEqual(agent.last_search_depth, 3)

    def test_expired_budget_records_depth_1(self):
        moves = self._setup_multi_move()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        agent.get_best_move(self.board, moves, WHITE, time_budget_s=-1.0)
        self.assertEqual(agent.last_search_depth, 1)

    def test_board_restored_when_timeout_fires_deep_in_recursion(self):
        """Regression: a _TimeoutError raised inside a nested depth-2 frame must still
        undo every applied move as it unwinds (try/finally), leaving the board pristine."""
        import ai.agent as agent_module
        moves = self._setup_multi_move()
        agent = Agent(ConstantEvaluator(value=0.3), self.encoder)
        board_repr_before = repr(self.board)

        # Fake clock: first deadline check passes (in the outer depth-3 frame, after it
        # has applied a move and recursed), the second check (in the depth-2 frame, after
        # it too has applied a move) trips the deadline.
        calls = {"n": 0}
        real_monotonic = agent_module.time.monotonic

        def fake_monotonic():
            calls["n"] += 1
            return 0.0 if calls["n"] <= 1 else 100.0

        agent_module.time.monotonic = fake_monotonic
        try:
            with self.assertRaises(agent_module._TimeoutError):
                agent._evaluate_moves_nply(
                    self.board, moves, WHITE, depth=3, beam_threshold=0.08,
                    deadline=1.0, relative_cutoff=0.08, max_branch=5,
                )
        finally:
            agent_module.time.monotonic = real_monotonic

        self.assertEqual(repr(self.board), board_repr_before)


if __name__ == "__main__":
    unittest.main()
