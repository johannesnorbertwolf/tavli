# ai/ — Machine Learning Modules

## agent.py

`Agent` is the inference interface wrapping a `BoardEvaluator` and `BoardEncoder`. It never updates weights.

**1-ply evaluation** (`_evaluate_moves_batch`): For each candidate move, apply it to the board, encode the resulting position from the *opponent's* perspective (since after our move it's their turn), run a batched forward pass, then return `1 - opponent_value` as our score. Winning moves are short-circuited to score 1.0 before the forward pass.

**2-ply evaluation** (`_evaluate_moves_2ply_batch`): Expectimax. For each candidate move, iterate over all 21 distinct dice outcomes (doubles count once with weight 1/36; others weight 2/36). For each outcome, enumerate the opponent's legal responses, encode all resulting positions in one big batch, and compute the opponent's best response value. Our expected score for a candidate move is the weighted average of `1 - opponent_best_value` across all dice outcomes.

**Public API**:
- `get_best_move(board, possible_moves, color, lookahead_plies=1)` → `(best_move, best_score)`
- `evaluate_moves(board, possible_moves, color, lookahead_plies=1)` → `List[float]`

`RandomAgent` is a minimal class with a single `get_move(possible_moves)` method that returns a random choice. Used as the opponent in random-agent evaluations.

The 21 distinct `(d1, d2, weight)` dice outcomes are precomputed once at module load in `_DICE_OUTCOMES`.

---

## board_encoder.py

`BoardEncoder` converts a `Board` into a flat float32 numpy array that always represents the position from the *current player's* perspective. The board is "flipped" so that the encoder sees the same spatial structure regardless of which color is moving.

**Coordinate flip**: when encoding for White, slot indices map directly (0→25). When encoding for Black, slot index `k` in the output corresponds to physical slot `n - 1 - k`. In this flipped view, slot 0 is the opponent's bear-off, slot 25 is our bear-off, our home is slots 19–24, opponent's home is slots 1–6.

**Three encoder versions** (backward-compatible; version tag stored in checkpoint):

| Version constant | `input_size` | Used by |
|---|---|---|
| `LEGACY_V1 = "legacy_unary_v1"` | 494 | gold_v1–v4 |
| `UNARY_V2 = "unary_v2"` | 468 | gold_v5 |
| `UNARY_V3 = "unary_v3"` | 486 | current training |

**Per-point layout (UNARY_V3 / UNARY_V2)** — `point_size = 3 + pieces_per_player` = 18 floats per slot:
- `[0]` color bit: 0 = ours, 1 = theirs
- `[1]` captured_by_us: 1 if our stack pins an opponent checker here
- `[2]` captured_by_them: 1 if their stack pins our checker here
- `[3..3+count-1]` unary count: as many 1s as there are pieces at this slot

