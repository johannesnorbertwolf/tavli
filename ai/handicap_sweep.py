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

Tier-1 dice kinds (concept doc §3):
- `weighted_dice:β` — the rules' `roll_valuer` is the agent's 1-ply `Agent.roll_values`
  (21 per-roll best-move values under the cell's own move generator); the favoured side's
  roll is the tilted inverse CDF of the turn's SAME main-stream uniforms (domain/handicap.py),
  so β = 0 is the fair game bit-for-bit and pairs stay aligned.
- `rerolls:N` — the favoured side holds N tokens per game. Policy (`wants_reroll`): reroll
  while tokens remain and v(rolled) < E_p[v(fresh roll)] − margin, p = the side's own roll
  distribution (fair unless it also has weighted dice), margin `REROLL_MARGIN` (--margin).
  A reroll draws two uniforms from a dedicated per-colour stream (`_reroll_rng`), never from
  the main stream: the main stream is consumed exactly two uniforms per turn whatever the
  rerolls, so every later turn of both games in a pair still sees the same uniforms; only
  the rerolled turn itself differs (it gets the colour's next reroll uniforms).

Tier 2 (#148 E3): cells may use the rule-changing kinds `overshoot:1`, `safe_point:p`,
`checkers:n` and `smaller_house:k` (domain/handicap.py) and combos of them (`--tier2` runs the
default tier-2 grid + `DEFAULT_TIER2_COMBOS`). They are meant for the handicap-aware model
(`--config config/config-handicap.yml --model models/plakoto_hc_gold_vK.pth`); with it
(`is_handicap_model`) the bear-off DB stays on for every cell — the board gate
(`HandicapBoard.bearoff_exact`) switches it off exactly where it would be wrong — and every
cell made of position + tier-2 kinds gets the net's start-position estimate (the net knows the
rules). The app table (`ios/scripts/make_handicap_table.py --tier2 <json>`) uses the same
log-odds additive model as tier 1.

Start-position estimate (`start_estimate`, concept doc §5): for cells made only of position
levers (`ESTIMABLE_KINDS`) the net's prediction of the measured rate, computed the way the
pair is played — game A and B each contribute the start position's pre-roll value (average
over the 21 opening rolls of the first mover's best 1-ply move value) from the handicapped
side's view, averaged. With no `first_mover` that is the roll-off average (each side moves
first in one game); `first_mover` makes the handicapped side move second in both.
"""

import json
import math
import multiprocessing as mp
import random
import time
from typing import Dict, List, Optional, Sequence, Tuple

from domain.constants import WHITE, BLACK
from domain.handicap import (
    KINDS, ROLLS, TIER2_KINDS, HandicapSpec, make_handicapped_rules, parse_spec, plain_roll,
    roll_index, tilted_roll_probs,
)

MAX_PLIES = 1500
_HSEED_SALT = 0x9E3779B1
_RSEED_SALT = 0x5BD1E995

#: Reroll when the rolled value trails the expected fresh-roll value by more than this.
REROLL_MARGIN = 0.02

#: Kinds whose effect is fully in the start position / first mover, so the net's
#: start-position estimate applies (E1 compares it with the measured rate).
ESTIMABLE_KINDS = frozenset({"first_mover", "pip_headstart", "pre_borne"})

#: Tier-2 kinds the plain (phase-1 / tier-1) sweep leaves out of its default cells: only the
#: handicap-aware net encodes them (smaller_house was already a phase-1 cell and stays).
TIER2_ONLY_KINDS = frozenset(k for k in TIER2_KINDS if k != "smaller_house")

#: Tier-2 combos for the additive-model check (`--tier2`).
DEFAULT_TIER2_COMBOS = [
    "overshoot:1+safe_point:6",
    "overshoot:1+checkers:14",
    "overshoot:1+smaller_house:4",
    "safe_point:6+checkers:14",
    "safe_point:6+smaller_house:4",
    "checkers:16+smaller_house:4",
    "overshoot:1+safe_point:6+checkers:14",
    "overshoot:1+safe_point:6+checkers:14+smaller_house:4",
]


def is_handicap_model(agent) -> bool:
    """True for the tier-2-aware net (encoder `unary_v3_hc1`)."""
    return getattr(agent.board_encoder, "version", "") == "unary_v3_hc1"

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


def rules_for(cell: Cell, side: int, roll_valuer=None):
    return make_handicapped_rules([HandicapSpec(k, x, side) for k, x in cell], roll_valuer)


def agent_roll_valuer(agent, rules):
    """The weighted-dice oracle: 21 per-roll 1-ply best-move values under `rules`' generator."""
    legal = rules.legal_moves
    return lambda board, color: agent.roll_values(board, color, legal)


def wants_reroll(values, d1: int, d2: int, beta: float = 0.0,
                 margin: float = REROLL_MARGIN) -> bool:
    """Reroll policy: v(rolled) < E[v(fresh roll)] − margin, the expectation over the side's
    own roll distribution (fair, or tilted when it also has weighted dice)."""
    probs = tilted_roll_probs(values, beta)
    expected = sum(p * v for p, v in zip(probs, values))
    return values[roll_index(d1, d2)] < expected - margin


def _reroll_rng(seed: int, color: int) -> random.Random:
    """Dedicated per-colour reroll stream of `seed` (independent of the main dice stream)."""
    return random.Random(((seed * 2654435761) + (1 if color == WHITE else 2) * 0x85EBCA6B)
                         ^ _RSEED_SALT)


def play_game(agent, config, rules, seed: int, trace: Optional[list] = None,
              reroll_margin: float = REROLL_MARGIN) -> Dict:
    """One 1-ply game under `rules` on the duplicate dice stream of `seed`.
    Returns {'winner': WHITE/BLACK/None, 'plies': int, 'pin': bool, 'rerolls': int}."""
    rng = random.Random(seed)
    hrng = random.Random((seed * 2654435761) ^ _HSEED_SALT)
    plain = not hasattr(rules, "roll")
    board = rules.initial_board(config)
    player = WHITE if plain else rules.first_mover(WHITE)
    legal = rules.legal_moves
    own_turns = {WHITE: 0, BLACK: 0}
    tokens = {c: (0 if plain else rules.reroll_tokens(c)) for c in (WHITE, BLACK)}
    rr = {c: _reroll_rng(seed, c) for c in (WHITE, BLACK) if tokens[c]}
    valuer = None
    if not plain and (any(tokens.values()) or rules.needs_roll_values(WHITE)
                      or rules.needs_roll_values(BLACK)):
        valuer = rules.roll_valuer or agent_roll_valuer(agent, rules)
    rerolls = 0
    plies = 0
    while not rules.is_over(board):
        if plies >= MAX_PLIES:
            return {"winner": None, "plies": plies, "pin": False, "rerolls": rerolls}
        u1, u2 = rng.random(), rng.random()
        q1, q2 = hrng.random(), hrng.random()
        own_turns[player] += 1
        plies += 1
        if not plain and rules.skips_turn(player, own_turns[player]):
            if trace is not None:
                trace.append((player, None, "skip"))
            player = -player
            continue
        if plain:
            dice = plain_roll(u1, u2)
        else:
            values = None
            if valuer is not None and (tokens[player] or rules.needs_roll_values(player)):
                values = valuer(board, player)
            dice = rules.roll(player, u1, u2, q1, q2, board, values)
            beta = rules.roll_beta(player)
            while tokens[player] and wants_reroll(values, dice.die1.value, dice.die2.value,
                                                  beta, reroll_margin):
                tokens[player] -= 1
                rerolls += 1
                if trace is not None:
                    trace.append((player, (dice.die1.value, dice.die2.value, dice.is_pasch()),
                                  "reroll"))
                dice = rules.roll(player, rr[player].random(), rr[player].random(), q1, q2,
                                  board, values)
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
            "pin": winner is not None and not board.all_borne_off(winner), "rerolls": rerolls}


