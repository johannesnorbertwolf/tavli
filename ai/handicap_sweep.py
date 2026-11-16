"""Handicap exploration harness (#148, phase 1): gold self-play under one handicap.

Two copies of the same gold model play each other; one side carries a handicap
(domain/handicap.py). Every *pair* k uses one seed s_k and plays two games on the
same duplicate dice stream:

    game A: handicapped side = White;  game B: handicapped side = Black
    (White moves first in both unless `first_mover` says otherwise)

So the handicapped side moves first in A and second in B, and receives the opposite
half of the dice stream — first-mover edge and dice luck cancel within the pair.
Dice come from uniforms (`random.Random(s_k)`, two per turn, consumed even on a
skipped turn), mapped through each side's die, so modified dice stay aligned with
the fair stream. Probabilistic handicaps draw from a second per-seed stream.

Statistic per pair: h_k = handicapped-side wins in {0, 1, 2} (cap-hit = half);
rate = mean(h_k)/2, 95% CI from the per-pair standard error (Wilson over games when
that is degenerate). Every cell reuses the same seeds (common random numbers). With
no handicap A and B are the same game, so the baseline is exactly 50% — the harness
asserts its own symmetry; shift = rate - baseline.

All play is 1-ply. The exact bear-off DB (part of the deployed gold's strength:
without it the 1-ply net stacks checkers on the last point and stalls under the
exact-die bear-off rule) stays on except for geometry cells (smaller/larger house),
where its 6-point-home race values would be wrong. Under dice handicaps it still
assumes fair dice ahead, exactly like the net.
"""

import json
import math
import multiprocessing as mp
import random
import time
from typing import Dict, List, Optional, Sequence, Tuple

from domain.constants import WHITE, BLACK
from domain.handicap import KINDS, HandicapSpec, make_handicapped_rules, parse_spec, plain_roll

MAX_PLIES = 1500
_HSEED_SALT = 0x9E3779B1

# A cell is a tuple of (kind, intensity) pairs; () is the baseline.
Cell = Tuple[Tuple[str, float], ...]


def cell_label(cell: Cell) -> str:
    if not cell:
        return "baseline"
    return " + ".join(HandicapSpec(k, x).label() for k, x in cell)


def parse_cell(text: str) -> Cell:
    """'dice_ceiling:5+first_mover' -> (('dice_ceiling', 5), ('first_mover', 1))."""
    out = []
    for part in text.split("+"):
        s = parse_spec(part)
        out.append((s.kind, s.intensity))
    return tuple(out)


def rules_for(cell: Cell, side: int):
    return make_handicapped_rules([HandicapSpec(k, x, side) for k, x in cell])


def play_game(agent, config, rules, seed: int, trace: Optional[list] = None) -> Dict:
    """One 1-ply game under `rules` on the duplicate dice stream of `seed`.
    Returns {'winner': WHITE/BLACK/None, 'plies': int, 'pin': bool}."""
    rng = random.Random(seed)
    hrng = random.Random((seed * 2654435761) ^ _HSEED_SALT)
    plain = not hasattr(rules, "roll")
    board = rules.initial_board(config)
    player = WHITE if plain else rules.first_mover(WHITE)
    legal = rules.legal_moves
    own_turns = {WHITE: 0, BLACK: 0}
    plies = 0
    while not rules.is_over(board):
        if plies >= MAX_PLIES:
            return {"winner": None, "plies": plies, "pin": False}
        u1, u2 = rng.random(), rng.random()
        q1, q2 = hrng.random(), hrng.random()
        own_turns[player] += 1
        plies += 1
        if not plain and rules.skips_turn(player, own_turns[player]):
            if trace is not None:
                trace.append((player, None, "skip"))
            player = -player
            continue
        dice = plain_roll(u1, u2) if plain else rules.roll(player, u1, u2, q1, q2)
        moves = legal(board, player, dice)
        move = None
        if moves:
            move, _ = agent.get_best_move(board, moves, player, lookahead_plies=1)
            board.apply(move, player)
        if trace is not None:
            trace.append((player, (dice.die1.value, dice.die2.value, dice.is_pasch()), move))
        player = -player
    winner, _ = rules.outcome(board)
    return {"winner": winner, "plies": plies,
            "pin": winner is not None and not board.all_borne_off(winner)}


