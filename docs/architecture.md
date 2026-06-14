# Architecture reference

Deep architecture detail for the TD(λ) self-play training system. The root
`CLAUDE.md` carries the quick map and commands; this file holds the
reimplementation-grade detail. Read it when working on training, encoding,
checkpoints, eval, or the tournament system.

## Training loop (`ai/td_lambda_training.py`)

Forward-view TD(λ) with a replay buffer and Adam. Per completed game (parallel worker or local):
1. Worker (or `_play_one_game_local`) plays one full game greedy-with-ε exploration and emits a trajectory dict: `{states[T+1], movers[T], exact_values[T+1], terminal_winner_white}`. Weights do not change mid-game. `exact_values` holds the exact bear-off DB equity for pure-race states (NaN elsewhere; see `ai/bearoff.py` and the `use_bearoff_db` knob).
2. `_ingest_trajectory` forward-passes all `T+1` states once to get bootstrap values `V[0..T]`, overwrites `V[j]` with the exact equity wherever `exact_values[j]` is non-NaN (λ-returns then bootstrap on ground truth), then computes offline λ-returns from each mover's perspective (`compute_lambda_returns`) and pins exact-race states' targets to their exact values. The post-terminal state's target is 0 (mover_T is the loser).
3. All `T+1` `(encoded_state, target)` pairs are pushed into a `ReplayBuffer` (capacity ~50k, ring buffer, uniform sampling).
4. `_train_minibatches` runs `updates_per_game` Adam steps of `binary_cross_entropy_with_logits(forward_logits, target)`. Optional linear LR warmup `0.1·lr → lr` over `lr_warmup_steps` optimizer steps. `max_grad_norm` clips the gradient L2 norm pre-Adam (not the eligibility trace as the old code did).

Perspective helper: from mover_i's view, `U(j, i) = V[j]` if `mover_j == mover_i` else `1 - V[j]`. λ-return at state i with `N = T - i`:
`G^λ_i = (1-λ) · Σ_{n=1..N-1} λ^{n-1}·G^{(n)}_i + λ^{N-1}·G^{(N)}_i`
with `G^{(n)}_i = U(i+n, i)` if `i+n < T`, else `1` if mover_i won else `0`.

The replay buffer is not persisted across restarts (refills naturally). Adam optimizer state IS persisted inside `trained_model.pth` alongside `state_dict` (format_version=2; old checkpoints without optimizer state load fine and Adam starts fresh).

The training loop owns `.eval()` / `.train()` mode — `Agent` methods are mode-agnostic.

## Perspective-invariant encoding (`ai/board_encoder.py`)

The network always sees the board "from its own side". For the current player's turn we iterate board points forward (0→25); for the opponent we iterate in reverse (25→0) — this is the board flip. The same physical position encodes identically regardless of which color is "current player", so the network needs no separate white/black representations.

In flipped coordinates, slot 0 is opponent's bear-off, slot 25 is our bear-off, our home is slots 19–24, opp home is slots 1–6.

Three encoder versions exist (each behind a checkpoint metadata tag):

| Version | Per-point | Smart features | Input size | Used by |
|---|---|---|---|---|
| `legacy_unary_v1` | 2 color + 2 captured + 15 unary count | — | 494 | gold_v1–v4 |
| `unary_v2` | 1 color + 2 captured + 15 unary count | — | 468 | gold_v5 |
| `unary_v3` (current) | same as v2 | 18 hand-crafted globals | 486 | new training |

The 18 `unary_v3` smart features (Tesauro-style) are folded into the same per-point loop and appended to the raw vector: pip count (us/them), blots, held points, pinned/pinning, home counts (4 quadrants), borne-off, max prime length, plus pip and borne-off differentials. All are normalized to roughly [0, 1].

The encoder uses pre-allocated `np.zeros(..., dtype=float32)` with slice writes per point. Mid-game encode is ~18µs (v3) vs ~30µs for the original list-extension implementation.

