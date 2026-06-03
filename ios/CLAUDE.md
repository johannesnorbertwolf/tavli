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
  `activeMoves` (legal `Move`s still consistent with what's been picked) + `built: [HalfMove]`,
  and a **read-only reference to the live `GameBoard`** (it reads occupancy to decide
  playability; it never applies/undoes — the session mutates that same board in step, so the
  builder always sees the position after the built prefix). Constructed with the dice
  (`init(legalMoves:board:die1:die2:)`) so it can unmerge (below).
  **Order-independent:** the engine stores each multi-die move in one canonical order, but the
  player may play those halves in any order, so the builder treats a move's half-moves as a *bag*
  (`remaining(of:)` is a pure multiset difference of `m.halfMoves` minus `built`; `nil` if `built`
  isn't a sub-multiset). It decides which half-move may come next from the **live board**, not a
  board-blind heuristic: a remaining half-move is playable-next iff its `from` currently holds a
  movable checker (`movablePieces(for:) > 0`, or a checker just arrived there mid-chain) **and**
  its `to` is open. This distinguishes a genuine single-checker chain (`8→6→4`, where 6 is empty
  until the first hop fills it, so `6→4` waits) from two *independent* checkers whose ray
  positions coincide (a checker at 8 and a separate one at 6 — both immediately playable, either
  order). The old `to == from` test couldn't tell those apart and wrongly locked out the
  independent checker (issue #44). No ordering re-check is needed in `remaining` because every
  committed half-move was board-legal in real order at commit time.
  **Multi-hop (Pasch).** On doubles the engine stores each equal-distance hop as a separate
  half-move, so `validDestinations(for:)` returns the **full reachable ray** (`s±N, s±2N, …`) and
  `path(from:to:)` gives the ordered single-die hops the session commits for a tap on a far
  endpoint.
  **Unmerged (non-Pasch single checker).** When one checker plays *both* distinct dice the engine
  stores it *merged* as a single half-move of distance `d1+d2` (e.g. `1→9` for dice 3·5). Left
  merged the player could only tap the far endpoint, never stop on or continue from the
  intermediate. So at construction the builder **unmerges** every such move into its single-die hop
  sequence(s) through whichever intermediate(s) are open at turn start — one expanded `Move` per
  legal intermediate (`[1→4, 4→9]` and/or `[1→6, 6→9]`). Both the stops and the far endpoint then
  highlight, and tapping a stop lets the same checker continue; the final board position is
  identical to the merged half-move. With this, non-Pasch single-checker moves run through the same
  bag/chaining machinery as Pasch.
  `selectableSourcePoints` / `validDestinations(for:)` are the `from`/`to` of the board-aware
  playable-next half-moves across surviving moves; `commit(halfMove:)` keeps the moves whose
  remaining bag contains the half-move, appends it, and returns whether nothing remains (complete);
  `canFinishNow` is true when some surviving move has no remaining halves (a shorter move that is a
  prefix of a longer one is *finishable*, not *forced*); `undo()` (no `allLegal:` argument anymore)
  rebuilds `activeMoves` from the stored **expanded** legal-move set; `completedMove` is a surviving
  move with no remaining halves.

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

- **AI integration (T6 + multi-ply search, #58).** `GameSession` optionally drives one side with
  the Core ML `Agent`. Construct it with `agent:` + `aiColor:` (+ optional `searchConfig:`);
  `GameSession.makeAgent()` loads the app-bundled `PlakotoValue.mlmodelc` (returns `nil` if absent →
  random fallback). Call `start()` once after construction so the AI moves first if it owns the
  starting player. When `finishTurn` (or `start`/`newGame`) lands on the AI's turn, `takeAITurn`
  rolls, computes legal moves (empty = forced pass), then: with no model it applies a random legal
  move synchronously; with a model it enters `aiThinking` and runs the **multi-ply expectimax
  search** (`agent.getBestMove`) on a detached task **off the main actor**, hopping back via
  `MainActor.run` to apply the move. `Agent` calls are wrapped in `try?` so a Core ML failure falls
  back to a random move. `winProbability` (WHITE's view: `mover == .white ? score : 1 - score`)
  updates only from a real model score and stays at its `0.5` default under the random fallback.
  `lastSearchDepth` (published, read-only) records the depth the iterative-deepening search actually
  *reached* on the AI's last move: `getBestMove` returns it, `applyAIMove` stores it, `newGame` resets
  it to `0`, and the random fallback passes `depth: nil` (leaving it `0`). The debug overlay surfaces
  it as `reached N-ply (max M)` so play can confirm whether 4-ply landed or the 20s budget forced a
  3-ply fallback. Validated headless by `GameSessionAITests` (real-model game + missing-model fallback; these pin
  `searchConfig: SearchConfig(maxDepth: 1)` so full-game tests stay fast — the search itself is
  covered by `AgentSearchTests`).

  **Board-copy isolation.** The search must not race the live `game.board`: the main actor keeps
  reading/scoring it (UI render, debug overlay) while the search applies/undoes thousands of times,
  and sharing one board would interleave the unbalanced pop/push and corrupt the checker counts. So
  `takeAITurn` snapshots `game.board.captureStacks()` + the dice on the main actor, and the detached
  task rebuilds an **isolated `GameBoard` copy** (`restoreStacks`) to search. Move generation is
  deterministic, so the copy's move list matches `liveMoves` index-for-index; the search returns the
  chosen **index**, which the main actor maps back to the live `Move` before applying. An
  out-of-range/`nil` index (Core ML failure) falls back to a random live move.

- **`SearchConfig`** mirrors the CLI's `config/config.yml` search section so on-device play matches
  `./run.sh play`: `timeBudget`↔`play_time_budget_s` (20s safety ceiling), `beamThreshold`↔
  `beam_threshold` (absolute fallback, used only when `relativeCutoff` is nil), `relativeCutoff`↔
  `search_relative_cutoff` (0.08), `maxBranch`↔`search_max_branch` (5). The pruning knobs match the
  CLI exactly. **`maxDepth` intentionally differs**: the CLI caps at `search_max_depth: 2`, but the
  default `.standard` config sets `maxDepth: 4` so on-device play reliably completes depth 3 (3-ply)
  and then *probes* depth 4 with whatever of the 20s `timeBudget` remains, falling back to the
  depth-3 result if 4 times out (the search reports the depth it actually reached — see
  `lastSearchDepth` below). `SearchConfig(maxDepth: 1)` forces pure 1-ply (used by the headless
  game tests to stay fast).

- **`Agent` search (ported from `ai/agent.py`, #58).** Three layers on top of the parity-validated
  1-ply primitive (`evaluateMoves`, which scores each candidate as `1 - opponentValue` and a `defer`
  restores the board on any exit):
  - `pruneBranches(scores:beamThreshold:relativeCutoff:maxBranch:)` — beam helper mirroring
    `_prune_branches`: keep `score >= best*(1-relativeCutoff)` when a relative cutoff is set, else
    `score >= best - beamThreshold`; sort best-first (ties by original index, matching Python's
    stable sort); cap to `maxBranch`; always keep ≥1.
  - `evaluateMovesNply(…depth:…deadline:)` — recursive expectimax (`_evaluate_moves_nply`). `depth ≤ 1`
    delegates to `evaluateMoves`. Deeper: for each candidate, iterate all 21 weighted dice outcomes
    (`diceOutcomes`); the chance nodes are **never** pruned (distribution stays exact); a pass-position
    (no opponent moves) is scored from our own perspective; otherwise opponent replies are 1-ply
    pre-screened, pruned via `pruneBranches`, recursed at `depth-1`, and folded in as
    `weight * (1 - oppDeep.max())`. Each apply is paired with a `defer`-undo so the board is restored
    even when a `SearchTimeout` unwinds from a deeper frame.
  - `getBestMove(…timeBudget:…maxDepth:)` — iterative-deepening beam expectimax under a wall-clock
    `DispatchTime` deadline. Single move → fast path (depth 1, index 0). Otherwise depth 1 scores all
    root moves, then it deepens while the deadline holds and `depth ≤ maxDepth`, re-scoring only the
    pruned root candidates (keeping prior-depth scores for the rest). A `SearchTimeout` mid-depth
    discards that depth's partial result and returns the last fully completed depth's best. Returns
    `(move, score, index, depth)`. Validated by `AgentSearchTests`: `pruneBranches` unit cases, an
    independent in-test 2-ply reference vs unpruned `evaluateMovesNply` (float-exact), the
    time-budget path (legal move, depth ≥ 2, budget respected, checkers conserved), and a
    **terminal-during-lookahead** case (a position where some lines pin Black's start point for an
    immediate win and others don't): every winning line must score exactly 1.0 via the `hasWon`
    short-circuit, non-winning lines strictly < 1.0, the search must pick a winning index, and the
    board must end byte-identical.

## Save & load (#61, replay-based)

Persist and resume in-progress games the same way the CLI does: **store only the move
history (dice + half-moves per ply), never the board state**, and rebuild by replaying from
the initial position. This is model-independent by construction — a game saved under model
vN reloads identically under vN+1 (acceptance criterion 3), because replay never consults the
model. Three engine files, all SwiftUI-free and covered by `GameSavePersistenceTests` (11
tests, no model/fixtures needed):

- **History recording — `GameSession`.** `history: [PlyRecord]` (public read-only) gains one
  entry per **finished turn**, recorded at all five turn-end points (`recordPly` captures the
  current dice + the played half-moves as `[[from, to]]`): the two human finish paths
  (`commitHalfMove` auto-finish and `confirm()`), the AI move (`applyAIMove`), and the two
  forced-pass paths (human `beginTurn`, AI `takeAITurn`) which record an **empty** half-move
  list. Saves are therefore only ever taken at clean turn boundaries — there is no
  partial/pending move state to serialize (a deliberate simplification). `startingPlayer` is
  also published (read-only) and `newGame` resets both it and `history`. `isTerminal` is the
  public "game over?" predicate the app uses to decide whether a save is worth keeping.
- **Resume — `GameSession.resume(from:config:agent:)` + private `replay(_:)`.** Builds a fresh
  session at `save.startingPlayer`/`aiColor`, then `replay` applies each recorded pair directly
  to the board (`board.points[from].pop()` / `board.points[to].push(mover)`, mirroring
  `applyHalfMove`) **without re-deriving legal moves**, alternating the mover every ply and
  stopping early if `game.isOver()`. It lands the session at `.awaitingRoll` (or `.gameOver`)
  with an empty `MoveBuilder` and a refreshed evaluation. Because turn order always alternates,
  the mover for ply *i* is `startingPlayer` when *i* is even, else its opponent — no per-ply
  color needs storing. Replay logic lives in `GameSession.swift` (not the model file) so it can
  reach file-private state; Swift `private` is file-scoped. Call `start()` after `resume` (as
  for a new game) so the AI moves if it owns the turn.
- **`GameSave.swift`** — the Codable wire format. `PlyRecord { die1, die2, halfMoves: [[Int]] }`
  and `GameSave { schemaVersion, name, savedAt, startingPlayer, aiColor?, history }`
  (`currentSchemaVersion = 1`). `GameSession.snapshot(name:savedAt:)` (extension) packages the
  live session into a `GameSave`. Colors serialize as their `rawValue` (`"white"`/`"black"`).
- **`SaveStore.swift`** — file-backed store, one pretty-printed JSON file per game under
  `directory` (the app uses `Documents/SavedGames`), `.iso8601` dates. One reserved **autosave**
  slot (`autosave.json`) plus any number of named manual saves (`save-<uuid8>.json`, so repeated
  names never clobber). The single autosave slot is overwritten on every move, so only the
  **last** in-progress game is ever kept. All IO is **synchronous** so the autosave completes
  before the app suspends. `list()` returns `SaveMetadata` (filename, name, savedAt, plyCount, isAutosave)
  newest-first, **skipping** unreadable or wrong-`schemaVersion` files; `load(filename:)` instead
  **throws** `SaveStoreError.incompatibleSchema` on a version mismatch. `writeAutosave` /
  `loadAutosave` / `clearAutosave` manage the reserved slot; `writeManual` returns the generated
  filename. `SaveStore.default()` roots it at `Documents/SavedGames`.

The app wiring (autosave after every move and on background, auto-resume on launch, the
saved-games list, and the in-game manual save) lives in `RootView`/`GameView` — see
`Views/CLAUDE.md`.

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
- **`DiceView.swift`** (T8; dice relocated to the board center bar in #46) — the dice:
  - `DieFace` — one ivory die (`#f5ead0` fill, `#2a1408` edge + pips, faint white inner
    highlight, soft drop shadow); pip positions are the design's normalized `PIP_LAYOUTS`.
    All metrics scale off `size` (default 56). `isUsed` greys it (opacity + desaturation).
  - `DiceRow` — pure row of `DieFace`s, driven by explicit `values` + a parallel
    `used: [Bool]`; renders any state for previews (normal, pasch=4, partially/fully
    consumed).
  - `usedDiceFlags(values:built:)` — greys the die **actually played**, not the leftmost
    (#46 fix): a half-move's die value is its signed point delta (no bear-off overshoot),
    matched to the first free slot of that value.
  - `BoardDiceView` — the live dice on the board's **center bar** (#46): lays each `DieFace`
    at `BoardGeometry.diceCenters(count:)`, a sibling overlay above the board's gesture
    stack with `.allowsHitTesting(canRoll)`. A pasch shows four; tap runs a brief tumble then
    `session.roll()`, gated on `phase == .awaitingRoll`. (`DiceView` is the equivalent chrome
    host, retained for previews.)
  - `ManualDiceControl` — two 1…6 steppers + "Set dice" → `session.setManualDice(d1,d2)`; only
    active while awaiting a roll. Same legal-move computation as a roll.
- **`PlayableBoardView.swift`** (T7) — the interactive board: `ZStack`s `BoardView`, a
  `TargetHighlightView` (gold frame/fill on legal targets), `CheckersView`, and a
  `SourceRingView` (gold ring on the selected source's checkers), and maps tap/drag to
  `GameSession` intents via `BoardGeometry.hitTest`. `HighlightStyle` (`.frame` default / `.fill`)
  is the design's two-readings constant. Binds via `@ObservedObject`; no game logic in the view.
  See `Views/CLAUDE.md`.
- **`GameView.swift`** (T9 chrome + T10 assembly + #61 manual save) — the assembled game screen:
  the interactive `PlayableBoardView` (which now hosts the center-bar dice) plus turn indicator,
  borne-off counters, contextual Undo/Done (dice no longer in the chrome, #46), a top-leading
  Back button (`onBack`) **paired with a Save button** (`onSave`, hidden once the game is over),
  a top-trailing hosted `DebugOverlayToggle`, and the win overlay. The Save button opens a naming
  `.alert` (timestamped default) and calls `onSave(name)`. Responsive landscape/portrait layout,
  padded tight so the board fills the display (#46), bound to a `GameSession`. See `Views/CLAUDE.md`.
- **`DebugOverlay.swift`** (T11) — an off-by-default bug-icon toggle (`DebugOverlayToggle`)
  plus a read-only eval panel (`DebugOverlay`) bound to `GameSession`: WHITE win-probability
  meter + top-3 candidate moves via `agent.evaluateMoves`, plus an **AI-search row** showing
  `reached N-ply (max M)` from `session.lastSearchDepth` / `session.searchConfig.maxDepth` (so play
  can see whether the iterative-deepening search hit 4-ply or fell back to 3). Never mutates
  gameplay. Hosted by `GameView` (T10) as a top-trailing overlay. See `Views/CLAUDE.md`.
- **`RootView.swift`** (T10 + #61 save/load) — app root: switches between the caramel mode picker
  (`ModePickerView`: "Tavli" wordmark + two "Play vs AI — You play White/Black" buttons **plus a
  saved-games list**) and a live `GameView`. Picking a color builds a human-vs-AI
  `GameSession(aiColor: humanColor.opponent)` (Black opens for now); Back returns to the picker.
  "Play Again" on the win overlay replaces the finished session with a fresh `GameSession` (same
  human color). Owns save/load via a `SaveStore.default()`: **auto-saves** the in-progress game
  after **every move** (plus on background and on Back) into the single overwritten autosave slot
  under a stable timestamped name (`persistAutosave` — clears the slot instead if the game is
  terminal, since finished games aren't resumed), **auto-resumes** a non-terminal autosave on cold
  launch (`autoResume` in `init`), and lets the picker resume or delete any saved game. The picker
  badges the autosave row "Continue last game". See `Views/CLAUDE.md`.

`App.swift` is `@main` hosting `RootView()`. The app launches on the mode picker; choosing a side
starts a fully playable human-vs-AI game. (The earlier T7 sign-off bootstrap that hosted a fixed
`PlayableBoardView`, and the retired T8 `DiceDemoScreen`, are gone; `DiceView` remains exercisable
via its `#Preview`.)

## Layout

```
ios/
├── TavliEngine/                 SwiftPM package — pure game engine + encoder + Core ML agent
│   ├── Sources/TavliEngine/     Color, GameConfig, Point, HalfMove, Move, Dice,
│   │                            GameBoard, PossibleMoves, BoardEncoder, Agent,
│   │                            SearchConfig, MoveBuilder, GameSession,
│   │                            GameSave, SaveStore
│   └── Tests/TavliEngineTests/  ParityTests, AgentParityTests, AgentSearchTests,
│                                FixtureSupport, MoveBuilderTests, GameSessionTests,
│                                GameSessionAITests, GameSavePersistenceTests
│       └── Fixtures/            fixtures.json + PlakotoValue.mlpackage (generated; see below)
├── TavliApp/                    SwiftUI iPad app (xcodegen project; .xcodeproj is generated)
│   ├── project.yml              xcodegen spec — iPad-only, all orientations, iOS 17, Swift-5 mode,
│   │                            local TavliEngine dep, bundles Resources/
│   ├── setup.sh                 generate model (if missing) → ensure xcodegen → generate project → resolve packages
│   ├── TavliAppUITests/         XCUITest target — drives the real gesture stack:
│   │                            BoardInteractionUITests (tap/drag move, visual
│   │                            repaint, full-turn → AI response). Launched with
│   │                            `-uiTestGame` (RootView starts a deterministic
│   │                            Black-to-move game, dice 3·5); asserts via the
│   │                            board's `accessibilityValue` checker-count signature.
│   └── TavliApp/
│       ├── App.swift            @main — hosts RootView (T10)
│       ├── Views/               SwiftUI views — BoardView (T3), CheckersView (T4),
│       │                        DiceView (T8), PlayableBoardView (T7), GameView (T9+T10),
│       │                        DebugOverlay (T11), RootView (T10 — picker + navigation)
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
bash ios/TavliApp/setup.sh            # generates the Core ML model (if missing) + TavliApp.xcodeproj
open ios/TavliApp/TavliApp.xcodeproj  # select an iPad simulator, ⌘R
```

`setup.sh` generates `PlakotoValue.mlpackage` only when it is absent (it shells out to
`convert_to_coreml.py` via the repo `.venv`); pass `--force-model` to regenerate after changing
`gold_model_path` or the encoder. A `preBuildScript` guard in `project.yml` fails the build
outright if the model is still missing, so the app can never silently ship the random-move
fallback.

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