def play_pair(agent, config, cell: Cell, seed: int,
              reroll_margin: float = REROLL_MARGIN) -> Dict:
    """Both orientations of one seed. h = handicapped-side wins (0..2, cap-hit = 0.5)."""
    h = 0.0
    out = {"seed": seed}
    for tag, side in (("a", WHITE), ("b", BLACK)):
        g = play_game(agent, config, rules_for(cell, side), seed, reroll_margin=reroll_margin)
        h += 0.5 if g["winner"] is None else float(g["winner"] == side)
        out[tag] = g
    out["h"] = h
    return out


def is_estimable(cell: Cell, handicap_model: bool = False) -> bool:
    ok = ESTIMABLE_KINDS | (frozenset(TIER2_KINDS) if handicap_model else frozenset())
    return all(k in ok for k, _ in cell)


def start_estimate(agent, config, cell: Cell) -> Optional[float]:
    """Net estimate of the handicapped side's pair win rate from the start position alone
    (None unless every kind is a position lever, or — for the handicap-aware net — a tier-2
    lever). Per orientation: v = the first mover's pre-roll value (mean over the 21 opening
    rolls of its best 1-ply move value); the handicapped side scores v if it moves first,
    else 1 − v. Returns the mean of A and B."""
    if not is_estimable(cell, is_handicap_model(agent)):
        return None
    est = 0.0
    for side in (WHITE, BLACK):
        rules = rules_for(cell, side)
        board = rules.initial_board(config)
        first = rules.first_mover(WHITE) if hasattr(rules, "first_mover") else WHITE
        vals = agent.roll_values(board, first, rules.legal_moves)
        v = sum(w * x for (_, _, w), x in zip(ROLLS, vals))
        est += v if first == side else 1.0 - v
    return est / 2.0


