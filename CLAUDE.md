# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A TD(λ) self-play training system for **Plakoto** (a Greek backgammon variant). A neural network learns to play by playing against itself, evaluated against frozen "gold" reference models in `models/`.

## Commands

```bash
./run.sh train [num_epochs]            # Train (caffeinate-wrapped on Mac, resumable)
./run.sh eval-gold [games] [v1-v4]     # Benchmark trained model vs a gold checkpoint
./run.sh eval-gold-stats [x]           # Stats + significance test on last x eval log entries
./run.sh eval-gold-graph [x]           # Generate SVG progress chart
./run.sh play                          # Human vs AI interactive game
```

Tests use `unittest` — run from repo root:
```bash
.venv/bin/python -m unittest tests/domain/test_legal_moves.py -v   # single file
.venv/bin/python -m unittest discover tests/ -v                     # all tests
```

Test config is at `config-test.yml` (minimal: 1 epoch, 1 game, no gold eval).

## Architecture

### Training loop (`ai/td_lambda_training.py`)

Forward-view TD(λ) with a replay buffer and Adam. Per completed game (parallel worker or local):
1. Worker (or `_play_one_game_local`) plays one full game greedy-with-ε exploration and emits a trajectory dict: `{states[T+1], movers[T], terminal_winner_white}`. Weights do not change mid-game.
2. `_ingest_trajectory` forward-passes all `T+1` states once to get bootstrap values `V[0..T]`, then computes offline λ-returns from each mover's perspective (`compute_lambda_returns`). The post-terminal state's target is 0 (mover_T is the loser). **MC race grounding (I2)**: for states the playing loop flagged as a race (no contact possible), the λ-return target is replaced by a Monte-Carlo win-probability from `mc_rollouts_per_race_state` random rollouts to terminal (computed inline during play in `ai/mc_rollouts.py`, since encoded states can't be rebuilt into boards). Set the config knob to 0 to reproduce the pre-I2 path exactly.
3. All `T+1` `(encoded_state, target)` pairs are pushed into a `ReplayBuffer` (capacity ~50k, ring buffer, uniform sampling).
4. `_train_minibatches` runs `updates_per_game` Adam steps of `binary_cross_entropy_with_logits(forward_logits, target)`. Optional linear LR warmup `0.1·lr → lr` over `lr_warmup_steps` optimizer steps. `max_grad_norm` clips the gradient L2 norm pre-Adam (not the eligibility trace as the old code did).

Perspective helper: from mover_i's view, `U(j, i) = V[j]` if `mover_j == mover_i` else `1 - V[j]`. λ-return at state i with `N = T - i`:
`G^λ_i = (1-λ) · Σ_{n=1..N-1} λ^{n-1}·G^{(n)}_i + λ^{N-1}·G^{(N)}_i`
with `G^{(n)}_i = U(i+n, i)` if `i+n < T`, else `1` if mover_i won else `0`.

The replay buffer is not persisted across restarts (refills naturally). Adam optimizer state IS persisted inside `trained_model.pth` alongside `state_dict` (format_version=2; old checkpoints without optimizer state load fine and Adam starts fresh).

The training loop owns `.eval()` / `.train()` mode — `Agent` methods are mode-agnostic.

### Perspective-invariant encoding (`ai/board_encoder.py`)

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

### Checkpoint backward compatibility (`ai/checkpoint_io.py`)

Checkpoints store `encoder_version`, `hidden_sizes`, and `network_type`. Two things to know:

- All three encoder versions above are still loadable; gold_v1–v4 stay at `legacy_unary_v1` and gold_v5 at `unary_v2`. New checkpoints are saved as `unary_v3`.
- **Legacy layer names**: old checkpoints use `fc1/fc2/fc3/fc4`; `_migrate_state_dict()` remaps these to `layers.0/1/2/3` on load automatically.

When constructing a `BoardEvaluator` for a loaded checkpoint, always derive `input_size` from a `BoardEncoder` built with the checkpoint's `encoder_version`, and pass `hidden_sizes` from the checkpoint metadata. `load_agent_from_checkpoint()` handles this correctly — use it rather than constructing evaluator/encoder manually.

When bumping encoder version mid-project, training cannot resume from an old `trained_model.pth` (input dimension mismatch); `main.py` catches the load error and starts fresh. Delete `trained_model.pth` and `training_state.json` to start a clean run.

Future encoder optimization ideas (GPU fixed-features layer, incremental caching on `Board`) are documented in `docs/encoder_optimization_ideas.md`.

### Network (`ai/board_evaluator.py`)

`BoardEvaluator(input_size, hidden_sizes)` builds a simple MLP with ReLU hidden layers and sigmoid output (win probability ∈ [0,1]). Hidden sizes are configurable via `config.yml` (`hidden_sizes: [128, 64]` default). Layers stored in `nn.ModuleList` as `self.layers`. Two forwards: `forward(x)` returns sigmoid probabilities (used by `Agent` / eval); `forward_logits(x)` returns pre-sigmoid logits (used by the training loop with `binary_cross_entropy_with_logits` for numerical stability).

### Key config knobs

| Key | Effect |
|---|---|
| `discount_factor` | γ — use `1.0` for terminal-reward games |
| `lambda_start/end` | TD(λ) — forward-view weighting of n-step returns |
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
| `gold_model_path` | Reference model for eval |
| `mc_rollouts_per_race_state` | I2 — for each race state (no contact possible), replace the λ-return target with the mean of this many random rollouts to terminal (0 = off) |

The `alpha`, `alpha_decay`, `alpha_decay_every`, `alpha_min` keys are deprecated (left readable for old `training_state.json` resumes) and ignored by the Adam path.

### Model files and gold standards

**Current trained model**: `trained_model.pth` in the repo root. This is the live model updated by training. It contains both the network `state_dict` and Adam optimizer state (format_version=2).

**Gold standard checkpoints**: `models/gold_v1.pth` … `models/gold_vN.pth`. These are frozen reference models used as eval opponents. Higher number = newer/better. The current gold reference is whichever version `gold_model_path` points to in `config/config.yml` — check that file to see which is active (currently `gold_v9.pth`).

**To promote the current trained model to a new gold standard**:
```bash
cp trained_model.pth models/gold_vN.pth          # increment N
# then update config/config.yml: gold_model_path: models/gold_vN.pth
```

Gold models grow in size when the network architecture changes (e.g. v9 is 1.9 MB vs v8's 652 KB because hidden_sizes grew from [128,64] to [256,128,64]).

### Eval and logging

Each eval run appends one line to `training_runs/eval_gold_history.log`:
```
2026-05-01 17:00:58 epoch=100 games_per_color=100 white=0.04 black=0.02 avg=0.03
```

`local_tools/` contains SVG graph generators and a file-watch daemon for live dashboards during training.

## Documentation Policy

Every significant source file must have a corresponding documentation entry in its directory's `CLAUDE.md`. Documentation should be detailed enough that the file could be reimplemented from it alone.

**Significant files** (must always be documented): training loop, encoder, evaluator, agent, checkpoint I/O, game runner, board, move generation, dice. Not `__init__.py`, config loaders, or utility scripts.

**In plan mode**: always include a "Documentation updates" step in the plan, and ask the user whether to update the docs alongside the implementation changes.
