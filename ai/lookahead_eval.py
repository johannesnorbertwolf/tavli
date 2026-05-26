"""Parallel validation harness: time-budget flexible search vs fixed 2-ply.

Plays gold_v9 against itself. Both arms use the *same* checkpoint weights — they differ
only in how moves are chosen:

- **flexible arm**: ``get_best_move(time_budget_s=…, relative_cutoff=…, max_branch=…, max_depth=…)``
  (iterative-deepening beam expectimax, the search we want to validate).
- **2-ply arm**: ``get_best_move(lookahead_plies=2)`` (fixed-depth expectimax baseline).

We alternate which color is the flexible arm to remove first-move bias, count the flexible
arm's win rate, and report a Wilson 95% CI + binomial p-value vs 0.5. We also collect the
depth the flexible search actually reached on each of its moves (`agent.last_search_depth`)
and per-move wall times, so we can answer "how deep did it really look".

Parallelism uses ``multiprocessing`` spawn workers that stream one result *per game* back
through a shared queue, so the parent can print a live ASCII progress block with a running
win rate, depth histogram, and ETA — important because a full 1000-game run takes hours.
The model is static, so unlike training there is no weight queue: each worker loads the
checkpoint once and plays its chunk of games.
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


def _play_one_game(agent, config, flex_color, budget, rel, mb, md):
    """Play a single game; flex_color uses the flexible search, the other uses 2-ply.
    Returns (flex_won: bool, depth_hist: dict, move_times: list)."""
    depth_hist: Counter = Counter()
    move_times: List[float] = []
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
    return game.get_winner() == flex_color, dict(depth_hist), move_times


def _worker(model_path, config_path, tasks, budget, rel, mb, md, result_q):
    """Run a chunk of games in a subprocess, streaming one result per game to result_q."""
    import random
    torch.set_num_threads(1)
    config = ConfigLoader(config_path)
    agent, _ = load_agent_from_checkpoint(model_path, config, device=torch.device("cpu"))
    for flex_color, seed in tasks:
        random.seed(seed)
        np.random.seed(seed)
        won, depth_hist, move_times = _play_one_game(agent, config, flex_color, budget, rel, mb, md)
        result_q.put({"win": won, "depth_hist": depth_hist, "move_times": move_times})


def _wilson_interval(wins: int, n: int, z: float = 1.96) -> Tuple[float, float]:
    if n == 0:
        return (0.0, 0.0)
    p = wins / n
    denom = 1 + z * z / n
    center = (p + z * z / (2 * n)) / denom
    half = (z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / denom
    return (max(0.0, center - half), min(1.0, center + half))


def _two_sided_binomial_p(wins: int, n: int) -> float:
    """Two-sided p-value vs a fair coin, exact for the n we use here (a few thousand)."""
    if n == 0:
        return 1.0
    k = min(wins, n - wins)
    tail = sum(math.comb(n, i) for i in range(0, k + 1)) * (0.5 ** n)
    return min(1.0, 2.0 * tail)


def _fmt_dur(seconds: float) -> str:
    if seconds < 90:
        return f"{seconds:.0f}s"
    if seconds < 5400:
        return f"{seconds / 60:.0f}m"
    return f"{seconds / 3600:.1f}h"


def _bar(frac: float, width: int = 30, fill: str = "█", empty: str = "░") -> str:
    frac = max(0.0, min(1.0, frac))
    n = int(round(frac * width))
    return fill * n + empty * (width - n)


def _render_progress(done, total, flex_wins, depth_hist, elapsed) -> str:
    rate = flex_wins / done if done else 0.0
    lo, hi = _wilson_interval(flex_wins, done)
    losses = done - flex_wins
    eta = (elapsed / done) * (total - done) if done else 0.0
    tot_moves = sum(depth_hist.values()) or 1
    depth_str = "  ".join(
        f"d{d} {depth_hist[d] / tot_moves:4.0%} [{_bar(depth_hist[d] / tot_moves, width=10)}]"
        for d in sorted(depth_hist)
    )
    sep = "─" * 60
    return "\n".join([
        sep,
        f" eval-lookahead   {done}/{total} games ({done / total:.0%})   flexible vs 2-ply",
        f" win rate {rate:6.1%}   [{_bar(rate)}]   {flex_wins}W–{losses}L",
        f" 95% CI [{lo:.1%}, {hi:.1%}]",
        f" depth: {depth_str}",
        f" elapsed {_fmt_dur(elapsed)}   eta ~{_fmt_dur(eta)}",
        sep,
    ])


def evaluate_lookahead_selfplay(config, model_path, games_per_color=500, num_workers=None):
    """Validate the flexible time-budget search against fixed 2-ply via gold self-play.

    Streams a live ASCII progress block (running win rate, depth histogram, ETA) as games
    complete, then prints a final summary with the Wilson CI, binomial p-value, full depth
    histogram, and flexible move-time stats.
    """
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
          f"max_depth={md}) vs fixed 2-ply: {total} games on {num_workers} workers, model={model_path}",
          flush=True)

    # Round-robin tasks into per-worker chunks.
    chunks = [[] for _ in range(num_workers)]
    for i, t in enumerate(tasks):
        chunks[i % num_workers].append(t)
    chunks = [c for c in chunks if c]

    ctx = mp.get_context("spawn")
    result_q = ctx.Queue()
    procs = [
        ctx.Process(target=_worker,
                    args=(model_path, "config/config.yml", chunk, budget, rel, mb, md, result_q))
        for chunk in chunks
    ]
    for p in procs:
        p.start()

    start = time.monotonic()
    flex_wins = 0
    depth_hist: Counter = Counter()
    move_times: List[float] = []
    report_every = max(1, total // 100)  # ~100 progress updates over the run

    for done in range(1, total + 1):
        r = result_q.get()
        if r["win"]:
            flex_wins += 1
        for d, c in r["depth_hist"].items():
            depth_hist[d] += c
        move_times.extend(r["move_times"])
        if done % report_every == 0 or done == total:
            print(_render_progress(done, total, flex_wins, depth_hist, time.monotonic() - start),
                  flush=True)

    for p in procs:
        p.join()

    # Final summary.
    rate = flex_wins / total if total else 0.0
    lo, hi = _wilson_interval(flex_wins, total)
    pval = _two_sided_binomial_p(flex_wins, total)
    elapsed = time.monotonic() - start

    print("\n========== FINAL ==========")
    print(f"Flexible win rate: {flex_wins}/{total} = {rate:.3f}  "
          f"(95% Wilson CI [{lo:.3f}, {hi:.3f}], two-sided p={pval:.4f} vs 0.5)")
    print(f"Elapsed: {_fmt_dur(elapsed)}  ({elapsed / total:.1f}s/game)")
    print("\nDepth reached by the flexible search (how far it actually looked):")
    tot_moves = sum(depth_hist.values()) or 1
    for d in sorted(depth_hist):
        c = depth_hist[d]
        print(f"  depth {d}: {c:7d} moves ({c / tot_moves:.1%})  [{_bar(c / tot_moves, width=20)}]")
    if move_times:
        srt = sorted(move_times)
        avg = sum(srt) / len(srt)
        median = srt[len(srt) // 2]
        print(f"\nFlexible move time: avg={avg:.2f}s  median={median:.2f}s  "
              f"min={srt[0]:.2f}s  max={srt[-1]:.2f}s  (n={len(srt)})")