## Checkpoint backward compatibility (`ai/checkpoint_io.py`)

Checkpoints store `encoder_version`, `hidden_sizes`, and `network_type`. Two things to know:

- All three encoder versions above are still loadable; gold_v1–v4 stay at `legacy_unary_v1` and gold_v5 at `unary_v2`. New checkpoints are saved as `unary_v3`.
- **Legacy layer names**: old checkpoints use `fc1/fc2/fc3/fc4`; `_migrate_state_dict()` remaps these to `layers.0/1/2/3` on load automatically.

When constructing a `BoardEvaluator` for a loaded checkpoint, always derive `input_size` from a `BoardEncoder` built with the checkpoint's `encoder_version`, and pass `hidden_sizes` from the checkpoint metadata. `load_agent_from_checkpoint()` handles this correctly — use it rather than constructing evaluator/encoder manually.

When bumping encoder version mid-project, training cannot resume from an old `trained_model.pth` (input dimension mismatch); `main.py` catches the load error and starts fresh. Delete `trained_model.pth` and `training_state.json` to start a clean run.

Future encoder optimization ideas (GPU fixed-features layer, incremental caching on `Board`) are documented in `docs/encoder_optimization_ideas.md`.

## Network (`ai/board_evaluator.py`)

`BoardEvaluator(input_size, hidden_sizes)` builds a simple MLP with ReLU hidden layers and sigmoid output (win probability ∈ [0,1]). Hidden sizes are configurable via `config.yml` (`hidden_sizes: [128, 64]` default). Layers stored in `nn.ModuleList` as `self.layers`. Two forwards: `forward(x)` returns sigmoid probabilities (used by `Agent` / eval); `forward_logits(x)` returns pre-sigmoid logits (used by the training loop with `binary_cross_entropy_with_logits` for numerical stability).

## Key config knobs

