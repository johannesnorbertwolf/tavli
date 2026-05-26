# ios/ — native iPad app (Swift)

A native, **offline** iPad app for the Plakoto AI. The value network runs on-device via
Core ML; the game engine and board encoder are re-implemented in Swift. Background:
`docs/ios_port_plan.md` (status + how to run), `docs/decisions.md`, `docs/history.md`.

## What this is

The Python in `domain/`, `ai/`, `game/`, `config/` is the **source of truth**. The Swift
here is a faithful port, kept honest by a parity test suite. If the two ever disagree,
the Python is right and the Swift has a bug.

The Swift was originally ported from the retired **v1 OO domain** and has since been
re-validated against the current **array-based domain v2** (`domain/board.py` `Board`,
`domain/move_generation.py` `legal_moves`, int colors in `domain/constants.py`,
`Move`/`HalfMove` `NamedTuple`s). The Swift keeps its OO / reference-type structure on purpose
(see gotchas below); only its *behavior* is pinned to v2, and the parity gate is green.

## Layout

```
ios/
├── TavliEngine/                 SwiftPM package — pure game engine + encoder + Core ML agent
│   ├── Sources/TavliEngine/     Color, GameConfig, Point, HalfMove, Move, Dice,
│   │                            GameBoard, PossibleMoves, BoardEncoder, Agent
│   └── Tests/TavliEngineTests/  ParityTests, AgentParityTests, FixtureSupport
│       └── Fixtures/            fixtures.json + PlakotoValue.mlpackage (generated; see below)
└── scripts/
    ├── generate_test_fixtures.py   Python → fixtures.json (encodings, legal moves, scores)
    └── convert_to_coreml.py        gold_v9.pth → PlakotoValue.mlpackage (+ self parity check)
```

`TavliApp` (the SwiftUI app, xcodegen project) is Phase 2 and not built yet.

## Key conventions / gotchas

- **Reference types on purpose.** `Point`, `HalfMove`, `Move`, `GameBoard`, `Die`, `Dice`
  are `final class`: a `HalfMove` holds the board's `Point` objects, so `applyHalfMove`
  mutates the board in place (and `undo` reverses it). Move generation relies on this. This
  mirrors the retired v1 OO domain; v2 instead uses an array `Board` + immutable `NamedTuple`
  moves with explicit apply/undo tokens. The Swift keeps the OO design (it's clean and fast
  enough) and is validated against v2 by behavior, not structure.
- **Encoder must match exactly.** `BoardEncoder` reproduces `ai/board_encoder.py`'s
  `unary_v3` path bit-for-bit (486 floats: per-point flip + 18 smart globals). Any change to
  the Python encoder must be mirrored here, then fixtures regenerated.
- **Fixtures + model are generated, not hand-written.** Re-run both scripts after changing
  the Python engine/encoder or the `gold_model_path`. The `.mlpackage` lives in the test
  Fixtures dir so `swift test` can load it; Phase 2 will also bundle it into the app.
- **Tests use `computeUnits = .cpuOnly`** to match Python CPU inference and avoid ANE float
  drift. The agent parity test runs ~170k Core ML predictions and takes ~60s.

## Run the parity gate

```bash
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/generate_test_fixtures.py
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/convert_to_coreml.py
cd ios/TavliEngine && swift test
```
