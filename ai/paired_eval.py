"""Paired duplicate-dice evaluation (#81 / E17): variance-reduced head-to-head.

Compares two models A and B by playing each trial twice on the SAME seeded dice
stream — once with A as White (B Black), once with B as White (A Black). Identical
rolls plus both models playing both sides cancel dice luck and the ~3pp first-mover
edge, so outcomes differ only where the models actually *disagree*. For near-identical
models (e.g. an EMA shadow vs its raw weights) agreement is high and the variance of
the estimator collapses, giving far more statistical power per game than an independent
head-to-head.

Per pair k (seed s_k):
    o1: White=A, Black=B  -> winner1   (A won iff winner1 == WHITE)
    o2: White=B, Black=A  -> winner2   (A won iff winner2 == BLACK)
    a_wins_k = [A won o1] + [A won o2]   in {0, 1, 2}
    d_k      = a_wins_k - 1              in {-1, 0, +1}

E[d_k] = 0 under A == B (by side symmetry), and > 0 iff A is stronger. We test
mean(d_k) > 0 with a one-sided z-test; std(d_k) shrinks toward 0 as agreement rises.
A self-comparison (A vs A) yields d_k == 0 for every pair — the two orientations are
byte-identical games — which is the module's correctness invariant.

The win-rate identity: with rate = (total A wins) / (2 * num_pairs),
    rate = 0.5 + mean(d_k) / 2,
so a paired result is directly comparable to a plain head-to-head percentage, but its
significance comes from the (tighter) paired statistic, not from sqrt(0.25 / 2n).
"""

import math
import multiprocessing as mp
import random
import time
from typing import List, Tuple

import numpy as np
import torch

from config.config_loader import ConfigLoader
from ai.checkpoint_io import load_agent_from_checkpoint
from game.game import Game
from domain.constants import WHITE, BLACK
from domain.ruleset import score_for


def _play_one_game(white_agent, black_agent, config, white_la: int, black_la: int):
    """Play one full game and return its outcome `(winner, points)`. Dice (and, for
    random-starter variants, the starter) come from the global RNG, so seed it before
    each call to share a common stream across orientations."""
    game = Game(config, starting_player=WHITE)
    game.player = game.ruleset.starting_player(WHITE)
    while not game.is_over():
        current = game.current_player
        game.dice.roll()
        moves = game.legal_moves()
        if not moves:
            game.switch_turn()
            continue
        agent = white_agent if current == WHITE else black_agent
        la = white_la if current == WHITE else black_la
        move, _ = agent.get_best_move(game.board, moves, current, lookahead_plies=la)
        game.board.apply(move, current)
        game.switch_turn()
    return game.outcome()


def run_pairs(agent_a, agent_b, config, seeds, lookahead: int) -> List[Tuple]:
    """Single-process core. For each seed, play both orientations on identical dice.
    Returns a list of (d_k, a_wins_k, a_points_k): a draw counts half a win, a_points_k
    is A's summed signed points over the two games. Used by tests and the workers."""
    out: List[Tuple] = []
    for s in seeds:
        random.seed(s); np.random.seed(s)
        o1 = _play_one_game(agent_a, agent_b, config, lookahead, lookahead)  # A is White
        random.seed(s); np.random.seed(s)
        o2 = _play_one_game(agent_b, agent_a, config, lookahead, lookahead)  # A is Black
        c1, p1 = score_for(o1, WHITE)
        c2, p2 = score_for(o2, BLACK)
        a_wins = c1 + c2
        if a_wins == int(a_wins):
            a_wins = int(a_wins)
        out.append((a_wins - 1, a_wins, p1 + p2))
    return out


def _worker(model_a, model_b, config_path, seeds, lookahead, result_q):
    """Subprocess: load both models once, play each assigned seed-pair, stream results."""
    torch.set_num_threads(1)
    config = ConfigLoader(config_path)
    device = torch.device("cpu")
    agent_a, _ = load_agent_from_checkpoint(model_a, config, device=device)
    agent_b, _ = load_agent_from_checkpoint(model_b, config, device=device)
    for s in seeds:
        result, = run_pairs(agent_a, agent_b, config, [s], lookahead)
        result_q.put(result)