# --- multiprocessing -------------------------------------------------------

_W = {}


def _init_worker(model_path: str, config_path: str, reroll_margin: float = REROLL_MARGIN) -> None:
    import torch
    from ai.checkpoint_io import load_agent_from_checkpoint
    from config.config_loader import ConfigLoader
    torch.set_num_threads(1)
    config = ConfigLoader(config_path)
    agent, _ = load_agent_from_checkpoint(model_path, config)
    _W["agent"], _W["config"], _W["db"] = agent, config, agent.bearoff
    _W["margin"] = reroll_margin
    _W["hc"] = is_handicap_model(agent)


def cell_uses_bearoff_db(cell: Cell, handicap_model: bool = False) -> bool:
    """Phase-1 rule (kept for comparability): the DB is off for geometry handicaps. With the
    handicap-aware net it is always on: `HandicapBoard.bearoff_exact` gates it per position
    (a smaller home is exact; overshoot, > 15 checkers and larger homes are not)."""
    if handicap_model:
        return True
    return not any(KINDS[k].category == "geometry" for k, _ in cell)


def _task(args):
    cell, seed = args
    agent = _W["agent"]
    agent.bearoff = _W["db"] if cell_uses_bearoff_db(cell, _W.get("hc", False)) else None
    return cell, play_pair(agent, _W["config"], cell, seed, _W["margin"])


def run_cells(cells: Sequence[Cell], num_pairs: int, model_path: str, config_path: str,
              workers: int = 2, base_seed: int = 0, progress=True,
              reroll_margin: float = REROLL_MARGIN) -> Dict[Cell, List[Dict]]:
    tasks = [(c, base_seed + k) for c in cells for k in range(num_pairs)]
    results: Dict[Cell, List[Dict]] = {c: [] for c in cells}
    start = time.monotonic()
    if workers <= 1:
        _init_worker(model_path, config_path, reroll_margin)
        it = map(_task, tasks)
        pool = None
    else:
        pool = mp.get_context("spawn").Pool(workers, _init_worker,
                                            (model_path, config_path, reroll_margin))
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


def summarize_cell(cell: Cell, pairs: List[Dict], handicap_model: bool = False) -> Dict:
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
        "mean_rerolls": sum(g.get("rerolls", 0) for g in games) / len(games) if games else 0.0,
        "on_distribution": all(KINDS[k].on_distribution
                               or (handicap_model and k in TIER2_KINDS) for k in kinds),
        "bearoff_db": cell_uses_bearoff_db(cell, handicap_model),
        "categories": sorted({KINDS[k].category for k in kinds}),
    }