**Per-point layout (LEGACY_V1)** — `point_size = 4 + pieces_per_player` = 19 floats:
- `[0]` occupied bit (1 if any piece here)
- `[1]` opponent bit (1 if opponent's pieces)
- `[2]` captured_by_us, `[3]` captured_by_them
- `[4..4+count-1]` unary count

**18 smart features (UNARY_V3 only)**, appended after the raw per-point section:

| Index | Feature | Normalization |
|---|---|---|
| 0–1 | our / their pip count | `/ (pieces_per_player * board_size)` |
| 2–3 | our / their blot count (single unguarded piece) | `/ pieces_per_player` |
| 4–5 | our / their held-point count (≥2 pieces) | `/ pieces_per_player` |
| 6–7 | our / their pinned count (opponent stacked on us) | `/ pieces_per_player` |
| 8–9 | our pieces in our/their home | `/ pieces_per_player` |
| 10–11 | their pieces in their/our home | `/ pieces_per_player` |
| 12–13 | our / their borne-off count | `/ pieces_per_player` |
| 14–15 | our / their max prime length (longest run of held points) | `/ home_size` |
| 16 | pip differential (us − them) | `/ (pieces_per_player * board_size)` |
| 17 | borne-off differential (us − them) | `/ pieces_per_player` |

Smart features are computed in a single pass over the board slots, using running accumulators that reset when the run of held points breaks.

`encode_board(board, is_whites_turn)` is the only public method. Output is pre-allocated (`np.zeros`) with in-place slice writes; typical latency ~18µs for UNARY_V3.

---

## board_evaluator.py

`BoardEvaluator(input_size, hidden_sizes)` is a simple feed-forward neural network (MLP) that outputs a single win-probability scalar in [0, 1].

**Architecture**: fully-connected layers with ReLU activations on all hidden layers, no activation on the output layer. Layers are stored in `self.layers` as an `nn.ModuleList`. The final layer has output size 1.

Construction: `sizes = [input_size] + hidden_sizes + [1]`; one `nn.Linear(sizes[i], sizes[i+1])` per adjacent pair.

**Two forward methods**:
- `forward(x)` → sigmoid probabilities; used by `Agent` at inference time.
- `forward_logits(x)` → raw pre-sigmoid logits; used by the training loop with `F.binary_cross_entropy_with_logits` for numerical stability (avoids sigmoid-then-log rounding).

`self.hidden_sizes` is stored as a plain list on the instance so checkpointing can save and restore the architecture.

---

## checkpoint_io.py

Handles saving and loading model checkpoints. The canonical entry point for loading is `load_agent_from_checkpoint(path, config, device)` which returns a ready-to-use `(Agent, meta)` pair — never construct an `Agent` manually from a checkpoint.

**Checkpoint format (format_version=2)**: a dict saved by `torch.save` containing:
- `state_dict`: network weights
- `network_type`: always `"mlp"` currently
- `encoder_version`: one of the three version strings from `board_encoder.py`
- `hidden_sizes`: list of ints
- `board_spec`: `{board_size, pieces_per_player, home_size}` from config
- `optimizer_state_dict`: Adam optimizer state (None for format_version=1)
- `format_version`: int (1 = no optimizer state, 2 = with optimizer state)

**Legacy plain state_dict** (format_version=1 or pre-format): just the `state_dict` tensor dict with no wrapper. Detected by the absence of a `"state_dict"` key.

**Legacy layer name migration** (`_migrate_state_dict`): old checkpoints used `fc1.weight/bias` … `fc4.weight/bias`; new code uses `layers.0.weight/bias` … `layers.3.weight/bias`. Migration happens automatically on every load if any key starts with `"fc"`.

**`save_checkpoint(path, evaluator, config, optimizer=None)`**: saves format_version=2 always. Optimizer state is included if `optimizer` is provided.

**`load_state_dict(path, device)`**: lower-level function that returns `(migrated_state_dict, meta_dict)`. Used internally and by the training loop to load optimizer state without constructing a full Agent.

---

## mc_rollouts.py

Monte-Carlo value estimation for **race endgames** (improvement idea I2). In a race (`Board.is_race()`) no contact is possible, so the position's value is a near-deterministic function of the checker distribution that the sigmoid-MLP estimates poorly. Instead of the TD bootstrap target, the self-play paths substitute an empirical win probability from random rollouts.

**`mc_value_estimate(board, mover_color, num_rollouts, dice_sides=6, rng=None)`** → float in [0,1]. Runs `num_rollouts` independent rollouts: clone the board, then alternate colors (starting with `mover_color`) playing **uniformly random** legal moves until someone wins, and return the fraction won by `mover_color`. The result is a win probability from `mover_color`'s perspective — exactly the target convention `compute_lambda_returns` uses, so it can be dropped into `targets` directly. Each rollout is capped at `_MAX_PLIES_PER_ROLLOUT = 500` plies as a safety net (race rollouts terminate far sooner). `rng` (a `random.Random`) drives both dice and move choice; pass a seeded instance for determinism, or `None` to use the global `random` module (caller seeds it). Returns 0.5 if `num_rollouts <= 0`.

**`maybe_mc_target(board, mover_color, num_rollouts, dice_sides=6, rng=None)`** → `Optional[float]`. Wrapper used by the self-play loops: returns `None` (no override) if rollouts are disabled (`num_rollouts <= 0`), the position is already terminal (so the existing post-terminal target=0 convention stands), or the position is not a race; otherwise returns `mc_value_estimate(...)`. This keeps the race/rollout cost out of the contact phase entirely.

---

## td_lambda_training.py

Contains the training loop (`TdLambdaTraining`), the replay buffer (`ReplayBuffer`), and the λ-return computation (`compute_lambda_returns`).

### ReplayBuffer

Ring buffer of `(encoded_state, target)` pairs stored in pre-allocated numpy arrays of shape `(capacity, state_dim)` and `(capacity,)`. Writes via `push(state, target)` or `push_many(states, targets)` advance a cursor modulo capacity. `sample(batch_size)` returns uniformly random rows. `len(buffer)` is the number of valid entries (saturates at capacity). Not persisted across restarts.

### compute_lambda_returns

Pure function, no side effects. Takes:
- `values`: shape `(T+1,)` — bootstrap win-probability estimates from the network for all states in the trajectory
- `movers`: shape `(T,)` bool — True if White moved at step i
- `terminal_winner_white`: who won
- `lambda_`: TD(λ) decay

Returns `targets` of shape `(T+1,)`. For each non-terminal state `i`, computes the forward-view λ-return from mover_i's perspective:

```
G^λ_i = (1−λ) · Σ_{n=1..N-1} λ^{n-1} · G^(n)_i  +  λ^{N-1} · G^(N)_i
```

where `G^(n)_i = U(i+n, mover_i)`: the bootstrap value at step `i+n` converted to mover_i's perspective. `U(j, mover_i) = V[j]` if `mover_j == mover_i`, else `1 - V[j]`. For the terminal step `G^(N)_i = 1` if mover_i won, else `0`. The post-terminal state (index T) gets target 0 (the loser's perspective).

### TdLambdaTraining

