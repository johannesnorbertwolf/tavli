# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Starting new work

Before creating a branch or starting anything new, always pull `main` and work from the
current state.

## Pull requests

When opening a PR that addresses a tracked issue, always put a closing keyword in the PR
description, e.g. `Closes #10` (one line per issue if it resolves several). This auto-closes
the linked issue on merge, which moves its card to Done on the "Tavli" GitHub Project board.
If a PR relates to an issue but shouldn't close it, use `Refs #10` instead.

## What this is

A TD(λ) self-play training system for **Plakoto** (a Greek backgammon variant). A neural network learns to play by playing against itself, evaluated against frozen "gold" reference models in `models/`.

## Commands

```bash
./run.sh train [num_epochs]            # Train (caffeinate-wrapped on Mac, resumable)
./run.sh eval-gold [games] [v1-v4]     # Benchmark trained model vs a gold checkpoint
./run.sh eval-gold-stats [x]           # Stats + significance test on last x eval log entries
./run.sh eval-gold-graph [x]           # Generate SVG progress chart
./run.sh eval-lookahead [total_games] [--workers N]  # Validate flexible search vs fixed 2-ply (gold self-play, parallel; default 1000)
./run.sh play                          # Human vs AI interactive game
./run.sh rollout-lab [--apply ...]     # Disagreement mining + rollout-labeled fine-tune with gated promotion (ai/REFERENCE.md)
./run.sh tournament [num_runs] [seed]  # Run round-robin tournaments (see tournaments/)
```

Tests use `unittest` — run from repo root:
```bash
.venv/bin/python -m unittest tests/domain/test_legal_moves.py -v   # single file
.venv/bin/python -m unittest discover -s tests/ -t . -v            # all tests
```

Test config is at `config-test.yml` (minimal: 1 epoch, 1 game, no gold eval).

## Architecture

Reimplementation-grade detail — training pipeline, encoder versions, checkpoint
back-compat, network, the full config-knobs table, eval/logging, and the
tournament system — lives in **`docs/architecture.md`**. Read it when working on
training or eval internals. Quick map:

- **Training** `ai/td_lambda_training.py` — forward-view TD(λ), replay buffer, Adam.
- **Encoding** `ai/board_encoder.py` — perspective-invariant; current `unary_v3` (486-dim).
- **Network** `ai/board_evaluator.py` — MLP; `hidden_sizes` from `config.yml`.
- **Checkpoints** `ai/checkpoint_io.py` — use `load_agent_from_checkpoint()`; back-compat across encoder versions.
- **Tournaments** `tournaments/` — round-robin gold-vs-gold eval.

Each top-level package (`ai/`, `domain/`, `game/`, `play/`, `ios/`) has its own `CLAUDE.md`
that indexes its modules and points to its reference doc(s).

## Model files and gold standards

**Current trained model**: `trained_model.pth` in the repo root. This is the live model updated by training. It contains both the network `state_dict` and Adam optimizer state (format_version=2).

**Gold standard checkpoints**: `models/gold_v1.pth` … `models/gold_vN.pth`. These are frozen reference models used as eval opponents. Higher number = newer/better. The current gold reference is whichever version `gold_model_path` points to in `config/config.yml` — check that file to see which is active (currently `gold_v11.pth`, the depth-2 TD-bootstrap endpoint). Gold files grow when the architecture changes (v9 is 1.9 MB vs v8's 652 KB because `hidden_sizes` grew from `[128,64]` to `[256,128,64]`).

**To promote the current trained model to a new gold standard**:
```bash
cp trained_model.pth models/gold_vN.pth          # increment N
# then update config/config.yml: gold_model_path: models/gold_vN.pth
```

## Documentation Policy

Docs are **two-tier** so they stay thorough without bloating the context window
(`CLAUDE.md` files auto-load; reference files are read on demand):

- **`CLAUDE.md` = thin index.** Each directory's `CLAUDE.md` gives a one-line summary
  per significant file, the critical conventions/gotchas for working there, and
  pointers to its reference doc(s). Target ≤ ~80 lines.
- **Reference files = the detail.** Reimplementation-grade detail lives in on-demand
  `.md` files co-located with the code: a single `REFERENCE.md` by default, or a few
  topic files (e.g. `USAGE.md` / `INTERNALS.md`) when a directory has genuinely distinct
  topics read in different situations. Referenced from the `CLAUDE.md` hub.
- **Self-contained, no cross-references.** Reference files don't link each other; only
  the `CLAUDE.md` hub points to them. Accept minor redundancy over a web of links.
- **Never `@import`** to offload detail — imports load at launch and save no context.
  Use plain prose pointers.

**Significant files** (must always be documented): training loop, encoder, evaluator,
agent, checkpoint I/O, game runner, board, move generation, dice. Not `__init__.py`,
config loaders, or utility scripts. The "reimplementable from the docs alone" bar is
preserved — it now lives in the reference files.

**In plan mode**: always include a "Documentation updates" step in the plan, and ask the
user whether to update the docs alongside the implementation changes.
