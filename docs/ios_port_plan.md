# iPad app — Swift port plan (living document)

A native, offline iPad app for the Plakoto AI. The neural network runs on-device via
Core ML; the game engine and board encoder are re-implemented in Swift. See
`docs/decisions.md` for the architectural decisions and `docs/history.md` for background.

Everything lives under `ios/`. Source of truth for behavior is the Python in
`domain/`, `ai/`, `game/`, `config/`.

## Phase 1 — Engine + Core ML parity  ✅ DONE

Goal: a Swift engine + encoder + Core ML model that behave **identically** to the Python
AI, proven by fixtures. No UI yet.

Implemented (`ios/TavliEngine`, a SwiftPM package):

The Python side was rewritten to the **array-based domain v2** (`domain/board.py` `Board` with
`n[]`/`color[]`/`pinned[]` arrays, `domain/move_generation.py`, int colors `WHITE=1`/`BLACK=-1`
in `domain/constants.py`, `Move`/`HalfMove` `NamedTuple`s). The Swift port deliberately keeps its
faithful **OO / reference-type** structure (`final class` `Point`/`HalfMove`/`GameBoard`); it is not
re-modelled as arrays. Its *behavior* is what's validated against v2 by the parity gate, and the
gate is green — so the mapping below is conceptual (Swift class ↔ v2 module), not line-for-line.

| Swift file | Mirrors (Python, v2) | Notes |
|---|---|---|
| `Color.swift` | `domain/constants.py` (int `WHITE=1`/`BLACK=-1`) | Swift keeps a `Color` enum; values map to the v2 ints |
| `GameConfig.swift` | `config/config.yml` + `gold_v9` board_spec | 24 / 15 / home 6 / 6-sided |
| `Point.swift` | (no v2 analogue) — v2 folds points into `Board` arrays | `final class`; stack bottom→top, pinning via stacking |
| `HalfMove.swift` | `domain/move.py` `HalfMove(src, dst)` | Swift holds `Point` refs; apply mutates the board |
| `Move.swift` | `domain/move.py` `Move(halves)` | |
| `Dice.swift` | `domain/dice.py` | |
| `GameBoard.swift` | `domain/board.py` `Board` (array model) | apply/undo, hasWon (goal + capture), home counts |
| `PossibleMoves.swift` | `domain/move_generation.py` `legal_moves` | non-pasch pairs, merged, **rule-2** single-die, **PaschGenerator** (1–4 halves, global-flag suppression), bear-off home rule |
| `BoardEncoder.swift` | `ai/board_encoder.py` (`unary_v3`) | 486 floats: per-point flip + 18 smart globals |
| `Agent.swift` | `ai/agent.py` (1-ply) | Core ML-backed; score = 1 − opponentValue, win = 1.0, argmax |

Parity fixtures + tests:
- `ios/scripts/generate_test_fixtures.py` — emits `Tests/TavliEngineTests/Fixtures/fixtures.json`
  (board positions → encodings, legal-move sets, 1-ply scores/best-move from the PyTorch agent).
- `ios/scripts/convert_to_coreml.py` — converts `models/gold_v9.pth` → `PlakotoValue.mlpackage`
  (in the test Fixtures dir), and self-checks PyTorch vs Core ML.
- `Tests/TavliEngineTests/` — `ParityTests` (encoding + legal moves), `AgentParityTests`
  (Core ML scores + best move).

Verified results (latest run — re-validated against **domain v2**):
- Encoding: max abs-diff ≤ 1e-5 over 428 cases.
- Legal moves: exact match over 4494 (position × dice) cases.
- Core ML vs PyTorch: max abs-diff 2.98e-7.
- Agent 1-ply: max score diff 8.4e-6 over 170,430 moves, **0 best-move mismatches**.

The Swift OO engine passed unchanged against fixtures regenerated from v2, confirming v2 is a
behavior-preserving rewrite of the retired v1 OO domain.

## Phase 2 — SwiftUI iPad app  ⬜ TODO

- xcodegen project (`ios/TavliApp`) wrapping the `TavliEngine` package + bundled `.mlpackage`.
- Views: board (24 points), checker stacks with pin rendering, dice, move input
  (tap + drag), win-probability/eval overlay, undo, manual dice, color choice.
- `GameViewModel`: turn flow, AI integration via `Agent`, save/load.
- Incorporate the design sketch from "Claude designs" — **to import**: drop into
  `docs/design/` as PNG or (ideally) SVG, then translate to SwiftUI.

## Phase 3 — Polish / later  ⬜ TODO

- 2-ply expectimax in the Swift `Agent` (mirror `_evaluate_moves_2ply_batch`) once 1-ply
  ships; batch Core ML predictions for speed.
- Android (Kotlin/Compose) reusing the Core ML→TFLite/ONNX model and a Kotlin engine port.

## How to run / verify

```bash
# 1. Regenerate fixtures from the Python source of truth (uses the main-repo venv):
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/generate_test_fixtures.py

# 2. (Re)convert the Core ML model from gold_v9 and self-check parity:
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/convert_to_coreml.py

# 3. Run the Swift parity suite (engine + encoder + Core ML agent):
cd ios/TavliEngine && swift test
```

Regenerate fixtures + model whenever the Python engine, encoder, or `gold_model_path`
changes. If the network architecture or encoder version changes, update `GameConfig` /
`BoardEncoder` to match and re-run all three steps.