def default_cells(only: Optional[Sequence[str]] = None, tier2: bool = False) -> List[Cell]:
    """Baseline + every kind's default grid. Without `only`, the tier-2-only kinds are left
    out unless `tier2` (then only the tier-2 kinds run)."""
    cells: List[Cell] = [()]
    for kind, info in KINDS.items():
        if only:
            if kind not in only:
                continue
        elif tier2 and kind not in TIER2_KINDS:
            continue
        elif not tier2 and kind in TIER2_ONLY_KINDS:
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
    if s["on_distribution"] and set(s.get("categories", ())) & {"rules", "position", "geometry"}:
        return "tier 2, handicap-aware net (DB gated per position)"
    if s["on_distribution"]:
        return "dice/tempo only (net assumes fair dice ahead)" + db
    return "position/geometry off-distribution" + db


def to_markdown(summaries: List[Dict]) -> str:
    base = next((s for s in summaries if s["label"] == "baseline"), None)
    b = base["rate"] if base else 0.5
    rows = sorted(summaries, key=lambda s: (s["rate"] - b, s["label"]))
    lines = [
        "| handicap | handicapped-side win % [95% CI] | shift (pp) | net est. % | games | mean plies | pin wins | net reliability |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for s in rows:
        est = s.get("net_estimate")
        est_txt = "" if est is None else f"{100*est:.1f}"
        lines.append(
            f"| `{s['label']}` | {100*s['rate']:.1f} [{100*s['ci_lo']:.1f}, {100*s['ci_hi']:.1f}] "
            f"| {100*(s['rate']-b):+.1f} | {est_txt} | {s['games']} | {s['mean_plies']:.0f} "
            f"| {100*s['pin_win_frac']:.0f}% | {_note(s)} |")
    return "\n".join(lines)


def run_sweep(config, model_path: str, games: int = 500, workers: int = 2,
              only: Optional[Sequence[str]] = None, combos: Optional[Sequence[str]] = None,
              base_seed: int = 0, out_json: str = "training_runs/handicap_sweep.json",
              out_md: Optional[str] = None, reroll_margin: float = REROLL_MARGIN,
              tier2: bool = False) -> List[Dict]:
    cells = default_cells(only, tier2)
    # Explicit --combos always run; the default combos follow the --only filter.
    default_combos = DEFAULT_TIER2_COMBOS if tier2 else DEFAULT_COMBOS
    for c in (default_combos if combos is None else combos):
        cell = parse_cell(c)
        if combos is not None or not only or all(k in only for k, _ in cell):
            cells.append(cell)
    cells = list(dict.fromkeys(cells))  # a combo may repeat a single
    num_pairs = max(1, games // 2)
    print(f"Handicap sweep: {len(cells)} cells x {num_pairs} pairs ({2*num_pairs} games), "
          f"{workers} workers, model={model_path}", flush=True)
    results = run_cells(cells, num_pairs, model_path, config.config_file, workers, base_seed,
                        reroll_margin=reroll_margin)
    from ai.checkpoint_io import load_agent_from_checkpoint
    est_agent, _ = load_agent_from_checkpoint(model_path, config)
    hc = is_handicap_model(est_agent)
    summaries = [summarize_cell(c, results[c], hc) for c in cells]
    for c, s in zip(cells, summaries):
        s["net_estimate"] = start_estimate(est_agent, config, c)
    base = summaries[0]
    if abs(base["rate"] - 0.5) > 1e-12:
        raise AssertionError(f"baseline not symmetric: {base['rate']}")
    for s in summaries:
        s["shift"] = s["rate"] - base["rate"]
    md = to_markdown(summaries)
    payload = {"model": model_path, "pairs_per_cell": num_pairs, "base_seed": base_seed,
               "lookahead_plies": 1, "reroll_margin": reroll_margin,
               "bearoff_db": ("on (from config), gated per position by HandicapBoard.bearoff_exact"
                              if hc else "on (from config) except geometry cells"),
               "handicap_model": hc,
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
