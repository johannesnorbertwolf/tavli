# Training Improvement Ideas

Working list of ideas to push the TD(λ) trained model past its current plateau.
We work through these one at a time. Mark items DONE / RULED OUT as we go.

## Context

- Model plays strongly overall, often beats the user.
- Specific weaknesses: occasional weird endgame play; sometimes mis-evaluates clearly-won midgame positions.
- Already tried (no improvement): bigger network, λ/ε sweeps, 2-ply lookahead training (move selection only — *not* TD-leaf with `V(s_leaf)` as target).
- Already tried (no improvement): **TD-leaf with search-improved value targets**. RULED OUT — so the bottleneck is probably *not* "the bootstrap targets are wrong on average." More likely: optimization noise, data distribution, or representation.

---

## Phase 0 — Diagnostics (do first; cheap; tells us where to spend effort)

### D1. Held-out hand-curated test set
Build ~50 frozen positions where the right answer is known (clear wins / clear losses / tricky endgames / pin-trap setups). Score model on these every eval. Converts "feels weird in endgame" into a number.

**Files**: new `tests/eval/positions/*.json` + a runner that prints per-bucket accuracy.

### D2. Hard-position logging during self-play
Each game, log the top-K plies by `|TD error|` (state + dice + chosen move + score). Build a small dataset of the model's actual blind spots. Useful for (a) human inspection — does it match your intuition? (b) prioritized replay later.

**Files**: hook into `train_one_game` / `_apply_trajectory` to write `training_runs/hard_positions.jsonl`.

### D3. Eval-curve shape inspection
Read `training_runs/eval_gold_history.log`. Plateau-clean vs oscillating tells us optimization-noise vs bootstrap-ceiling. Quick check before committing to interventions.

---

## Phase 1 — Interventions (after diagnostics tell us which to pick)

### I1. Replay buffer + Adam (TOP PICK) — DONE ✓
**Why**: Current update is per-ply, single-sample, no optimizer, no momentum. That's a *lot* of variance for an MLP. If targets are roughly right but updates are noisy → "strong on average, weird on specifics" — matches the symptom.

**Approach**:
1. After each game finishes, compute λ-returns offline for each visited state.
2. Push `(encoded_state, target)` pairs into a ring buffer (~100k).
3. Every K plies (or every game), sample a minibatch, do BCE-loss SGD with Adam.
4. Drop manual eligibility traces entirely.

**Outcome**: Tested with great success. Significantly improved training stability and convergence.

