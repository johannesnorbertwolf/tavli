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
.venv/bin/python -m unittest tests/domain/test_possible_moves.py -v   # single file
.venv/bin/python -m unittest discover tests/ -v                        # all tests
```

Test config is at `config-test.yml` (minimal: 1 epoch, 1 game, no gold eval).

## Architecture

### Training loop (`ai/td_lambda_training.py::train_one_game`)

Standard TD(λ) with manual eligibility traces (no optimizer). Per ply:
1. Encode current board → forward pass → `value_tensor` (kept for backward)
2. Select move via epsilon-greedy (softmax exploration when epsilon fires)
3. Apply move, encode next board → get `next_value`
4. Flip next value to mover's perspective: `next_value_from_mover = 1 - next_value`
5. TD error: `δ = r + γ·next_value_from_mover - value`
6. `value_tensor.backward()` → accumulate into eligibility traces with global L2 clipping
7. `param += α · δ · trace`

After the terminal ply, a second update grounds the opponent's terminal value to the actual outcome.

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

Future encoder optimization ideas (GPU fixed-features layer, incremental caching on `GameBoard`) are documented in `docs/encoder_optimization_ideas.md`.

### Network (`ai/board_evaluator.py`)

`BoardEvaluator(input_size, hidden_sizes)` builds a simple MLP with ReLU hidden layers and sigmoid output (win probability ∈ [0,1]). Hidden sizes are configurable via `config.yml` (`hidden_sizes: [128, 64]` default). Layers stored in `nn.ModuleList` as `self.layers`.

### Key config knobs

| Key | Effect |
|---|---|
| `discount_factor` | γ — use `1.0` for terminal-reward games |
| `lambda_start/end` | TD(λ) trace decay |
| `epsilon_start/end/decay` | Exploration schedule |
| `max_grad_norm` | Global L2 clip on eligibility traces (0 = off) |
| `hidden_sizes` | Network width list, e.g. `[128, 64]` |
| `model_save_every_epochs` | Periodic mid-run checkpoint saves |
| `gold_model_path` | Reference model for eval |

### Eval and logging

Each eval run appends one line to `training_runs/eval_gold_history.log`:
```
2026-05-01 17:00:58 epoch=100 games_per_color=100 white=0.04 black=0.02 avg=0.03
```

`local_tools/` contains SVG graph generators and a file-watch daemon for live dashboards during training.