def play_pair(agent, config, cell: Cell, seed: int) -> Dict:
    """Both orientations of one seed. h = handicapped-side wins (0..2, cap-hit = 0.5)."""
    h = 0.0
    out = {"seed": seed}
    for tag, side in (("a", WHITE), ("b", BLACK)):
        g = play_game(agent, config, rules_for(cell, side), seed)
        h += 0.5 if g["winner"] is None else float(g["winner"] == side)
        out[tag] = g
    out["h"] = h
    return out


# --- multiprocessing -------------------------------------------------------

_W = {}


def _init_worker(model_path: str, config_path: str) -> None:
    import torch
    from ai.checkpoint_io import load_agent_from_checkpoint
    from config.config_loader import ConfigLoader
    torch.set_num_threads(1)
    config = ConfigLoader(config_path)
    agent, _ = load_agent_from_checkpoint(model_path, config)
    _W["agent"], _W["config"], _W["db"] = agent, config, agent.bearoff


def cell_uses_bearoff_db(cell: Cell) -> bool:
    """The DB's race values assume 6-point homes: off for geometry handicaps."""
    return not any(KINDS[k].category == "geometry" for k, _ in cell)


def _task(args):
    cell, seed = args
    agent = _W["agent"]
    agent.bearoff = _W["db"] if cell_uses_bearoff_db(cell) else None
    return cell, play_pair(agent, _W["config"], cell, seed)


