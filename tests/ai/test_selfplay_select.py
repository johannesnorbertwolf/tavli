import unittest

import numpy as np

from ai.self_play_worker import select_self_play_move


class _StubAgent:
    """Duck-typed agent: returns canned scores per (lookahead_plies, #moves)
    and records every evaluate_moves call."""

    def __init__(self, scores_1ply, scores_2ply=None):
        self.scores_1ply = scores_1ply
        self.scores_2ply = scores_2ply
        self.calls = []

    def evaluate_moves(self, board, possible_moves, color, lookahead_plies=1):
        self.calls.append((lookahead_plies, list(possible_moves)))
        if lookahead_plies >= 2:
            return [self.scores_2ply[m] for m in possible_moves]
        return [self.scores_1ply[m] for m in possible_moves]


class TestSelectSelfPlayMove(unittest.TestCase):
    def setUp(self):
        np.random.seed(0)

    def test_single_move_short_circuits(self):
        agent = _StubAgent({"a": 0.5})
        move = select_self_play_move(agent, None, ["a"], 1, epsilon=0.0,
                                     exploration_temperature=1.0)
        self.assertEqual(move, "a")
        self.assertEqual(agent.calls, [])

    def test_no_escalation_when_margin_zero(self):
        agent = _StubAgent({"a": 0.60, "b": 0.59, "c": 0.10})
        move = select_self_play_move(agent, None, ["a", "b", "c"], 1, epsilon=0.0,
                                     exploration_temperature=1.0, twoply_margin=0.0)
        self.assertEqual(move, "a")
        self.assertEqual(len(agent.calls), 1)
        self.assertEqual(agent.calls[0][0], 1)

    def test_no_escalation_when_decision_clear(self):
        # Runner-up is 0.2 below best: outside the 0.05 margin.
        agent = _StubAgent({"a": 0.70, "b": 0.50, "c": 0.10},
                           scores_2ply={"a": 0.0, "b": 1.0, "c": 1.0})
        move = select_self_play_move(agent, None, ["a", "b", "c"], 1, epsilon=0.0,
                                     exploration_temperature=1.0, twoply_margin=0.05)
        self.assertEqual(move, "a")
        self.assertEqual(len(agent.calls), 1)

    def test_escalation_lets_2ply_overrule_1ply(self):
        # a and b are within the margin; 2-ply prefers b.
        agent = _StubAgent({"a": 0.60, "b": 0.58, "c": 0.10},
                           scores_2ply={"a": 0.55, "b": 0.65})
        move = select_self_play_move(agent, None, ["a", "b", "c"], 1, epsilon=0.0,
                                     exploration_temperature=1.0, twoply_margin=0.05)
        self.assertEqual(move, "b")
        self.assertEqual(len(agent.calls), 2)
        deep_plies, deep_moves = agent.calls[1]
        self.assertEqual(deep_plies, 2)
        self.assertEqual(set(deep_moves), {"a", "b"})  # c not re-scored

    def test_escalation_caps_candidates(self):
        scores = {m: 0.60 - 0.001 * i for i, m in enumerate("abcdefg")}
        agent = _StubAgent(scores, scores_2ply={m: 0.5 for m in "abcdefg"})
        select_self_play_move(agent, None, list("abcdefg"), 1, epsilon=0.0,
                              exploration_temperature=1.0, twoply_margin=0.05,
                              twoply_max_moves=3)
        self.assertEqual(len(agent.calls[1][1]), 3)

    def test_exploration_stays_on_1ply(self):
        # epsilon=1 → always softmax over 1-ply scores; 2-ply never consulted.
        agent = _StubAgent({"a": 0.60, "b": 0.59},
                           scores_2ply={"a": 0.0, "b": 0.0})
        move = select_self_play_move(agent, None, ["a", "b"], 1, epsilon=1.0,
                                     exploration_temperature=1.0, twoply_margin=0.05)
        self.assertIn(move, ("a", "b"))
        self.assertEqual(len(agent.calls), 1)


if __name__ == "__main__":
    unittest.main()
