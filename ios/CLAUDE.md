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

## Turn controller (headless, UI-agnostic)

`GameSession` + `MoveBuilder` are the contract the SwiftUI views build against. Both are
**SwiftUI-free** (only `Combine` for `ObservableObject`) and fully exercised by `swift test`,
so the game flow is validated without a simulator.

- **`MoveBuilder`** incrementally composes a full `Move` from half-moves. It holds
  `activeMoves` (legal `Move`s still consistent with what's been picked) + `built: [HalfMove]`.
  `selectableSourcePoints` / `validDestinations(for:)` drive highlighting at index `built.count`;
  `commit(halfMove:)` filters `activeMoves` and returns whether the move is complete;
  `canFinishNow` is true when some surviving move has exactly `built.count` halves (a shorter
  move that is a prefix of a longer one is *finishable*, not *forced*); `undo(allLegal:)` rebuilds
  `activeMoves` from scratch; `completedMove` is the first surviving move of length `built.count`.
  It does **not** touch the board — the session applies/undoes half-moves in step.

- **`GameSession`** (`@MainActor`, `ObservableObject`) owns the `Game` and drives the turn state
  machine. Phases: `awaitingRoll / picking / moving / aiThinking / animating / gameOver(winner:)`
  — the session itself only enters the four human-move phases; `aiThinking`/`animating` are part
  of the shared vocabulary for later AI/animation tickets. Intents: `roll` / `setManualDice(_:_:)`
  (deterministic dice for scripted/manual play) / `selectPoint` / `commitHalfMove(from:to:)` /
  `undo` / `confirm` / `newGame`. On roll it computes `legalMoves` via `PossibleMoves`; an empty
  set is a **forced pass** that advances the turn. `commitHalfMove` applies the half-move to the
  board and auto-finishes when the move is complete or the only continuation is itself legal.
  Win detection uses `game.getWinner()`; `finishTurn` switches turn and returns to `awaitingRoll`.
  Published read-state (`phase`, `legalMoves`, `selectedPoint`, `validTargets`, `selectableSources`)
  is the view contract. No AI, animation, or rendering live here (later tickets).

## Layout

```
ios/
├── TavliEngine/                 SwiftPM package — pure game engine + encoder + Core ML agent
│   ├── Sources/TavliEngine/     Color, GameConfig, Point, HalfMove, Move, Dice,
│   │                            GameBoard, PossibleMoves, BoardEncoder, Agent,
│   │                            MoveBuilder, GameSession
│   └── Tests/TavliEngineTests/  ParityTests, AgentParityTests, FixtureSupport,
│                                MoveBuilderTests, GameSessionTests
│       └── Fixtures/            fixtures.json + PlakotoValue.mlpackage (generated; see below)
├── TavliApp/                    SwiftUI iPad app (xcodegen project; .xcodeproj is generated)
│   ├── project.yml              xcodegen spec — iPad-only landscape, iOS 17, Swift-5 mode,
│   │                            local TavliEngine dep, bundles Resources/
│   ├── setup.sh                 ensure xcodegen → generate → resolve packages
│   └── TavliApp/
│       ├── App.swift            @main + placeholder screen (Phase 2 T1)
│       ├── Info.plist           landscape-only iPad; UIAppFonts registration
│       └── Resources/           bundled into the app:
│           ├── PlakotoValue.mlpackage   (generated; Xcode compiles → .mlmodelc)
│           ├── CormorantGaramond.ttf    (variable font, committed)
│           └── Inter.ttf                (variable font, committed)
└── scripts/
    ├── generate_test_fixtures.py   Python → fixtures.json (encodings, legal moves, scores)
    └── convert_to_coreml.py        gold_v9.pth → PlakotoValue.mlpackage, written to BOTH the
                                     test Fixtures dir and TavliApp/Resources (+ self parity check)
```

### Build the app

```bash
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/convert_to_coreml.py  # model into Resources/
bash ios/TavliApp/setup.sh            # generate TavliApp.xcodeproj
open ios/TavliApp/TavliApp.xcodeproj  # select an iPad simulator, ⌘R
```

`SWIFT_VERSION` is pinned to 5.9 (Swift-5 mode) on the app target — Swift-6 strict concurrency
errors on `MLModel` + the non-`Sendable` engine classes. The two display fonts are committed
TTFs (Cormorant Garamond + Inter, both variable) registered via `Info.plist` `UIAppFonts`; the
Core ML model is a generated artifact (gitignored, recreate with the convert script).

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