def run_cells(cells: Sequence[Cell], num_pairs: int, model_path: str, config_path: str,
              workers: int = 2, base_seed: int = 0, progress=True) -> Dict[Cell, List[Dict]]:
    tasks = [(c, base_seed + k) for c in cells for k in range(num_pairs)]
    results: Dict[Cell, List[Dict]] = {c: [] for c in cells}
    start = time.monotonic()
    if workers <= 1:
        _init_worker(model_path, config_path)
        it = map(_task, tasks)
        pool = None
    else:
        pool = mp.get_context("spawn").Pool(workers, _init_worker, (model_path, config_path))
        it = pool.imap_unordered(_task, tasks, chunksize=4)
    try:
        for i, (cell, r) in enumerate(it, 1):
            results[cell].append(r)
            if progress and (i % max(1, len(tasks) // 40) == 0 or i == len(tasks)):
                el = time.monotonic() - start
                print(f"  {i}/{len(tasks)} pairs  {el/60:.1f}m  eta {el/i*(len(tasks)-i)/60:.1f}m",
                      flush=True)
    finally:
        if pool is not None:
            pool.close()
            pool.join()
    for c in cells:
        results[c].sort(key=lambda r: r["seed"])
    return results


# --- statistics / reporting -----------------------------------------------

def _wilson(p: float, n: int, z: float = 1.96) -> Tuple[float, float]:
    if n == 0:
        return 0.0, 1.0
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    w = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - w), min(1.0, c + w)


def summarize_cell(cell: Cell, pairs: List[Dict]) -> Dict:
    n = len(pairs)
    x = [p["h"] / 2.0 for p in pairs]
    rate = sum(x) / n if n else 0.0
    var = sum((v - rate) ** 2 for v in x) / (n - 1) if n > 1 else 0.0
    se = math.sqrt(var / n) if n else 0.0
    if se > 0:
        lo, hi = max(0.0, rate - 1.96 * se), min(1.0, rate + 1.96 * se)
    elif cell:
        lo, hi = _wilson(rate, 2 * n)
    else:
        lo = hi = rate
    games = [g for p in pairs for g in (p["a"], p["b"])]
    kinds = [k for k, _ in cell]
    return {
        "label": cell_label(cell),
        "cell": [[k, x_] for k, x_ in cell],
        "pairs": n, "games": 2 * n, "rate": rate, "ci_lo": lo, "ci_hi": hi, "se": se,
        "first_mover_win": (sum(1 for p in pairs if p["a"]["winner"] == WHITE) / n) if n else 0.0,
        "mean_plies": sum(g["plies"] for g in games) / len(games) if games else 0.0,
        "pin_win_frac": sum(1 for g in games if g["pin"]) / len(games) if games else 0.0,
        "capped": sum(1 for g in games if g["winner"] is None),
        "on_distribution": all(KINDS[k].on_distribution for k in kinds),
        "bearoff_db": cell_uses_bearoff_db(cell),
        "categories": sorted({KINDS[k].category for k in kinds}),
    }


def default_cells(only: Optional[Sequence[str]] = None) -> List[Cell]:
    cells: List[Cell] = [()]
    for kind, info in KINDS.items():
        if only and kind not in only:
            continue
        cells += [((kind, x),) for x in info.intensities]
    return cells


#: Combos of the two most promising orthogonal levers (chosen from the singles run;
#: see docs/handicap-phase1.md).
DEFAULT_COMBOS = [
    "smaller_house:5+first_mover",
    "smaller_house:4+first_mover",
    "smaller_house:5+pip_headstart:2",
    "smaller_house:4+pip_headstart:2",
    "smaller_house:3+pip_headstart:4",
    "pip_headstart:2+first_mover",
]


def _note(s: Dict) -> str:
    if s["label"] == "baseline":
        return "reference"
    db = "" if s.get("bearoff_db", True) else "; DB off"
    if s["on_distribution"]:
        return "dice/tempo only (net assumes fair dice ahead)" + db
    return "position/geometry off-distribution" + db


def to_markdown(summaries: List[Dict]) -> str:
    base = next((s for s in summaries if s["label"] == "baseline"), None)
    b = base["rate"] if base else 0.5
    rows = sorted(summaries, key=lambda s: (s["rate"] - b, s["label"]))
    lines = [
        "| handicap | handicapped-side win % [95% CI] | shift (pp) | games | mean plies | pin wins | net reliability |",
        "|---|---|---|---|---|---|---|",
    ]
    for s in rows:
        lines.append(
            f"| `{s['label']}` | {100*s['rate']:.1f} [{100*s['ci_lo']:.1f}, {100*s['ci_hi']:.1f}] "
            f"| {100*(s['rate']-b):+.1f} | {s['games']} | {s['mean_plies']:.0f} "
            f"| {100*s['pin_win_frac']:.0f}% | {_note(s)} |")
    return "\n".join(lines)


def run_sweep(config, model_path: str, games: int = 500, workers: int = 2,
              only: Optional[Sequence[str]] = None, combos: Optional[Sequence[str]] = None,
              base_seed: int = 0, out_json: str = "training_runs/handicap_sweep.json",
              out_md: Optional[str] = None) -> List[Dict]:
    cells = default_cells(only)
    # Explicit --combos always run; the default combos follow the --only filter.
    for c in (DEFAULT_COMBOS if combos is None else combos):
        cell = parse_cell(c)
        if combos is not None or not only or all(k in only for k, _ in cell):
            cells.append(cell)
    num_pairs = max(1, games // 2)
    print(f"Handicap sweep: {len(cells)} cells x {num_pairs} pairs ({2*num_pairs} games), "
          f"{workers} workers, model={model_path}", flush=True)
    results = run_cells(cells, num_pairs, model_path, config.config_file, workers, base_seed)
    summaries = [summarize_cell(c, results[c]) for c in cells]
    base = summaries[0]
    if abs(base["rate"] - 0.5) > 1e-12:
        raise AssertionError(f"baseline not symmetric: {base['rate']}")
    for s in summaries:
        s["shift"] = s["rate"] - base["rate"]
    md = to_markdown(summaries)
    payload = {"model": model_path, "pairs_per_cell": num_pairs, "base_seed": base_seed,
               "lookahead_plies": 1,
               "bearoff_db": "on (from config) except geometry cells",
               "baseline_first_mover_win": base["first_mover_win"],
               "cells": summaries}
    import os
    os.makedirs(os.path.dirname(out_json) or ".", exist_ok=True)
    with open(out_json, "w") as f:
        json.dump(payload, f, indent=1)
    out_md = out_md or os.path.splitext(out_json)[0] + ".md"
    with open(out_md, "w") as f:
        f.write(f"First-mover win rate (baseline, game A): {100*base['first_mover_win']:.1f}%\n\n")
        f.write(md + "\n")
    print(md)
    print(f"\nWrote {out_json} and {out_md}")
    return summaries
