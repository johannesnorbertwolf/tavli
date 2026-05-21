"""Parallel validation harness: time-budget flexible search vs fixed 2-ply.

Plays gold_v9 against itself. Both arms use the *same* checkpoint weights — they differ
only in how moves are chosen:

- **flexible arm**: ``get_best_move(time_budget_s=…, relative_cutoff=…, max_branch=…)``
  (iterative-deepening beam expectimax, the search we want to validate).
- **2-ply arm**: ``get_best_move(lookahead_plies=2)`` (fixed-depth expectimax baseline).

We alternate which color is the flexible arm to remove first-move bias, count the flexible
arm's win rate, and report a Wilson 95% CI + binomial p-value vs 0.5. We also collect the
depth the flexible search actually reached on each of its moves (`agent.last_search_depth`)
and per-move wall times, so we can answer "how deep did it really look".

Parallelism uses ``multiprocessing`` spawn workers. The model is static, so unlike training
there is no weight queue: each worker loads the checkpoint once and plays a chunk of games.
"""

import math
import multiprocessing as mp
import time
from collections import Counter
from typing import List, Tuple

import numpy as np
import torch

from config.config_loader import ConfigLoader
from ai.checkpoint_io import load_agent_from_checkpoint
from game.game import Game
from domain.move_generation import legal_moves
from domain.constants import WHITE, BLACK


def _play_one_game(agent, config, flex_color: int, budget: float, rel: float, mb: int, md: int,
                   depth_hist: Counter, move_times: List[float]) -> int:
    """Play a single game; flex_color uses the flexible search, the other uses 2-ply.
    Returns the winner color. Mutates depth_hist / move_times with flexible-move stats."""
    game = Game(config, starting_player=WHITE)
    while not game.is_over():
        current = game.current_player
        game.dice.roll()
        moves = legal_moves(game.board, current, game.dice)
        if not moves:
            game.switch_turn()
            continue
        if current == flex_color:
            t = time.monotonic()
            move, _ = agent.get_best_move(
                game.board, moves, current,
                time_budget_s=budget, relative_cutoff=rel, max_branch=mb, max_depth=md,
            )
            move_times.append(time.monotonic() - t)
            depth_hist[agent.last_search_depth] += 1
        else:
            move, _ = agent.get_best_move(game.board, moves, current, lookahead_plies=2)
        game.board.apply(move, current)
        game.switch_turn()
    return game.get_winner()


def _worker(args) -> Tuple[int, int, dict, List[float]]:
    """Run a chunk of games in a subprocess. ``tasks`` is a list of (flex_color, seed)."""
    model_path, config_path, tasks, budget, rel, mb, md = args
    torch.set_num_threads(1)
    config = ConfigLoader(config_path)
    agent, _ = load_agent_from_checkpoint(model_path, config, device=torch.device("cpu"))

    flex_wins = 0
    depth_hist: Counter = Counter()
    move_times: List[float] = []
    import random
    for flex_color, seed in tasks:
        random.seed(seed)
        np.random.seed(seed)
        winner = _play_one_game(agent, config, flex_color, budget, rel, mb, md, depth_hist, move_times)
        if winner == flex_color:
            flex_wins += 1
    return flex_wins, len(tasks), dict(depth_hist), move_times


def _wilson_interval(wins: int, n: int, z: float = 1.96) -> Tuple[float, float]:
    if n == 0:
        return (0.0, 0.0)
    p = wins / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = (z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / denom
    return (center - half, center + half)


def _two_sided_binomial_p(wins: int, n: int) -> float:
    """Two-sided p-value vs a fair coin, exact for the n we use here (≤ a few hundred)."""
    if n == 0:
        return 1.0
    k = min(wins, n - wins)
    tail = sum(math.comb(n, i) for i in range(0, k + 1)) * (0.5 ** n)
    return min(1.0, 2.0 * tail)


def evaluate_lookahead_selfplay(config, model_path, games_per_color=100, num_workers=None):
    """Validate the flexible time-budget search against fixed 2-ply via gold self-play."""
    if num_workers is None:
        num_workers = config.get_num_self_play_workers()
    budget = config.get_play_time_budget_s()
    rel = config.get_search_relative_cutoff()
    mb = config.get_search_max_branch()
    md = config.get_search_max_depth()

    # Build the full task list: games_per_color games with each color as the flexible arm.
    tasks = []
    seed = 0
    for flex_color in (WHITE, BLACK):
        for _ in range(games_per_color):
            tasks.append((flex_color, seed))
            seed += 1
    total = len(tasks)

    print(f"Validating flexible search (budget={budget}s, relative_cutoff={rel}, max_branch={mb}, "
          f"max_depth={md}) vs fixed 2-ply: {total} games on {num_workers} workers, model={model_path}")

    # Round-robin tasks into per-worker chunks.
    chunks = [[] for _ in range(num_workers)]
    for i, t in enumerate(tasks):
        chunks[i % num_workers].append(t)
    worker_args = [(model_path, "config/config.yml", chunk, budget, rel, mb, md)
                   for chunk in chunks if chunk]

    start = time.monotonic()
    ctx = mp.get_context("spawn")
    with ctx.Pool(processes=len(worker_args)) as pool:
        results = pool.map(_worker, worker_args)
    elapsed = time.monotonic() - start

    flex_wins = sum(r[0] for r in results)
    depth_hist: Counter = Counter()
    move_times: List[float] = []
    for _, _, hist, times in results:
        for d, c in hist.items():
            depth_hist[d] += c
        move_times.extend(times)

    rate = flex_wins / total if total else 0.0
    lo, hi = _wilson_interval(flex_wins, total)
    pval = _two_sided_binomial_p(flex_wins, total)

    print()
    print(f"Flexible win rate: {flex_wins}/{total} = {rate:.3f}  "
          f"(95% Wilson CI [{lo:.3f}, {hi:.3f}], two-sided p={pval:.4f} vs 0.5)")
    print(f"Elapsed: {elapsed/60:.1f} min  ({elapsed/total:.1f}s/game)")

    print("\nDepth reached by the flexible search (how far it actually looked):")
    total_moves = sum(depth_hist.values())
    for d in sorted(depth_hist):
        c = depth_hist[d]
        print(f"  depth {d}: {c:6d} moves ({c/total_moves:.1%})")
    if move_times:
        srt = sorted(move_times)
        avg = sum(srt) / len(srt)
        median = srt[len(srt) // 2]
        print(f"\nFlexible move time: avg={avg:.2f}s  median={median:.2f}s  "
              f"min={srt[0]:.2f}s  max={srt[-1]:.2f}s  (n={len(srt)})")
