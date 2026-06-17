"""Seeded-start self-play (#83, E9): build a pool of high-residual pre-roll
positions and let self-play start a fraction of games from them.

Pure self-play funnels every game through the same opening distribution, so
the states where the net is least self-consistent (largest |V_search - V_net|
residual) are visited too rarely for TD to fix them. Starting games at those
states gives TD direct continuation data exactly there. Both sides still play
the current policy from the seed onward, so learned values keep their
on-policy meaning (unlike league play, which changes the value definition).

Build (offline, parallel):  python main.py seed-pool [--games N] [--top K]
Consume (during training):  selfplay_seeded_fraction > 0 in config.yml
"""

import random
import time
from multiprocessing import Pool

import numpy as np
import torch

from ai.checkpoint_io import load_agent_from_checkpoint
from ai.rollout_lab import mine_games
from domain.board import Board
from domain.constants import WHITE, BLACK


def board_to_arrays(board):
    """Flatten a Board into plain arrays for npz storage / IPC."""
    return (np.asarray(board.n, dtype=np.int16),
            np.asarray(board.color, dtype=np.int8),
            np.asarray(board.pinned, dtype=bool),
            int(board.borne_off[WHITE]),
            int(board.borne_off[BLACK]))


def board_from_arrays(n, color, pinned, bo_white, bo_black, config=None):
    """Inverse of board_to_arrays. The pool must be built and consumed with the
    same board dimensions (arrays are length board_size + 2)."""
    board = Board.initial(config)
    board.n = [int(x) for x in n]
    board.color = [int(x) for x in color]
    board.pinned = [bool(x) for x in pinned]
    board.borne_off = {WHITE: int(bo_white), BLACK: int(bo_black)}
    return board


class SeedPool:
    """Read-only pool of seed positions, loaded once per worker process.

    Sampling uses the global `random` module so it follows each worker's
    deterministic seeding."""

    def __init__(self, path):
        d = np.load(path)
        self.n = d["n"]
        self.color = d["color"]
        self.pinned = d["pinned"]
        self.bo_white = d["bo_white"]
        self.bo_black = d["bo_black"]
        self.mover_is_white = d["mover_is_white"]

    def __len__(self):
        return len(self.mover_is_white)

    def sample(self, config):
        """Return (board, mover_color) for a uniformly sampled seed position."""
        i = random.randrange(len(self))
        board = board_from_arrays(self.n[i], self.color[i], self.pinned[i],
                                  self.bo_white[i], self.bo_black[i], config)
        mover = WHITE if self.mover_is_white[i] else BLACK
        return board, mover


def _worker_mine_seeds(args):
    """Pool worker: mine a share of games and return seed candidates as flat
    arrays (no Board objects cross the process boundary)."""
    worker_id, checkpoint_path, config_path, num_games, sample_every, base_seed = args
    torch.set_num_threads(1)
    from config.config_loader import ConfigLoader
    config = ConfigLoader(config_path)
    agent, _ = load_agent_from_checkpoint(checkpoint_path, config)

    seed = (base_seed + worker_id * 9176 + 29) & 0xFFFFFFFF
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)

    t0 = time.perf_counter()
    mined = mine_games(agent, config, num_games, sample_every, rng)
    ns, colors, pinneds, bo_ws, bo_bs, movers, residuals = [], [], [], [], [], [], []
    for p in mined:
        n, c, pin, bo_w, bo_b = board_to_arrays(p.board)
        ns.append(n)
        colors.append(c)
        pinneds.append(pin)
        bo_ws.append(bo_w)
        bo_bs.append(bo_b)
        movers.append(p.mover_color == WHITE)
        residuals.append(p.residual)
    return {
        "n": np.stack(ns),
        "color": np.stack(colors),
        "pinned": np.stack(pinneds),
        "bo_white": np.array(bo_ws, dtype=np.int16),
        "bo_black": np.array(bo_bs, dtype=np.int16),
        "mover_is_white": np.array(movers, dtype=bool),
        "residuals": np.array(residuals, dtype=np.float32),
        "seconds": time.perf_counter() - t0,
    }


def build_seed_pool(config, config_path, checkpoint_path="trained_model.pth",
                    out_path="models/seed_pool.npz", num_games=600, sample_every=2,
                    top_k=8000, num_workers=6, base_seed=None):
    """Mine self-play games in parallel and save the top_k highest-residual
    pre-roll positions as the seed pool."""
    if base_seed is None:
        base_seed = random.randrange(2**31)
    games_per_worker = [num_games // num_workers] * num_workers
    for i in range(num_games % num_workers):
        games_per_worker[i] += 1
    args = [(w, checkpoint_path, config_path, games_per_worker[w], sample_every, base_seed)
            for w in range(num_workers) if games_per_worker[w] > 0]

    t0 = time.perf_counter()
    with Pool(processes=len(args)) as pool:
        results = pool.map(_worker_mine_seeds, args)

    merged = {k: np.concatenate([r[k] for r in results])
              for k in ("n", "color", "pinned", "bo_white", "bo_black",
                        "mover_is_white", "residuals")}
    order = np.argsort(merged["residuals"])[::-1][:top_k]
    kept = {k: merged[k][order] for k in merged}
    np.savez_compressed(out_path, **kept)

    res = kept["residuals"]
    print(f"Seed pool: mined {len(merged['residuals'])} positions from {num_games} games "
          f"in {time.perf_counter() - t0:.0f}s, kept top {len(res)} by residual "
          f"(min {res.min():.4f}, median {np.median(res):.4f}, max {res.max():.4f})")
    print(f"Saved to {out_path}")
