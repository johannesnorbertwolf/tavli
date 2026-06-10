"""Rollout lab (#80): disagreement mining + rollout-labeled fine-tuning.

The net is strong, so its remaining errors are sparse and uniform self-play
rarely corrects them. This module targets compute at exactly those spots:

1. **Mine**: play greedy self-play games with the current checkpoint and, for a
   sample of pre-roll states, compare the net's static value `V_net(s)` with a
   one-roll expectimax `V_search(s)` (best 1-ply move over all 21 dice
   outcomes, exact bear-off equity at race leaves). The absolute residual
   `|V_search - V_net|` is the net's self-inconsistency — the positions where
   deeper search would change the evaluation.
2. **Label**: the top-residual states are labeled by Monte-Carlo rollouts with
   the current 1-ply greedy policy (both sides), truncated as soon as the
   position becomes an exact race — the bear-off DB equity replaces the rest of
   the playout, keeping rollouts short and low-variance.
3. **Fine-tune**: supervised BCE on the labeled set at small LR, mixed 50/50
   with "anchor" states (targets = the net's own pre-fine-tune values) so the
   net only moves where the rollouts say it is wrong.

The result is saved as a candidate checkpoint (optimizer state and metadata
copied from the source checkpoint) and must pass a head-to-head gate vs the
source before being promoted — see the `rollout-lab` mode in `main.py`.

All states are encoded from the mover's perspective pre-roll, matching the
training pipeline's state semantics. Pure-race states are skipped during
mining (they already get exact targets from the bear-off DB).
"""

import os
import random
import time
from dataclasses import dataclass
from typing import List, Optional, Tuple

import numpy as np
import torch

from ai.bearoff import exact_value_on_roll
from ai.checkpoint_io import load_agent_from_checkpoint
from domain.constants import WHITE
from domain.dice import Dice
from domain.move_generation import legal_moves
from game.game import Game

_DIE_SIDES = 6


def _dice_outcomes() -> List[Tuple[int, int, float]]:
    outcomes = []
    n = _DIE_SIDES
    for i in range(1, n + 1):
        for j in range(i, n + 1):
            weight = (1.0 / (n * n)) if i == j else (2.0 / (n * n))
            outcomes.append((i, j, weight))
    return outcomes


_DICE_OUTCOMES = _dice_outcomes()


def state_net_value(agent, board, mover_is_white: bool) -> float:
    """Net's static pre-roll value of the state from the mover's perspective."""
    encoded = agent.board_encoder.encode_board(board, is_whites_turn=mover_is_white)
    x = torch.from_numpy(encoded).float().unsqueeze(0)
    with torch.no_grad():
        return float(agent.board_evaluator(x).squeeze())


def state_search_value(agent, board, mover_color: int) -> float:
    """One-roll expectimax pre-roll value: expectation over the 21 dice
    outcomes of the best 1-ply move score (exact-race leaves resolved by the
    bear-off DB inside `_evaluate_moves_batch`). A pass roll keeps the board
    and hands the turn to the opponent."""
    mover_is_white = mover_color == WHITE
    dice = Dice(_DIE_SIDES)
    expected = 0.0
    for (d1, d2, weight) in _DICE_OUTCOMES:
        dice.set(d1, d2)
        moves = legal_moves(board, mover_color, dice)
        if moves:
            scores = agent._evaluate_moves_batch(board, moves, mover_color)
            expected += weight * max(scores)
        else:
            exact = exact_value_on_roll(board, not mover_is_white, agent.bearoff)
            if exact is not None:
                expected += weight * (1.0 - exact)
            else:
                expected += weight * (1.0 - state_net_value(agent, board, not mover_is_white))
    return expected


def rollout_value(agent, board, mover_color: int, rng: np.random.Generator,
                  max_plies: int = 1000) -> float:
    """One greedy-1-ply playout from a pre-roll state. Returns P(mover wins).

    Truncates as soon as the position is an exact race (bear-off DB equity) or
    a side wins. Dice come from `rng` so rollouts are reproducible per worker.
    """
    b = board.clone()
    cur = mover_color
    for _ in range(max_plies):
        exact = exact_value_on_roll(b, cur == WHITE, agent.bearoff)
        if exact is not None:
            return exact if cur == mover_color else 1.0 - exact
        d1 = int(rng.integers(1, _DIE_SIDES + 1))
        d2 = int(rng.integers(1, _DIE_SIDES + 1))
        dice = Dice(_DIE_SIDES)
        dice.set(d1, d2)
        moves = legal_moves(b, cur, dice)
        if moves:
            move, _ = agent.get_best_move(b, moves, cur, lookahead_plies=1)
            b.apply(move, cur)
            if b.has_won(cur):
                return 1.0 if cur == mover_color else 0.0
        cur = -cur
    # Pathologically long playout: fall back to the net's value.
    v = state_net_value(agent, b, cur == WHITE)
    return v if cur == mover_color else 1.0 - v