def summarize(results: List[Tuple[int, int]]) -> dict:
    """Aggregate (d_k, a_wins_k) pairs into the paired statistic + comparison numbers."""
    n = len(results)
    d = [r[0] for r in results]
    a_wins = [r[1] for r in results]
    mean_d = sum(d) / n if n else 0.0
    var_d = sum((x - mean_d) ** 2 for x in d) / (n - 1) if n > 1 else 0.0
    std_d = math.sqrt(var_d)
    z = (mean_d * math.sqrt(n) / std_d) if std_d > 0 else 0.0
    one_sided_p = 0.5 * math.erfc(z / math.sqrt(2))  # P(Z > z)
    rate = 0.5 + mean_d / 2.0                          # A win rate over 2n games
    pos = sum(1 for x in d if x > 0)
    neg = sum(1 for x in d if x < 0)
    ties = sum(1 for x in d if x == 0)
    # How much the pairing bought: an independent fair head-to-head has std(d) ≈ 0.707.
    var_reduction = (0.5 / var_d) if var_d > 0 else float("inf")  # ~ effective-sample multiplier
    # A's average signed points per game (only meaningful when max_points > 1).
    a_points = [r[2] for r in results if len(r) > 2]
    ppg = (sum(a_points) / (2.0 * len(a_points))) if a_points else None
    return {
        "num_pairs": n, "num_games": 2 * n, "mean_d": mean_d, "std_d": std_d,
        "z": z, "one_sided_p": one_sided_p, "rate": rate,
        "pos": pos, "neg": neg, "ties": ties, "var_reduction": var_reduction,
        "points_per_game": ppg,
    }


def evaluate_paired(config, model_a, model_b, num_pairs=5000, num_workers=None,
                    base_seed=0, lookahead=None):
    """Paired duplicate-dice head-to-head of model A vs model B (A is the candidate).

    Plays num_pairs trials (2 games each) across spawn workers, streaming a live block,
    then prints the paired one-sided z-test, the equivalent A win rate, and the variance
    reduction the pairing achieved. A's edge is significant at p<0.05 iff z > 1.645.
    """
    if num_workers is None:
        num_workers = config.get_num_self_play_workers()
    if lookahead is None:
        lookahead = max(1, int(config.get_eval_candidate_lookahead_plies()))

    seeds = [base_seed + k for k in range(num_pairs)]
    print(f"Paired eval: A='{model_a}'  vs  B='{model_b}'", flush=True)
    print(f"{num_pairs} pairs ({2 * num_pairs} games), {num_workers} workers, "
          f"lookahead={lookahead}, base_seed={base_seed}", flush=True)

    chunks = [[] for _ in range(num_workers)]
    for i, s in enumerate(seeds):
        chunks[i % num_workers].append(s)
    chunks = [c for c in chunks if c]

    ctx = mp.get_context("spawn")
    result_q = ctx.Queue()
    procs = [ctx.Process(target=_worker,
                         args=(model_a, model_b, config.config_file, chunk, lookahead, result_q))
             for chunk in chunks]
    for p in procs:
        p.start()

    start = time.monotonic()
    results: List[Tuple[int, int]] = []
    report_every = max(1, num_pairs // 50)
    for done in range(1, num_pairs + 1):
        results.append(result_q.get())
        if done % report_every == 0 or done == num_pairs:
            s = summarize(results)
            elapsed = time.monotonic() - start
            eta = (elapsed / done) * (num_pairs - done)
            print(f"  {done}/{num_pairs} pairs  A={s['rate']:.4f}  z={s['z']:.2f}  "
                  f"(+{s['pos']}/-{s['neg']}/={s['ties']})  "
                  f"varRed×{s['var_reduction']:.1f}  eta {eta/60:.0f}m", flush=True)
    for p in procs:
        p.join()

    s = summarize(results)
    elapsed = time.monotonic() - start
    print("\n========== PAIRED FINAL ==========")
    print(f"A win rate (over {s['num_games']} games): {s['rate']:.4f}")
    if config.get_ruleset().max_points > 1 and s["points_per_game"] is not None:
        print(f"A average points/game: {s['points_per_game']:+.4f}")
    print(f"mean d_k = {s['mean_d']:+.4f}   std d_k = {s['std_d']:.4f}")
    print(f"Paired one-sided z = {s['z']:.3f}   p = {s['one_sided_p']:.4f}   "
          f"=> A {'IS' if s['z'] > 1.645 else 'is NOT'} significantly stronger (z>1.645)")
    print(f"Decisive pairs: A+{s['pos']}  B+{s['neg']}  tied {s['ties']}  "
          f"({s['ties'] / s['num_pairs']:.1%} cancelled by identical dice)")
    print(f"Variance reduction vs independent games: ~{s['var_reduction']:.1f}x effective sample")
    print(f"Elapsed: {elapsed / 60:.1f}m  ({elapsed / s['num_games']:.3f}s/game)")
    return s
