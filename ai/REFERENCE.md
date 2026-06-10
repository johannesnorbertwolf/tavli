# ai/ — module reference

Reimplementation-grade detail for the machine-learning modules. The directory
`CLAUDE.md` carries the one-line index and conventions; this file holds the deep
detail. Read it when implementing or modifying anything under `ai/`.

## agent.py

`Agent` is the inference interface wrapping a `BoardEvaluator` and `BoardEncoder`. It never updates weights.

**1-ply evaluation** (`_evaluate_moves_batch`): For each candidate move, apply it to the board, encode the resulting position from the *opponent's* perspective (since after our move it's their turn), run a batched forward pass, then return `1 - opponent_value` as our score. Winning moves are short-circuited to score 1.0 before the forward pass.

**Exact-race leaves** (`_exact_value`, used by all three search depths): when the `Agent` was constructed with a `bearoff` DB, every position that would be sent to the net is first probed with `ai.bearoff.exact_value_on_roll` from the same perspective the encoder would use; exact races get DB equity instead of a net call (in 2-ply this is done via a placeholder-and-scatter pass so the remaining net evals still run as one batch; in N-ply it also short-circuits pass-positions). `bearoff` is optional — without it behavior is unchanged.

**2-ply evaluation** (`_evaluate_moves_2ply_batch`): Expectimax. For each candidate move, iterate over all 21 distinct dice outcomes (doubles count once with weight 1/36; others weight 2/36). For each outcome, enumerate the opponent's legal responses, encode all resulting positions in one big batch, and compute the opponent's best response value. Our expected score for a candidate move is the weighted average of `1 - opponent_best_value` across all dice outcomes.

**N-ply evaluation with branch pruning** (`_evaluate_moves_nply`): Recursive expectimax generalising to arbitrary depth. At depth=1 it delegates to `_evaluate_moves_batch`. At depth>1, for each candidate move it iterates all 21 dice outcomes; for each outcome it calls `_evaluate_moves_batch` on all opponent replies as a quick 1-ply pre-screen, then prunes the replies via `_prune_branches` (see below) and recurses at depth-1 on the survivors. Pass-positions (no opponent moves) are collected and resolved in a single deferred batch. The per-candidate body is wrapped in `try/finally` so the applied move is always undone — even when `_TimeoutError` unwinds the recursion from a deeper frame mid-iteration (without this, enclosing frames would leak their applied moves and corrupt the board). Raises the module-private `_TimeoutError` if a `deadline` (monotonic timestamp) is exceeded — callers catch this to discard partial results.

**Branch pruning** (`_prune_branches`, static helper): given `(moves, scores)`, keeps the strongest moves and returns their indices best-first. When `relative_cutoff` is set, keeps moves with `score >= best * (1 - relative_cutoff)` (a *relative*, scale-aware cut — tight when the best move is near-certain, looser in balanced positions); otherwise falls back to the absolute `beam_threshold` (`score >= best - beam_threshold`). Survivors are then capped to `max_branch`, always keeping at least one. This is what bounds the otherwise-explosive search width — the 21×21 dice chance-nodes are *not* pruned (the dice distribution stays exact), so the move cap is the only width limiter. Defaults (`search_relative_cutoff=0.08`, `search_max_branch=5`) keep ~3.5 moves per node on average.

**Iterative deepening** (`get_best_move` with `time_budget_s`): When `time_budget_s` is provided, performs iterative deepening: depth-1 scores are computed for all root moves unconditionally, then the loop deepens while the deadline has not expired *and* `depth <= max_depth`. At each iteration the root moves are pruned via `_prune_branches` and only those are re-scored; the rest retain their previous-depth score. If `_TimeoutError` is raised mid-depth, partial results are discarded and the result from the last fully completed depth is returned. When `time_budget_s` is `None` (default), the fixed-depth path (`lookahead_plies`: 1 or 2) is used unchanged.

`max_depth` (default config `search_max_depth=3`) caps the deepening: depth 4+ is never *completed* within a sane budget (full depth-3 expectimax already costs several seconds per move and grows in the mid/endgame, since many near-equal moves defeat the relative cutoff), so attempting it would just burn the whole budget and time out. Capping at depth 3 means each move costs the depth-3 *completion* time rather than the full `time_budget_s`. The budget then acts as a safety ceiling for the rare expensive position.