@dataclass
class MinedPosition:
    board: object          # Board clone at the pre-roll state
    mover_color: int
    encoded: np.ndarray    # mover-perspective encoding
    v_net: float
    v_search: float

    @property
    def residual(self) -> float:
        return abs(self.v_search - self.v_net)


def mine_games(agent, config, num_games: int, sample_every: int,
               rng: np.random.Generator) -> List[MinedPosition]:
    """Greedy self-play games; every `sample_every`-th non-race pre-roll state
    gets a residual measurement and is returned as a candidate."""
    mined: List[MinedPosition] = []
    encoder = agent.board_encoder
    ply_counter = 0
    for _ in range(num_games):
        game = Game(config)
        while not game.is_over():
            cur = game.current_player
            is_race = exact_value_on_roll(game.board, cur == WHITE, agent.bearoff) is not None
            if not is_race:
                ply_counter += 1
                if ply_counter % sample_every == 0:
                    v_net = state_net_value(agent, game.board, cur == WHITE)
                    v_search = state_search_value(agent, game.board, cur)
                    mined.append(MinedPosition(
                        board=game.board.clone(),
                        mover_color=cur,
                        encoded=encoder.encode_board(game.board, is_whites_turn=cur == WHITE),
                        v_net=v_net,
                        v_search=v_search,
                    ))
            game.dice.roll()
            moves = legal_moves(game.board, cur, game.dice)
            if moves:
                move, _ = agent.get_best_move(game.board, moves, cur, lookahead_plies=1)
                game.board.apply(move, cur)
            game.switch_turn()
    return mined


def label_positions(agent, positions: List[MinedPosition], rollouts_per_position: int,
                    rng: np.random.Generator) -> np.ndarray:
    """Mean truncated-rollout return per position, mover's perspective."""
    labels = np.empty(len(positions), dtype=np.float32)
    for i, pos in enumerate(positions):
        total = 0.0
        for _ in range(rollouts_per_position):
            total += rollout_value(agent, pos.board, pos.mover_color, rng)
        labels[i] = total / rollouts_per_position
    return labels


def _worker_mine_and_label(args) -> dict:
    """Pool worker: mine a share of games, keep the local top residuals,
    rollout-label them, and return flat arrays (no Board objects cross the
    process boundary)."""
    (worker_id, checkpoint_path, config_path, num_games, sample_every,
     top_k_local, rollouts_per_position, base_seed) = args
    torch.set_num_threads(1)
    from config.config_loader import ConfigLoader
    config = ConfigLoader(config_path)
    agent, _ = load_agent_from_checkpoint(checkpoint_path, config)

    seed = (base_seed + worker_id * 9176 + 13) & 0xFFFFFFFF
    random.seed(seed)
    np.random.seed(seed)
    rng = np.random.default_rng(seed)

    t0 = time.perf_counter()
    mined = mine_games(agent, config, num_games, sample_every, rng)
    mined.sort(key=lambda p: p.residual, reverse=True)
    labeled, anchors = mined[:top_k_local], mined[top_k_local:]
    labels = label_positions(agent, labeled, rollouts_per_position, rng)
    return {
        "labeled_states": np.stack([p.encoded for p in labeled]) if labeled else np.empty((0, 0), np.float32),
        "labels": labels,
        "labeled_residuals": np.array([p.residual for p in labeled], dtype=np.float32),
        "labeled_v_net": np.array([p.v_net for p in labeled], dtype=np.float32),
        "anchor_states": np.stack([p.encoded for p in anchors]) if anchors else np.empty((0, 0), np.float32),
        "anchor_targets": np.array([p.v_net for p in anchors], dtype=np.float32),
        "mined_count": len(mined),
        "seconds": time.perf_counter() - t0,
    }


