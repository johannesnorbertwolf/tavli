# ios/ — engine reference

Reimplementation-grade detail for the headless engine layer (turn controller,
persistence, stats) and the directory layout. The directory `CLAUDE.md` carries
the index, build/parity commands, and conventions; this file holds the deep
detail. The SwiftUI rendering layer is documented separately under
`TavliApp/TavliApp/Views/`.

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
  `undo` / `undoLastDecision` / `confirm` / `surrender` / `newGame`. On roll it computes `legalMoves` via
  `PossibleMoves`; an empty set is a **forced pass** that advances the turn. `commitHalfMove`
  applies the half-move to the board and auto-finishes when the move is complete or the only
  continuation is itself legal. Win detection uses `game.getWinner()`; `finishTurn` records the
  ply, switches turn, and returns to `awaitingRoll`.
  Published read-state (`phase`, `legalMoves`, `selectedPoint`, `validTargets`, `selectableSources`,
  `winProbability`) is the view contract. No animation or rendering live here (later tickets).
- **Undo — two intents, two surfaces (#59).** Every committed ply (human or AI move, or a forced
  pass) is appended to a private `undoHistory` of `UndoRecord`s — `(mover, move?, dice)` — via
  `recordTurn`, in lockstep with the entry added to `record.plies`. The live `Move` objects let
  `board.undo(move)` reverse board mutations exactly; passes carry `move == nil`.
  - `undo()` — half-move only (the **within-turn editing primitive**): peels the last committed
    half-move off `moveBuilder` while a move is being composed; no-op otherwise. `canUndo` is
    true only while `moveBuilder.built` is non-empty. Wired to the persistent **Undo** button in
    `ControlsView`.
  - `undoLastDecision()` — **decision-point rewind** (debug pane only): pops every ply from the
    human's last real move forward (reversing each on the board), restores that ply's player +
    dice, and re-enters the human's turn (`beginTurn` → `picking`) so the same position can be
    re-decided. Both `undoHistory` and `record.plies` are trimmed to the same target index so they
    stay in sync. Mirrors the CLI's `undo_to_my_decision`: typically two plies (your move + the
    AI's reply), skipping passes, clamped at game start. The decide-side is `aiColor?.opponent`;
    a human-vs-human session steps back the single last move. `canUndoLastDecision` gates the
    **"↩ Undo decision"** button in `DebugOverlay`. After `replay` (loading a save),
    `undoHistory` is empty and `canUndoLastDecision` is false until the first new move.

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
  Validated headless by `GameSessionAITests` (real-model game + missing-model fallback; these pin
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

- **`SearchConfig`** — the leaf scoring + inner pruning mirror the CLI's `config/config.yml` search
  section (so move *evaluation* matches `./run.sh play`), but the **root search strategy is
  iOS-specific** (see `getBestMove` below). `timeBudget`↔`play_time_budget_s` (20s — now a *hard* cap),
  `beamThreshold`↔`beam_threshold` (absolute fallback, used only when `relativeCutoff` is nil),
  `relativeCutoff`↔`search_relative_cutoff` (0.08), `maxBranch`↔`search_max_branch` — the cap on
  replies expanded per **inner** node, default `4`. **`maxDepth`**: `.standard` defaults to `2` for a
  fast 2-ply on-device search (typical turns are effectively instant); `maxDepth: 3`+ opts into the
  anytime deepening described below (its worst case can take the full `timeBudget`), and
  `SearchConfig(maxDepth: 1)` forces pure 1-ply (used by headless game tests to stay fast). Three
  knobs have **no CLI equivalent**: `maxRootBranches` (5) caps the root candidate set at every depth;
  `rootSoftBudget` (8s) and `minRootBranches` (2) only matter for the `maxDepth >= 3` deepening.

- **`Agent` search (#58).** Three layers on top of the parity-validated
  1-ply primitive (`evaluateMoves`, which scores each candidate as `1 - opponentValue` and a `defer`
  restores the board on any exit). The leaf scoring and `evaluateMovesNply` are ported from
  `ai/agent.py`; `getBestMove`'s *root strategy* is iOS-specific (below):
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
  - `getBestMove(…timeBudget:…maxDepth:rootSoftBudget:minRootBranches:maxRootBranches:)` — **2-ply
    baseline + anytime deepening** under a wall-clock `DispatchTime` deadline (this replaced the
    earlier iterative-deepening loop). Single move → fast path (depth 1, index 0). Otherwise: (1) score
    every root move 1-ply and take the best-first candidate set within `relativeCutoff`, capped at
    `maxRootBranches`; (2) **2-ply baseline** — score the whole candidate set at depth 2 (the
    guaranteed floor: cheap, almost always completes, and orders the next step) — **at the default
    `maxDepth: 2` this baseline is the result and step 3 is skipped**; (3) when `maxDepth >= 3`,
    **deepen to `maxDepth`** one candidate at a time in 2-ply order, overwriting each baseline score
    with the deeper score — always at least `minRootBranches` (subject to the `timeBudget` hard cap),
    then keep widening up to `maxRootBranches` total **only while elapsed < `rootSoftBudget`**; inside
    each branch the 2nd/3rd levels prune to `maxBranch`; (4) return the argmax over the mixed
    2-ply/deepened scores. So cheap positions deepen the whole set in well under the soft budget, while
    a hugely-branching doubles roll still returns a complete 2-ply result plus a genuine `maxDepth`
    evaluation of its best moves within `timeBudget`. A `SearchTimeout` keeps the best result so far;
    if not even the 2-ply baseline finishes, the 1-ply best is returned (`depth = 1`). The cost floor
    on extreme positions is the per-node screen (every reply is scored before pruning), which
    `maxBranch` does not reduce. Returns `(move, score, index, depth)`. Validated by `AgentSearchTests`:
    `pruneBranches` unit cases, an independent in-test 2-ply reference vs unpruned `evaluateMovesNply`
    (float-exact), the budgeted path (legal move, budget respected, checkers conserved), an **anytime**
    case (tiny budget still yields a legal conserved move), and a **terminal-during-lookahead** case (a
    position where some lines pin Black's start point for an immediate win and others don't): every
    winning line must score exactly 1.0 via the `hasWon` short-circuit, non-winning lines strictly
    < 1.0, the search must pick a winning index, and the board must end byte-identical.

- **Game-over hook (#64).** `GameSession.onGameOver: (@MainActor (Color) -> Void)?` fires
  **exactly once**, inside `finishTurn` the moment the session enters `.gameOver`, with the
  winning color. It's the seam the app uses to record the human's win/loss; the engine itself
  stays unaware of stats persistence. It fires once per game because no intent re-enters
  `finishTurn` after `.gameOver` (all intents guard on the pre-game-over phases), and a fresh
  game (a new session, or `newGame`) re-arms it. `replay` (loading a save) deliberately does
  **not** fire it, so resuming a finished game never double-counts.

- **Surrender / resign (#74).** `surrender()` lets the human concede: it discards any half-move
  built this turn (`board.undoHalfMove`), records the AI side as the winner, and enters `.gameOver`
  — the same terminal state a played-out loss reaches, so `onGameOver(aiColor)` fires and the loss
  is counted normally. Gated by `canSurrender` (true only on the human's own `awaitingRoll`/`picking`/
  `moving` phase of a game with an AI side — never mid-AI-think/animation or once over), so a double
  tap or a tap during the AI's turn is a no-op and the hook still fires once. It records nothing to
  `record.plies` (no ply was played), so the app's per-move auto-save hook does **not** fire on
  resign — the view clears the auto-save slot explicitly via `onAutosave` after confirming.
  `humanWinProbability` re-expresses WHITE's `winProbability` for the human side (or `nil` h-vs-h)
  and drives the UI's double-confirm threshold; the engine owns the perspective flip, the view owns
  the 10% policy.

## Save & load (#61, replay-based)

Persist and resume in-progress games the same way the CLI does: **store only the move
history (dice + half-moves per ply), never the board state**, and rebuild by replaying from
the initial position. This is model-independent by construction — a game saved under model
vN reloads identically under vN+1 (acceptance criterion 3), because replay never consults the
model. Three engine files, all SwiftUI-free and covered by `GameSavePersistenceTests` (11
tests, no model/fixtures needed):

- **Canonical record — `GameRecord` (#71).** One value type `{ startingPlayer, aiColor,
  plies: [PlyRecord], outcome }` is the single source of truth for a game, in-progress and
  completed. `GameSession` holds one `@Published private(set) var record`; `history`,
  `startingPlayer` and `aiColor` are **computed passthroughs** over it (so every call site and
  the `onChange(of: session.history.count)` autosave keep working — mutating `record` still
  fires `objectWillChange`). `outcome` is the winner, set whenever a turn ends the game
  (`finishTurn`/`replay`), else `nil`; it lives in memory only — the on-disk format does not
  carry it yet (only in-progress games are persisted). This is the shared foundation the undo
  (#59), history-log (#60), review/drill (#62/#63) and stats (#64) features build on.
- **History recording — `GameSession`.** `history: [PlyRecord]` (the record's `plies`) gains one
  entry per **finished turn**, recorded at all five turn-end points (`recordTurn` captures the
  current dice + the played half-moves as `[[from, to]]`, and in parallel appends an `UndoRecord`
  to `undoHistory` for decision-point undo): the two human finish paths (`commitHalfMove`
  auto-finish and `confirm()`), the AI move (`applyAIMove`), and the two forced-pass paths (human
  `beginTurn`, AI `takeAITurn`) which record an **empty** half-move list. Saves are therefore only
  ever taken at clean turn boundaries — there is no partial/pending move state to serialize (a
  deliberate simplification). `newGame` resets the whole `record` (preserving `aiColor`).
  `isTerminal` is the public "game over?" predicate the app uses to decide whether a save is
  worth keeping.
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
- **`GameSave.swift`** — the `GameRecord` value type plus the Codable wire format.
  `PlyRecord { die1, die2, halfMoves: [[Int]] }` and `GameSave { schemaVersion, name, savedAt,
  startingPlayer, aiColor?, history }` (`currentSchemaVersion = 1`) — the on-disk format is
  unchanged (flat, no `outcome` key, no schema bump), so existing v1 saves still load. A bridge
  ties the two: `GameSave(record:name:savedAt:)` flattens a record into the wire format, and the
  computed `GameSave.record` reads it back (with `outcome == nil`). `GameSession.snapshot(name:
  savedAt:)` packages the live session's `record` into a `GameSave`. Colors serialize as their
  `rawValue` (`"W"`/`"B"`).
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

## Human game stats (#64)

`HumanGameStats.swift` is the iPad analogue of the CLI's post-game summary box / `human-stats`
command (`main.py`). Pooled results only — no per-opponent / per-model breakdown (out of scope).
SwiftUI-free (Foundation + Combine), so it's covered by `swift test`
(`HumanGameStatsTests`, `HumanStatsStoreTests`).

- **`HumanGameRecord`** — `Codable` `{ date, humanWon }`. One completed game.
- **`HumanGameStats(records:)`** — a **pure** summary mirroring `_print_human_record`:
  `total` / `wins` / `losses`, `winRate` (∈ [0, 1], 0 when empty), `recent` (up to the last 20
  outcomes, **oldest→newest**, for the sparkline), and the current streak (`streakCount` +
  `streakIsWin`, counting back from the most recent game; `0`/`false` when empty). `.empty` is
  the no-games value.
- **`HumanGameLog` + `HumanGameLogStore`** — persistence, following the **same conventions as
  `SaveStore`** (not `UserDefaults`): `HumanGameLog` is a schema-versioned Codable wrapper
  (`currentSchemaVersion`, `games: [HumanGameRecord]`), and `HumanGameLogStore` is a file-backed
  store writing a single JSON file (the app uses `Documents/HumanGameLog.json`) with `.iso8601`
  dates, pretty-printed + sorted-keys encoding, atomic writes, and an unrecognized
  `schemaVersion` **skipped** (read as empty) — exactly like `SaveStore.list()`. This is the
  iPad analogue of the CLI's `human_game_history.log` (the app is offline + sandboxed, so it can't
  share that file). It is deliberately a **separate outcome log**, not part of the
  `GameSave`/`SaveStore` game-storage standard (which stores resumable games), but it matches that
  standard's on-disk style. Tests run it against a real temp file (like the `SaveStore` tests).
- **`HumanStatsStore`** (`@MainActor`, `ObservableObject`) — loads on init from a
  `HumanGameLogStore` (default `.default()`), `record(humanWon:)` appends + persists immediately
  and republishes so SwiftUI panels re-derive `stats`. `RootView` owns one (`@StateObject`) and
  wires `session.onGameOver` to `store.record(humanWon: winner == humanColor)`.

## Post-game blunder review (#62)

`GameReview.swift` is the on-device analogue of the CLI's `review` command
(`play/loop.py:_handle_review` → `_collect_blunders`): after a game ends it replays the canonical
`GameRecord` and re-evaluates each human ply to surface the moves where the player deviated most
from the AI's best choice. SwiftUI-free (Foundation + Core ML via `Agent`), so it's covered by
`swift test` (`GameReviewTests`).

- **`GameReview.analyze(record:agent:humanColor:depth:config:searchConfig:onEvaluation:progress:)`** —
  replays the record from the initial position, advancing the board by applying each ply's recorded
  half-moves in place (identical to `GameSession.replay`, so reconstruction is model-independent).
  At each ply where it's the **human's** move, the move was **not a forced pass**, and there is
  **more than one legal move** (a single legal move is no decision — mirrors the CLI's
  `len(moves) <= 1` skip), it ranks *every* legal move with `Agent.evaluateMovesNply` at `depth`
  (default **2** — fast, and the depth on-device play uses; the same parity-validated scoring the
  live AI uses), with **no wall-clock deadline** since analysis is offline. `evaluateMovesNply`
  capture/restores stacks, so the working board is never corrupted. The played move is located among
  the legal moves by **multiset-comparing `(from, to)` pairs** (order-independent — the recorded
  order may differ from the generator's; the Swift analogue of the CLI's structural `_pairs`/`_find`
  match). `onEvaluation` fires per evaluated ply **as it is scored** (lets the UI stream blunders —
  show the first one immediately while the rest are still being found); `progress` fires once per
  evaluated human ply with `(done, total)`.
- **`PlyEvaluation`** — one analyzed human ply: 1-based `plyNumber`, dice, the **pre-move**
  `boardStacks` snapshot (for rendering the position faced), `mover`, the `playedMove`/`bestMove`
  `[from,to]` pairs and their win-probability scores (for `mover`), plus derived `relativeGap`
  `(best − played)/best`, `absoluteGap`, and `isBlunder(threshold:)`.
- **`GameReviewResult`** — every analyzed ply (`evaluations`); `blunders(threshold:)` filters to
  those whose relative gap meets the threshold. The analysis runs **once** and the consumer filters
  at any threshold (the iPad UI fixes it at **10%**, matching the CLI default; a configurable one is
  tracked in #77).

The app side (`GameReviewView` + its `@MainActor GameReviewModel`) runs `analyze` on a detached
task and **streams** blunders back via `onEvaluation`: the first blunder is shown as soon as it's
found (the panel notes it's still analyzing) while the rest are scored in the background; on
completion the model settles on the authoritative full set returned by `analyze`. The screen is a
**full-screen, board-centric** mode (a `fullScreenCover` from the win overlay): the position the
player faced fills the screen, with a panel (played→best + win-prob gap, a Best/Yours/None move
overlay) and Prev/Next/swipe to page through blunders. The drill is launched the same way (full
screen), with the already-streamed blunders handed over as a precomputed `GameReviewResult`.

## Post-game drill (#63)

The interactive sibling of the review — the on-device analogue of the CLI's `drill` command
(`play/loop.py:_handle_drill` / `_drill_inner`): step through the same blunders, and for each, ask
the player to find a better move **on the real board**. It reuses #62's blunder detection
(`GameReview`/`PlyEvaluation`) and two small additions to `GameSession`:

- **Attempt mode** (`onMoveAttempt: (@MainActor (Move) -> Void)?`). When set, the session runs in
  attempt mode: completing a move (via the normal `commitHalfMove`/`confirm` tap flow) reports it
  to the hook and then **rolls it back** to the pre-move position (`board.undoHalfMove` per built
  half-move, then `beginTurn()` re-arms `.picking` at the same dice) instead of recording it and
  advancing the turn. `record.plies`/`undoHistory` and the turn are left untouched, so a finished
  game's record is never mutated and the player can re-attempt the position indefinitely. Both
  completion sites funnel through one private `completeMove()`; with the hook nil (normal play)
  behaviour is unchanged.
- **Drill seeder** (`GameSession.drill(boardStacks:die1:die2:mover:agent:config:)`). Stands up a
  **human-vs-human** session (`aiColor: nil`, so no AI auto-moves) at an arbitrary position: seed
  each point via `setPoint`, then `setManualDice` → `.picking` with `mover` to play.

Grading reuses `Agent.scoreCandidate(boardStacks:move:mover:depth:)` (in `GameReview.swift`): it
rebuilds an **isolated** board from the stacks, reconstructs the attempted move against it, and
scores that single candidate at 2-ply via `evaluateMovesNply` — identical to that move's entry in a
full ranking, so it's directly comparable to the `PlyEvaluation`'s `bestScore`, and safe to run off
the main actor (the attempt's own `Move` references the live drill board the main actor keeps
reading). `gap = bestScore − attemptScore`; the feedback tiers mirror `_drill_inner` (correct =
`gap ≤ max(0.01, best·0.03)`, close = `gap ≤ max(0.04, best·0.10)`, else wrong).

The app side (`DrillView` + `@MainActor DrillModel`) analyzes (or takes a precomputed
`GameReviewResult` from the review screen), seeds a card per blunder, wires `onMoveAttempt` to grade
off the main actor, reveals the best move with `SourceRingView`/`TargetHighlightView`, and tracks
solved/skipped for the "Drill complete" summary. Launchable from the win overlay and the review
screen.

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