**Search instrumentation**: `self.last_search_depth` records the depth actually reached by the most recent `get_best_move` call (the last *fully completed* depth in the time-budget path; the effective `lookahead_plies` in the fixed path; 0 for an empty move list, 1 for the single-move fast path). The validation harness reads this to report how deep the search got.

**Public API**:
- `get_best_move(board, possible_moves, color, lookahead_plies=1, time_budget_s=None, beam_threshold=0.08, relative_cutoff=None, max_branch=None, max_depth=None)` → `(best_move, best_score)`
- `evaluate_moves(board, possible_moves, color, lookahead_plies=1)` → `List[float]`

`RandomAgent` is a minimal class with a single `get_move(possible_moves)` method that returns a random choice. Used as the opponent in random-agent evaluations.

The 21 distinct `(d1, d2, weight)` dice outcomes are precomputed once at module load in `_DICE_OUTCOMES`. The module-private `_TimeoutError` exception is used internally to unwind the recursion stack when a deadline expires.

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

Handles saving and loading model checkpoints. The canonical entry point for loading is `load_agent_from_checkpoint(path, config, device)` which returns a ready-to-use `(Agent, meta)` pair — never construct an `Agent` manually from a checkpoint. When `use_bearoff_db` is true in config, it also attaches the bear-off DB to the returned `Agent`, so standalone consumers (eval-gold, play, lookahead-eval) get exact race play for free.

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

## bearoff.py

Exact equity for pure-race positions. Once a Plakoto position has **no pinned checkers anywhere and every stack inside its owner's home quadrant**, no future contact is possible and the game is an exactly solvable race — the net's estimate can be replaced with ground truth.

**One-sided database** (`BearoffDB`): a state is a count-tuple `(c_1..c_6)` — `c_d` checkers at distance `d` from the bear-off slot, `sum ≤ 15` — giving C(21,6) = 54,264 states (the same DB serves both colors; distances are color-agnostic). For each state, `pmf[row]` holds the exact probability distribution of the number of rolls needed to bear everything off under **roll-minimizing play** (the standard one-sided approximation; truly equity-optimal play can depend on the opponent, but the error is negligible).

**Build algorithm** (`BearoffDB.build`): states are processed in increasing-pip order, so every non-pass successor is already solved. For each state and each of the 21 weighted dice outcomes, move enumeration is **delegated to `domain.move_generation.legal_moves` on a synthetic one-sided board** (Black checkers on points 1..6, bear-off slot 0) — this guarantees the DB replicates the engine's exact rules, including *exact-die bear-off*, which means a race can stall on pass rolls. The chosen successor is the one minimizing exact expected rolls (`exp_rolls`, computed untruncated via `E = (1 + Σ w_r·E_succ) / (1 − p_pass)`). Pass rolls keep the state unchanged and are folded in closed form: `P(s,n) = base[n] + p_pass·P(s,n−1)`. The pmf is truncated at `N_MAX = 128` rolls (exact-die bear-off makes the worst states very slow — 15 checkers at distance 1 average ≈39 rolls with a geometric pass tail); the build raises if total truncated mass exceeds 1e-6. Build takes a few minutes; the result is cached as compressed npz (`models/bearoff_db.npz` by default, `format_version=1`) and `load_or_build()` loads the cache when present. **The trainer builds the DB eagerly before spawning workers** so the (non-atomic) cache write happens exactly once.

**Two-sided win probability** (`win_prob_on_roll(me, opp)`): exact P(player on roll wins) = `Σ_{n≥1} pmf_me[n] · (1 − cdf_opp[n−1])` — I win iff I finish on my n-th roll and the opponent still needs ≥ n. Terminal edges short-circuit (`sum(me)==0` → 1.0, `sum(opp)==0` → 0.0).

**Race detector** (`race_state(board)`): single pass over points 1..board_size; returns `(white_counts, black_counts)` by distance, or `None` if any checker is pinned or outside its owner's home. White's distance at point `i` is `board_size+1−i`, Black's is `i`.

**Value hook** (`exact_value_on_roll(board, persp_is_white, db)`): returns the exact win probability of the perspective player *assuming they are on roll* — deliberately the same quantity the value net answers for an encoded position — or `None` outside exact races (or when `db is None`). All integration points (agent leaf evals, TD targets) call this and fall back to the net on `None`.