def fine_tune(evaluator, labeled_states: np.ndarray, labels: np.ndarray,
              anchor_states: np.ndarray, anchor_targets: np.ndarray,
              lr: float = 1e-4, steps: int = 2000, batch_size: int = 128,
              seed: int = 0) -> None:
    """Supervised BCE fine-tune in place: each minibatch is half rollout-labeled
    positions, half anchors pinned to the net's pre-fine-tune values."""
    rng = np.random.default_rng(seed)
    optimizer = torch.optim.Adam(evaluator.parameters(), lr=lr)
    lab_x = torch.from_numpy(labeled_states).float()
    lab_y = torch.from_numpy(labels).float()
    anc_x = torch.from_numpy(anchor_states).float()
    anc_y = torch.from_numpy(anchor_targets).float()
    half = batch_size // 2

    evaluator.train()
    try:
        for _ in range(steps):
            li = rng.integers(0, len(lab_x), size=min(half, len(lab_x)))
            xs, ys = [lab_x[li]], [lab_y[li]]
            if len(anc_x):
                ai_ = rng.integers(0, len(anc_x), size=half)
                xs.append(anc_x[ai_])
                ys.append(anc_y[ai_])
            x = torch.cat(xs)
            y = torch.cat(ys)
            optimizer.zero_grad()
            loss = torch.nn.functional.binary_cross_entropy_with_logits(
                evaluator.forward_logits(x).squeeze(1), y)
            loss.backward()
            optimizer.step()
    finally:
        evaluator.eval()


def run_rollout_lab(config, config_path: str, checkpoint_path: str = "trained_model.pth",
                    out_path: str = "models/rollout_candidate.pth",
                    num_games: int = 600, sample_every: int = 2, top_k: int = 4000,
                    rollouts_per_position: int = 64, lr: float = 1e-4,
                    steps: int = 2000, num_workers: int = 6,
                    base_seed: Optional[int] = None) -> dict:
    """Full pipeline: parallel mine+label, fine-tune, save candidate checkpoint.

    Returns a summary dict (counts, residual stats, paths). The candidate keeps
    the source checkpoint's optimizer state and metadata so a later promotion
    behaves exactly like a normal mid-training checkpoint.
    """
    import multiprocessing as mp

    if base_seed is None:
        base_seed = random.randrange(2 ** 31)
    games_per_worker = max(1, num_games // num_workers)
    top_k_local = max(1, top_k // num_workers)
    jobs = [(w, checkpoint_path, config_path, games_per_worker, sample_every,
             top_k_local, rollouts_per_position, base_seed)
            for w in range(num_workers)]

    t0 = time.perf_counter()
    ctx = mp.get_context("spawn")
    with ctx.Pool(num_workers) as pool:
        results = pool.map(_worker_mine_and_label, jobs)

    labeled_states = np.concatenate([r["labeled_states"] for r in results if len(r["labels"])])
    labels = np.concatenate([r["labels"] for r in results])
    residuals = np.concatenate([r["labeled_residuals"] for r in results])
    v_nets = np.concatenate([r["labeled_v_net"] for r in results])
    anchor_states = np.concatenate([r["anchor_states"] for r in results if len(r["anchor_targets"])])
    anchor_targets = np.concatenate([r["anchor_targets"] for r in results])
    mined_total = sum(r["mined_count"] for r in results)

    # Cache the labeled dataset so fine-tune variants can be re-run without
    # re-mining (~the expensive part).
    dataset_path = os.path.splitext(out_path)[0] + "_dataset.npz"
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    np.savez_compressed(dataset_path, labeled_states=labeled_states, labels=labels,
                        residuals=residuals, v_nets=v_nets,
                        anchor_states=anchor_states, anchor_targets=anchor_targets)

    agent, _ = load_agent_from_checkpoint(checkpoint_path, config)
    fine_tune(agent.board_evaluator, labeled_states, labels, anchor_states,
              anchor_targets, lr=lr, steps=steps, seed=base_seed)

    # Candidate = source payload with only the weights swapped.
    payload = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    payload["state_dict"] = agent.board_evaluator.state_dict()
    torch.save(payload, out_path)

    summary = {
        "candidate_path": out_path,
        "dataset_path": dataset_path,
        "mined": mined_total,
        "labeled": int(len(labels)),
        "anchors": int(len(anchor_targets)),
        "mean_residual_labeled": float(residuals.mean()) if len(residuals) else 0.0,
        "mean_abs_label_shift": float(np.abs(labels - v_nets).mean()) if len(labels) else 0.0,
        "seconds": time.perf_counter() - t0,
        "base_seed": base_seed,
    }
    return summary