The main orchestrator. Constructed with `(board_evaluator, board_encoder, config)`.

**Init**: reads all knobs from config, constructs `ReplayBuffer` and `Adam` optimizer, then calls `_try_load_optimizer_state()` (loads Adam state from `trained_model.pth`), `_load_training_state()` (loads `training_state.json` for game count, epsilon, lambda, optimizer step count), and `_try_load_gold_agent()`.

**Per-game training cycle** (`train_one_game` or via parallel workers):
1. Play one full self-play game to a real terminal (`_play_one_game_local` or worker), collecting trajectory `{states[T+1], movers[T], mc_targets[T+1], terminal_winner_white, plies, game_seconds}`. Weights do not change mid-game. `mc_targets` is computed during play (where the live `Board` exists) via `maybe_mc_target`: a float per race state, `None` otherwise.
2. `_ingest_trajectory`: forward-pass all `T+1` states once (eval mode, no_grad) to get bootstrap values, compute λ-returns via `compute_lambda_returns`, **then override each race state's target with its precomputed MC estimate** (`mc_targets[i]` when non-None), and push all `(state, target)` pairs into the replay buffer. Returns a per-game `mc_overrides` count (number of targets replaced), aggregated into the per-epoch log line.
3. `_train_minibatches`: run `updates_per_game` Adam steps on randomly sampled minibatches from the replay buffer using `binary_cross_entropy_with_logits`.

**MC race grounding (I2)**: `mc_rollouts_per_race_state` (config; 0 disables) controls the rollout budget. The encoded states in a trajectory can't be turned back into boards, so the MC targets are computed inline in the playing loops (`_play_one_game_local` and `self_play_worker.play_one_game_record`) and shipped in the trajectory. `compute_lambda_returns` is left untouched — the override happens only in `_ingest_trajectory`, so disabling rollouts reproduces the pre-I2 code path exactly.

**Exploration**: `_select_move_self_play` applies ε-softmax: with probability `1 - ε` pick the greedy best move; with probability `ε` sample from a softmax over scores divided by `exploration_temperature`.

**Schedule updates** (called after every game): epsilon decays linearly toward `epsilon_end` over `epsilon_decay_games` games. Lambda decays exponentially toward `lambda_end` over `lambda_decay_games` games.

**LR warmup**: `_current_lr()` implements linear warmup from `0.1·lr` to `lr` over `lr_warmup_steps` optimizer steps. Applied by `_set_lr()` before each Adam step.

**Gradient clipping**: if `max_grad_norm > 0`, the global L2 norm of all gradients is clipped to `max_grad_norm` before the Adam step.

**Serialisation**: `_save_training_state()` atomically writes `training_state.json` (tmp + rename). `save_checkpoint` in `checkpoint_io.py` handles the model.

**Eval** (`_run_eval`): optionally evaluates vs. random agent and/or vs. gold model. Uses a seeded RNG isolated from training RNG. Appends results to `training_runs/eval_gold_history.log`.

**Parallel training** (`_run_training_loop_parallel`): spawns `num_self_play_workers` processes via `multiprocessing.spawn`. Each worker gets its own weight queue and pushes trajectories to a shared result queue. After ingesting a trajectory, the trainer immediately sends updated weights back to the worker that produced it (pipelining: workers play ahead of the trainer by one game, incurring a small off-policy lag).

---

## self_play_worker.py

Runs inside a worker subprocess spawned by the parallel training loop.

`worker_main(worker_id, weight_q, traj_q, config_path, hidden_sizes, base_seed)`: entry point. Constructs its own `BoardEncoder`, `BoardEvaluator`, and `Agent` (seeded deterministically from `base_seed + worker_id * 9176 + 7`). Loops: read `(weights, epsilon, exploration_temperature)` from `weight_q`, load weights into the evaluator via `load_state_dict`, call `play_one_game_record`, push `(worker_id, trajectory)` to `traj_q`. Stops on a `None` message.

`play_one_game_record(agent, encoder, config, epsilon, exploration_temperature)`: plays one full self-play game. At each step: roll dice, get legal moves, call `_select_self_play_move`, apply move, record `(is_white_to_move, encoded_board_after)`. Also records `mc_targets` (one entry per state) via `maybe_mc_target` using `config.get_mc_rollouts_per_race_state()` and `config.get_die_sides()`, so race-state MC targets are computed inside the worker. Returns trajectory dict including `mc_targets`.

`_select_self_play_move`: ε-softmax over `agent.evaluate_moves` scores. With probability `1 - ε` greedy; with probability `ε` sample from softmax at temperature `exploration_temperature`.

Workers always run in `eval()` mode (no gradient tracking). `torch.set_num_threads(1)` prevents thread contention between workers.

---

## evaluator.py

`AIEvaluator` is an older evaluation helper that runs the trained agent (as White) against a `RandomAgent` (as Black) for a fixed number of games and reports win percentage. It is not used by the main training loop; the main loop calls `TdLambdaTraining._evaluate_against_random` directly. This file may be vestigial.
