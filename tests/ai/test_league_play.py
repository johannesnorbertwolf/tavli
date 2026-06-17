import unittest

import torch

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import ENCODER_VERSION_CURRENT
from ai.self_play_worker import play_one_game_record
from config.config_loader import ConfigLoader


def _make_agent(config):
    encoder = BoardEncoder(config, version=ENCODER_VERSION_CURRENT)
    evaluator = BoardEvaluator(encoder.input_size, hidden_sizes=[16, 8])
    evaluator.eval()
    return Agent(evaluator, encoder, bearoff=None)


class _StubOpponent:
    """Duck-typed opponent recording which colors it was asked to move."""

    def __init__(self, inner):
        self.inner = inner
        self.calls = []

    def get_best_move(self, board, possible_moves, color, lookahead_plies=1):
        self.calls.append(color)
        return self.inner.get_best_move(board, possible_moves, color,
                                        lookahead_plies=lookahead_plies)


class TestLeaguePlay(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = ConfigLoader("config-test.yml")
        torch.manual_seed(0)
        cls.agent = _make_agent(cls.config)

    def test_league_game_routes_one_side_to_opponent(self):
        stub = _StubOpponent(_make_agent(self.config))
        traj = play_one_game_record(self.agent, self.agent.board_encoder, self.config,
                                    epsilon=0.0, exploration_temperature=1.0,
                                    league_opponents=[stub], league_fraction=1.0)
        self.assertGreater(len(stub.calls), 0)
        self.assertEqual(len(set(stub.calls)), 1)  # opponent plays exactly one color
        self.assertEqual(len(traj["states"]), len(traj["movers"]) + 1)

    def test_no_league_when_fraction_zero(self):
        stub = _StubOpponent(_make_agent(self.config))
        play_one_game_record(self.agent, self.agent.board_encoder, self.config,
                             epsilon=0.0, exploration_temperature=1.0,
                             league_opponents=[stub], league_fraction=0.0)
        self.assertEqual(stub.calls, [])
