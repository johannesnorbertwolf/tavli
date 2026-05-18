"""Worker process for parallel self-play.

Each worker holds a frozen copy of the live network and plays a complete
self-play game to a real terminal. The trainer consumes the trajectory and
runs TD(λ) updates against its live weights.

Workers play with weights that may be a few games stale (off-policy by a small
margin), which is fine for TD-Gammon-style self-play."""

import time
import random

import numpy as np
import torch

from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import ENCODER_VERSION_CURRENT
from config.config_loader import ConfigLoader
from domain.constants import WHITE
from domain.move_generation import legal_moves
from game.game import Game


def _select_self_play_move(agent, board, possible_moves, current_player, epsilon, exploration_temperature):
    if len(possible_moves) == 1:
        return possible_moves[0]
    scores = agent.evaluate_moves(board, possible_moves, current_player)
    best_idx = int(np.argmax(scores))
    if np.random.random() >= epsilon:
        return possible_moves[best_idx]
    s = np.array(scores, dtype=np.float64) / max(exploration_temperature, 1e-6)
    s -= np.max(s)
    probs = np.exp(s) / np.sum(np.exp(s))
    return possible_moves[int(np.random.choice(len(possible_moves), p=probs))]


def play_one_game_record(agent, encoder, config, epsilon, exploration_temperature):
    """Play one self-play game to a real terminal. Returns a trajectory dict:
    - `states`: encoded board snapshots, length T+1.
    - `movers`: is-white-to-move at each ply, length T.
    - `terminal_winner_white`: True if White won.
    """
    t0 = time.perf_counter()
    game = Game(config)

    states = [encoder.encode_board(game.board, game.current_player == WHITE)]
    movers = []

    while True:
        current_player = game.current_player
        is_white_to_move = current_player == WHITE

        game.dice.roll()
        possible_moves = legal_moves(game.board, current_player, game.dice)
        if not possible_moves:
            game.switch_turn()
        else:
            move = _select_self_play_move(agent, game.board, possible_moves, current_player,
                                          epsilon, exploration_temperature)
            token = game.board.apply(move, current_player)
            game.switch_turn()
        movers.append(is_white_to_move)
        states.append(encoder.encode_board(game.board, game.current_player == WHITE))

        if game.is_over():
            return {
                "states": states,
                "movers": movers,
                "terminal_winner_white": (game.get_winner() == WHITE),
                "plies": len(movers),
                "game_seconds": time.perf_counter() - t0,
            }


def worker_main(worker_id, weight_q, traj_q, config_path, hidden_sizes, base_seed):
    """Worker process entry point. Reads (weights, epsilon, exploration_temperature)
    tuples from weight_q, plays one game per message, and pushes (worker_id, trajectory)
    to traj_q. Stops on a None message."""
    torch.set_num_threads(1)
    config = ConfigLoader(config_path)
    encoder = BoardEncoder(config, version=ENCODER_VERSION_CURRENT)
    evaluator = BoardEvaluator(encoder.input_size, hidden_sizes=list(hidden_sizes))
    evaluator.eval()
    agent = Agent(evaluator, encoder)

    seed = (base_seed + worker_id * 9176 + 7) & 0xFFFFFFFF
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)

    while True:
        msg = weight_q.get()
        if msg is None:
            return
        weights, epsilon, exploration_temperature = msg
        evaluator.load_state_dict({k: torch.from_numpy(v) for k, v in weights.items()})
        traj = play_one_game_record(agent, encoder, config, epsilon, exploration_temperature)
        traj_q.put((worker_id, traj))