### I2. Monte-Carlo grounding for race endgames — IMPLEMENTED (pending eval)
**Why**: Bear-off positions are near-deterministic functions of pip-count distributions. MLPs are bad at exact arithmetic. TD never gives a clean MC signal here because λ-traces always blend bootstrap. Different mechanism from TD-leaf (#I1 ruled out): uses actual rollouts to terminal, not network re-evaluation.

**Approach**:
- Detect "race" state (no contact possible; both sides home or close).
- For race states, replace TD target with average of N random rollouts to terminal (50–200 rolls).
- Cheap because race rollouts need no decisions worth thinking about.

**Implementation** (settled: 200 rollouts/race state, replace λ-target entirely):
- `Board.is_race()` (`domain/board.py`): no contact possible iff `min(white_points) > max(black_points)` (White travels 1→25, Black 24→0). Pinned blots counted toward their own color.
- `ai/mc_rollouts.py`: `mc_value_estimate(board, mover_color, num_rollouts, dice_sides, rng)` runs uniform-random rollouts to terminal; `maybe_mc_target(...)` returns the estimate only for non-terminal race states (else `None`).
- MC targets are computed inline in the playing loops (`_play_one_game_local`, `self_play_worker.play_one_game_record`) — encoded states can't be rebuilt into boards — and shipped in the trajectory as `mc_targets`. `_ingest_trajectory` overrides each race state's λ-return with its MC target; `compute_lambda_returns` is unchanged. Per-epoch log reports `mc_overrides`.
- Config: `mc_rollouts_per_race_state` (200 in `config.yml`, 5 in `config-test.yml`, 0 disables → exact pre-I2 path). Tests: `tests/domain/test_race_detection.py`, `tests/ai/test_mc_rollouts.py`.
- **Next**: run a full training run, compare eval-gold win rates vs the pre-I2 baseline. Mark DONE if it helps, RULED OUT if not.

**Cheaper variant**: pre-compute a pip-count → win-prob lookup table from many simulated races; use it as the target for race states. **NOT suitable for Plakoto** — exact-roll bearing-off means the checker distribution matters enormously, not just total pip count (e.g. all checkers on point 1 = terrible despite low pip count). Stick with actual rollouts. Note: pip count as a race proxy does not generalise across all Tavli variants — bearing-off rules differ per variant, so any pip-count heuristic must be validated against the specific variant's rules before use.

### I3. Opponent pool / fictitious self-play — RULED OUT
**Why**: Greedy-on-self collapses the position distribution. The net never sees positions that arise against a *different* style of play, so calibration drifts there.

**Approach**:
- Every K games, snapshot weights to a pool (cap pool size, e.g., last 20 snapshots).
- During self-play, with probability p≈0.3, opponent plays with weights sampled from the pool instead of current.
- Gold model checkpoints can seed the pool.

**Ruling**: Gut feel is this doesn't move the needle. Skipping.

### I4. Pin-trap auxiliary head (Plakoto-specific) — RULED OUT
**Why**: Pin-trap is a sharp discontinuity (lone opp checker on its start point pinned = instant win). Sigmoid-on-MLP under-fits sharp cliffs. Auxiliary loss shapes the trunk to encode pin geometry better.

**Approach**:
- Second output head: predict "is the opponent at high pin-trap risk in ≤2 turns?" (cheap-to-label).
- Auxiliary BCE loss added to main value loss with small weight (~0.1).
- Head can be discarded at play time.

**Ruling**: The model does not actually struggle with pin-trap detection. Not a real weakness, so no point addressing it.

### I5. Always-softmax exploration
**Why**: Current ε-greedy with softmax-on-trigger gives bimodal exploration. Smooth always-softmax (temperature annealed) gives graded position diversity. Minor change; might compound with #I3.

### I6. Target network (DQN-style)
**Why**: Compute `V(s′)` with a frozen copy that updates every N games. Reduces moving-target instability — most useful once #I1 is in place (online updates without an optimizer already wash out the benefit).

### I7. Categorical value head
**Why**: Output {loss, normal win, pin-trap win} as 3 logits, cross-entropy loss. Forces representation to separate win modes that have different positional signatures. Light architectural change.

### I8. Prioritized replay from #D2 — RULED OUT
**Why**: Once #D2 is logging hard positions, up-weight those samples in the replay buffer (needs #I1 first). Effectively a hard-example mining loop.

**Ruling**: Tried. No improvement in win rate against gold. Up-weighting high-TD-error positions did not translate into stronger play.

---

## Working order (current progress)

1. ~~**D1 + D2 + D3** — measure first.~~ (skipped in favor of I1)
2. ✓ **I1** (replay buffer + Adam) — DONE. Great success.
3. ~~**I3** (opponent pool) — RULED OUT (gut: won't move needle).~~
4. ~~**I4** (pin-trap aux head) — RULED OUT (model doesn't struggle here).~~
5. ~~**I8** (prioritized replay) — RULED OUT. Tried; no improvement in win rate.~~
6. **I2** (MC grounding for race endgames) — IMPLEMENTED (pending eval). Actual rollouts (200/race state, replace λ-target); pip-count lookup table is NOT suitable for Plakoto because exact-roll bearing-off means distribution matters, not just pip count. Code + unit tests landed; next is a full training run vs the pre-I2 baseline to confirm it helps.

## Ruled out

- TD-leaf with `V(s_leaf)` as target — tried, no improvement.
- Larger network — tried, no improvement (capacity is not the bottleneck).
- λ / ε sweeps — tried, no improvement.
- 2-ply lookahead for move selection during training — tried, no improvement (and slow).
- Prioritized replay (I8) — tried, no improvement in win rate. Up-weighting high-TD-error positions did not translate into stronger play.