| Key | Effect |
|---|---|
| `discount_factor` | γ — use `1.0` for terminal-reward games |
| `lambda_start/end` | TD(λ) — forward-view weighting of n-step returns |
| `bootstrap_depth` | 1 = bootstrap λ-returns on the raw net value (default). 2 (E14) = bootstrap on a one-ply expectimax backup of the net (averaged over the 21 dice via `Agent.position_value_lookahead`, threaded through the trajectory as `bootstrap_values`); exact-race values still take precedence. ~17× slower self-play |
| `epsilon_start/end/decay` | Exploration schedule |
| `max_grad_norm` | Global L2 clip on gradients pre-Adam (0 = off) |
| `hidden_sizes` | Network width list, e.g. `[128, 64]` |
| `learning_rate` | Adam lr |
| `lr_warmup_steps` | Linear warmup `0.1·lr → lr` over this many optimizer steps (0 = off) |
| `replay_buffer_capacity` | Sample capacity of replay buffer |
| `minibatch_size` | SGD minibatch size |
| `updates_per_game` | Adam steps run per ingested trajectory |
| `min_buffer_to_train` | Don't start training until buffer holds this many samples |
| `model_save_every_epochs` | Periodic mid-run checkpoint saves |
| `selfplay_2ply_margin` | Self-play decisions whose 1-ply runner-up is within this absolute margin of the best are re-scored at 2-ply (top candidates only); 0 disables. Targeted policy improvement (#90) |
| `selfplay_2ply_max_moves` | Max candidates re-scored at 2-ply on escalation |
| `selfplay_seeded_fraction` | Fraction of self-play games started from a sampled seed-pool position instead of the initial board (#83); 0 disables. Trainer fails fast if the pool file is missing |
| `selfplay_seed_pool_path` | npz pool of high-residual pre-roll positions, built offline via `python main.py seed-pool` (gitignored) |
| `selfplay_league_fraction` | Fraction of self-play games with one randomly-chosen side played by a frozen opponent from `selfplay_league_opponents` (1-ply greedy, no exploration); 0 disables. Diversifies the data distribution (#83) |
| `selfplay_league_opponents` | List of opponent checkpoint paths, sampled uniformly per league game (any encoder version — each loads its own agent) |
| `aux_heads` | Auxiliary output heads (#106): 0 = off; 2 adds [P(game ends by pinning), final borne-off margin] as side targets sharing the trunk. Training-only — eval/play/Core ML use the main head; old checkpoints load with the head initialized fresh |
| `aux_loss_weight` | Weight of the aux BCE term added to the main value loss |
| `model_save_path` | Live checkpoint path (default `trained_model.pth`); training resumes weights + Adam state from it. `config-test.yml` points it at a test-local file so tests never touch live artifacts |
| `gold_model_path` | Reference model for eval |
| `use_bearoff_db` | Exact race equity from the bear-off DB (`ai/bearoff.py`): replaces net evals at search leaves and TD bootstrap values/targets for pure-race states (no pins, all checkers home). `false` in `config-test.yml` to keep tests fast |
| `bearoff_db_path` | Disk cache of the one-sided bear-off DB (npz, ~54k states, built once in ~1 min, gitignored) |
| `play_time_budget_s` | Max wall-clock budget per AI move during play / `eval-lookahead` (safety ceiling; usually finishes earlier via `search_max_depth`) |
| `search_relative_cutoff` | Move-pruning width: keep moves with `score >= best*(1-cutoff)` at each search node |
| `search_max_branch` | Hard cap on moves expanded per search node, applied on top of `search_relative_cutoff` |
| `search_max_depth` | Stop iterative deepening at this depth (depth 4+ is unreachable in budget) |

The `alpha`, `alpha_decay`, `alpha_decay_every`, `alpha_min` keys are deprecated (left readable for old `training_state.json` resumes) and ignored by the Adam path.

## Eval and logging

Each eval run appends one line to `training_runs/eval_gold_history.log`:
```
2026-05-01 17:00:58 epoch=100 games_per_color=100 white=0.04 black=0.02 avg=0.03
```

`local_tools/` contains SVG graph generators and a file-watch daemon for live dashboards during training.

## Tournament system (`tournaments/`)

Round-robin tournament framework for evaluating all gold models against each other. Runs N independent tournaments, each with 9 models playing every other model in 2 games (once as WHITE, once as BLACK). Parallelized across workers.

**Key modules**:
- `tournament_engine.py`: Plays one round-robin tournament; reuses existing `Game`, `Agent.get_best_move()`, `legal_moves()`
- `tournament_runner.py`: Orchestrates N parallel tournaments; auto-discovers gold models from `models/gold_v*.pth`; handles seeding for reproducibility
- `tournament_aggregator.py`: Computes statistics (win rates, ELO, confidence intervals, head-to-head records, placement frequency)
- `tournament_reporter.py`: Generates HTML visualizations (summary table, ELO evolution chart, placement frequency heatmap, head-to-head matrix)
- `tournament_cli.py`: CLI entry point; argument parsing and report generation
- `monitor.py`: Live progress monitor showing tournament winners and running statistics

**Usage**:
```bash
./run.sh tournament [num_runs] [seed]        # Default: 100 runs, 6 workers
python main.py tournament --num-runs 1000    # Full 1000-tournament run
python3 tournaments/monitor.py [interval]    # Live dashboard in another terminal
```

**Output** (in `tournament_results/`):
- `aggregated_results.csv`: Per-model statistics (wins, losses, win rate, ELO, CI)
- `match_matrix.csv`: Head-to-head records
- `placement_frequency.json`: How often each model finishes in each placement
- `html/summary.html`: Ranking table with ELO and color breakdowns
- `html/elo_evolution.html`: Interactive line chart showing ELO convergence across runs
- `html/placement_frequency.html`: Heatmap and table of placement frequencies
- `html/head_to_head_matrix.html`: 2D grid showing WHITE/BLACK win rates per matchup

**Runtime**: ~2.5 min per 100 tournaments (7,200 games) on 6 workers with 1-ply lookahead. Scales linearly with number of tournaments.
