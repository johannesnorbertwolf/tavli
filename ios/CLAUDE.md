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
  **Order-independent:** the engine stores each multi-die move in one canonical order (die-1
  first — so a dice (3,5) two-checker move is `[1→4, 1→6]`), but the player may play those halves
  in either order, so the builder treats a move's half-moves as a *bag*. At each step it offers
  every half-move that could come next in *some* valid ordering (`playableNext`): a remaining
  half-move is offerable unless another remaining half-move delivers a checker to its `from` (a
  chain dependency like a pasch `1→3→5`); independent half-moves are freely reorderable. So
  selecting point 1 on a (3,5) roll offers 4, 6, **and** 9 (the merged single-checker move),
  matching the design — not just the stored-order 4/9. `remaining(of:)` validates `built` is a
  legal ordering prefix and returns the leftover half-moves; `selectableSourcePoints` /
  `validDestinations(for:)` are the `from`/`to` of `playableNext(remaining)` across surviving
  moves; `commit(halfMove:)` keeps the moves in which the half-move is offerable, appends it, and
  returns whether nothing remains (complete); `canFinishNow` is true when some surviving move has
  no remaining halves (a shorter move that is a prefix of a longer one is *finishable*, not
  *forced*); `undo(allLegal:)` rebuilds `activeMoves` from scratch; `completedMove` is a surviving
  move with no remaining halves. It does **not** touch the board — the session applies/undoes
  half-moves in step (in the player's chosen order, always a legal ordering).

- **`GameSession`** (`@MainActor`, `ObservableObject`) owns the `Game` and drives the turn state
  machine. Phases: `awaitingRoll / picking / moving / aiThinking / animating / gameOver(winner:)`
  — the session itself only enters the four human-move phases; `aiThinking`/`animating` are part
  of the shared vocabulary for later AI/animation tickets. Intents: `roll` / `setManualDice(_:_:)`
  (deterministic dice for scripted/manual play) / `selectPoint` / `commitHalfMove(from:to:)` /
  `undo` / `confirm` / `newGame`. On roll it computes `legalMoves` via `PossibleMoves`; an empty
  set is a **forced pass** that advances the turn. `commitHalfMove` applies the half-move to the
  board and auto-finishes when the move is complete or the only continuation is itself legal.
  Win detection uses `game.getWinner()`; `finishTurn` switches turn and returns to `awaitingRoll`.
  Published read-state (`phase`, `legalMoves`, `selectedPoint`, `validTargets`, `selectableSources`,
  `winProbability`) is the view contract. No animation or rendering live here (later tickets).

- **AI integration (T6).** `GameSession` optionally drives one side with the Core ML `Agent`.
  Construct it with `agent:` + `aiColor:`; `GameSession.makeAgent()` loads the app-bundled
  `PlakotoValue.mlmodelc` (returns `nil` if absent → random fallback). Call `start()` once after
  construction so the AI moves first if it owns the starting player. When `finishTurn` (or `start`/
  `newGame`) lands on the AI's turn, `takeAITurn` rolls, computes legal moves (empty = forced pass),
  then: with no model it applies a random legal move synchronously; with a model it enters
  `aiThinking` and runs `agent.getBestMove` on a detached task **off the main actor**, hopping back
  via `MainActor.run` to apply the move. `Agent` calls are wrapped in `try?` so a Core ML failure
  falls back to a random move. `winProbability` (WHITE's view: `mover == .white ? score : 1 - score`)
  updates only from a real model score and stays at its `0.5` default under the random fallback.
  Validated headless by `GameSessionAITests` (real-model game + missing-model fallback).

## SwiftUI views

`TavliApp/TavliApp/Views/` holds the rendering layer. Views are thin and bind to `GameSession`
through its published read-state + intents — no game logic lives in views.

- **`BoardView.swift`** (T3) — static empty Caramel board drawn with a single `Canvas` on top
  of `BoardGeometry` (frame, surface, triangles + tip pips, bar line, diamonds, wordmark). No
  game state yet. See `Views/CLAUDE.md` for the full breakdown.
- **`CheckersView.swift`** (T4) — checker stacks drawn with a single `Canvas` on top of
  `BoardGeometry`, a pure function of board state (`[Point]`); overlays `BoardView` in a
  `ZStack`. Radial-gradient ivory/red discs, detail rings, specular arc, drop shadow; ≤5
  visible per point with a base-checker count label when >5; pinned checker = its opponent
  color at the base. See `Views/CLAUDE.md`.
- **`DiceView.swift`** (T8) — the dice. Layered as three views:
  - `DieFace` — one ivory die (`#f5ead0` fill, `#2a1408` edge + pips, faint white inner
    highlight, soft drop shadow); pip positions are the design's normalized `PIP_LAYOUTS`.
    All metrics scale off `size` (default 56). `isUsed` greys it (opacity + desaturation).
  - `DiceRow` — pure row of `DieFace`s, driven by explicit `values` + `usedCount`; renders any
    state for previews (normal, pasch=4, partially/fully consumed).
  - `DiceView` — binds `DiceRow` to a `GameSession`: a pasch shows four dice; `usedCount` =
    `moveBuilder.built.count` (one die greyed per committed half-move, left→right); tap runs a
    brief tumble animation then `session.roll()`, gated on `phase == .awaitingRoll`.
  - `ManualDiceControl` — two 1…6 steppers + "Set dice" → `session.setManualDice(d1,d2)`; only
    active while awaiting a roll. Same legal-move computation as a roll.
- **`PlayableBoardView.swift`** (T7) — the interactive board: `ZStack`s `BoardView`, a
  `TargetHighlightView` (gold frame/fill on legal targets), `CheckersView`, and a
  `SourceRingView` (gold ring on the selected source's checkers), and maps tap/drag to
  `GameSession` intents via `BoardGeometry.hitTest`. `HighlightStyle` (`.frame` default / `.fill`)
  is the design's two-readings constant. Binds via `@ObservedObject`; no game logic in the view.
  See `Views/CLAUDE.md`.

`App.swift` now hosts `PlayableBoardView` bound to a `GameSession(startingPlayer: .white)` rolled
to `3·5` (the design's reference highlight scenario) on the reference page background — a T7
sign-off bootstrap (only the first turn is playable without a dice UI). The earlier T8
`DiceDemoScreen` harness has been retired; `DiceView` remains exercisable via its `#Preview`.
These remain placeholders until the screen assembly in T10.

## Layout

```
ios/
├── TavliEngine/                 SwiftPM package — pure game engine + encoder + Core ML agent
│   ├── Sources/TavliEngine/     Color, GameConfig, Point, HalfMove, Move, Dice,
│   │                            GameBoard, PossibleMoves, BoardEncoder, Agent,
│   │                            MoveBuilder, GameSession
│   └── Tests/TavliEngineTests/  ParityTests, AgentParityTests, FixtureSupport,
│                                MoveBuilderTests, GameSessionTests, GameSessionAITests
│       └── Fixtures/            fixtures.json + PlakotoValue.mlpackage (generated; see below)
├── TavliApp/                    SwiftUI iPad app (xcodegen project; .xcodeproj is generated)
│   ├── project.yml              xcodegen spec — iPad-only, all orientations, iOS 17, Swift-5 mode,
│   │                            local TavliEngine dep, bundles Resources/
│   ├── setup.sh                 ensure xcodegen → generate → resolve packages
│   └── TavliApp/
│       ├── App.swift            @main — hosts PlayableBoardView (T7 sign-off bootstrap); T10 replaces
│       ├── Views/               SwiftUI views — BoardView (T3), CheckersView (T4),
│       │                        DiceView (T8), PlayableBoardView (T7)
│       ├── Info.plist           iPad, all orientations; UIAppFonts registration
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