Config knobs: `use_bearoff_db` (default true) and `bearoff_db_path` (default `models/bearoff_db.npz`). `config-test.yml` disables it to keep tests fast.

---

## rollout_lab.py

Offline improvement pass (issue #80) targeting compute at positions where the net is most likely wrong. Three phases, orchestrated by `run_rollout_lab()` and exposed as `./run.sh rollout-lab` / `python main.py rollout-lab`:

1. **Mine** (`mine_games`): greedy 1-ply self-play games with the current checkpoint. Every `sample_every`-th non-race pre-roll state gets two values: `V_net(s)` (static net eval, mover perspective) and `V_search(s)` (`state_search_value`: expectation over the 21 weighted dice outcomes of the best 1-ply move score, exact bear-off equity at race leaves; a pass roll contributes `1 − V(board, opponent)`). The residual `|V_search − V_net|` measures the net's self-inconsistency — a TD-error magnitude under the net's own policy. Pure-race states are skipped (they already train on exact targets).
2. **Label** (`label_positions` / `rollout_value`): two modes. `rollout` (default): the top-`top_k` residual states are labeled by `rollouts_per_position` Monte-Carlo playouts under the greedy 1-ply policy (both sides). A playout returns as soon as the position becomes an exact race — the bear-off DB equity stands in for the rest of the game — or a side wins; a `max_plies` guard (default 1000) falls back to the net value. Labels are mean returns from the mover's perspective. Rollouts run on `board.clone()`; the mined board is never mutated. `search2` (`--label search2`): deterministic depth-2 expectimax state value (`state_search_value(move_plies=2)`) — a TreeStrap-style policy-*improvement* label, useful once 1-ply-policy rollouts stop disagreeing with the net (~2 s/position; rollout count is ignored).
3. **Fine-tune** (`fine_tune`): Adam + BCE-with-logits on the labeled set at small LR (default 1e-4, 2000 steps). Each minibatch is half labeled positions, half **anchors** — the non-top mined states pinned to their own pre-fine-tune net values — so the net only moves where rollouts disagree with it (a cheap trust region against catastrophic forgetting). Sets `.train()` for the duration and restores `.eval()` in a `finally`.

Parallelism: `run_rollout_lab` splits mining+labeling across `num_workers` spawn-context processes (`_worker_mine_and_label`); each worker loads its own agent from the checkpoint, keeps its local top `top_k/num_workers` (approximate global top-k), and returns flat numpy arrays — `Board` objects never cross the process boundary. The labeled dataset is cached next to the candidate (`*_dataset.npz`) so fine-tune variants can re-run without re-mining.

The candidate checkpoint is the **source payload with only `state_dict` swapped** — optimizer state and metadata are preserved so a promoted candidate resumes TD training like any mid-run checkpoint. Promotion is gated in `main.py`: head-to-head vs the source checkpoint (`evaluate_against_gold`, `--gate-games` per color); the candidate is only promoted (with `--apply`, after a one-sided z-test at p < 0.05) and the source is backed up first.

CLI knobs: `--games 600 --top 4000 --rollouts 64 --steps 2000 --lr 1e-4 --workers 6 --gate-games 2000 --label rollout|search2 --checkpoint trained_model.pth --out models/rollout_candidate.pth --apply`.

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

**Init**: reads all knobs from config, constructs `ReplayBuffer` and `Adam` optimizer, then calls `_try_load_optimizer_state()` (loads Adam state from `trained_model.pth`), `_load_training_state()` (loads `training_state.json` for game count, epsilon, lambda, optimizer step count), and `_try_load_gold_agent()`. When `use_bearoff_db` is true, the bear-off DB is built/loaded **eagerly here, before any workers are spawned**, so workers only ever read the disk cache; the trainer's own agent and the gold agent both get it.

**Per-game training cycle** (`train_one_game` or via parallel workers):
1. Play one full self-play game to a real terminal (`_play_one_game_local` or worker), collecting trajectory `{states[T+1], movers[T], exact_values[T+1], terminal_winner_white, plies, game_seconds}`. Weights do not change mid-game. `exact_values` carries the bear-off DB equity for exact-race states (NaN elsewhere), computed at play time so ingest never has to decode boards from encodings.
2. `_ingest_trajectory`: forward-pass all `T+1` states once (eval mode, no_grad) to get bootstrap values; where `exact_values` is non-NaN, **overwrite the bootstrap value with the exact equity** (λ-returns then bootstrap on ground truth, propagating it backward into contact play); compute λ-returns via `compute_lambda_returns`; finally pin the targets of the exact-race states themselves to their exact values; push all `(state, target)` pairs into the replay buffer. Trajectories without an `exact_values` key (or with `use_bearoff_db: false`) train exactly as before.
3. `_train_minibatches`: run `updates_per_game` Adam steps on randomly sampled minibatches from the replay buffer using `binary_cross_entropy_with_logits`.

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

`worker_main(worker_id, weight_q, traj_q, config_path, hidden_sizes, base_seed)`: entry point. Constructs its own `BoardEncoder`, `BoardEvaluator`, bear-off DB (cache load only — the trainer builds it before spawning), and `Agent` (seeded deterministically from `base_seed + worker_id * 9176 + 7`). Loops: read `(weights, epsilon, exploration_temperature)` from `weight_q`, load weights into the evaluator via `load_state_dict`, call `play_one_game_record`, push `(worker_id, trajectory)` to `traj_q`. Stops on a `None` message.

`play_one_game_record(agent, encoder, config, epsilon, exploration_temperature)`: plays one full self-play game. At each step: roll dice, get legal moves, call `_select_self_play_move`, apply move, record `(is_white_to_move, encoded_board_after)` plus the position's exact race equity (`exact_values`, NaN outside exact races or without a DB). Returns trajectory dict.

`_select_self_play_move`: ε-softmax over `agent.evaluate_moves` scores. With probability `1 - ε` greedy; with probability `ε` sample from softmax at temperature `exploration_temperature`.

Workers always run in `eval()` mode (no gradient tracking). `torch.set_num_threads(1)` prevents thread contention between workers.

---

## evaluator.py

`AIEvaluator` is an older evaluation helper that runs the trained agent (as White) against a `RandomAgent` (as Black) for a fixed number of games and reports win percentage. It is not used by the main training loop; the main loop calls `TdLambdaTraining._evaluate_against_random` directly. This file may be vestigial.

---

## lookahead_eval.py

Parallel validation harness that pits one checkpoint (the gold model) against *itself*, with one side using the time-budget iterative-deepening search and the other fixed 2-ply, to measure whether the deeper search actually wins. Invoked via `python main.py eval-lookahead [total_games] [--workers N]` (or `./run.sh eval-lookahead [total_games]`). The CLI `total_games` argument (default 1000) is split evenly between the two color assignments — i.e. `games_per_color = total_games // 2`.

Both arms share the *same* weights, so each worker loads the checkpoint once and simply calls `get_best_move` two different ways: the **flexible arm** with `time_budget_s` / `relative_cutoff` / `max_branch` (knobs from config), the **2-ply arm** with `lookahead_plies=2`. Which color is the flexible arm alternates between the two halves of the run (`games_per_color` games each) to remove first-move bias.

`evaluate_lookahead_selfplay(config, model_path, games_per_color, num_workers)` builds the full task list of `(flex_color, seed)` games, round-robins them into per-worker chunks, and runs each chunk in a `multiprocessing` *spawn* `Process`. Unlike training there is no weight queue (the model is static). Each worker sets `torch.set_num_threads(1)`, plays its games via `_play_one_game`, and **streams one result per game** (`{win, depth_hist, move_times}`) back through a shared `result_q`. The parent consumes results as they arrive and, every ~1% of the run, prints a live ASCII progress block (`_render_progress`): running win rate with a bar (`_bar`), the depth histogram so far, and an ETA (`_fmt_dur`) derived from wall-elapsed/games-done. This matters because a full run takes hours — the streaming output lets you watch it converge. The final summary adds the Wilson 95% CI, a two-sided binomial p-value vs 0.5 (`_wilson_interval`, `_two_sided_binomial_p`), the full depth histogram (the "how far did it actually look" answer), and avg/median/min/max flexible move time.

Because each flexible move runs the depth-capped search (~5–6s at the default knobs) and a game has ~46 flexible moves, a game takes ~4 min; a full `total_games=1000` run is ~12 hours even on 6 workers — start it yourself rather than expecting it to finish inline.
