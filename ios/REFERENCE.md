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
  — the four human-move phases plus `aiThinking` (the off-main search) and `animating` (the
  presentational replay of the AI's turn, #93); both AI phases block human input through the
  same guards the intents already use. Intents: `roll` / `setManualDice(_:_:)`
  (deterministic dice for scripted/manual play — on the AI's turn in manual mode it hands the
  entered dice straight to `playAITurn`, #110) / `selectPoint` / `commitHalfMove(from:to:)` /
  `undo` / `undoLastDecision` / `confirm` / `surrender` / `newGame`. On roll it computes `legalMoves` via
  `PossibleMoves`; an empty set is a **forced pass** that advances the turn. `commitHalfMove`
  applies the half-move to the board and auto-finishes when the move is complete or the only
  continuation is itself legal. Win detection uses `game.getWinner()`; `finishTurn` records the
  ply, switches turn, and returns to `awaitingRoll`.
  Published read-state (`phase`, `legalMoves`, `selectedPoint`, `validTargets`, `selectableSources`,
  `winProbability`, plus `aiDiceRolling`/`aiHopInFlight` for the AI-turn animation, #93) is the
  view contract. No rendering lives here.

- **Manual-dice mode for both players (#110).** The `manualDiceEntry` flag (init parameter,
  default `false`, threaded through `resume(from:)`; the view keeps it in sync with the dice-mode
  setting) makes the human enter the AI's dice too. When set, `maybeStartAITurn` does **not**
  auto-roll: the session pauses in `.awaitingRoll` on the AI's turn. The human's `setManualDice`
  then detects `isAITurn` and calls `playAITurn(animateDiceRoll: false)` — the AI searches/plays
  the entered dice with the normal move animation but no dice tumble (the values are already
  shown). `takeAITurn` is now just `rollDice()` + `playAITurn(animateDiceRoll: true)`.

- **AI-turn animation (#93).** Driven entirely by the session so the view layer stays passive;
  knobs live in **`AnimationTimings`** (`aiDiceRollDuration` / `aiMoveAnimationDuration`, both
  0.6 s in `.standard` for a ~1.8 s two-move turn; settings UI lands with #77). The struct is a
  mutable `var animationTimings` on the session (init parameter, default `.standard`, also
  threaded through `resume(from:)`); `.off` (both zero) restores the fully synchronous
  pre-animation behavior — headless tests pass it — and `isAnimated` is the gate `takeAITurn`
  checks. Animated flow:
  1. `takeAITurn` rolls (values are set up front — the search needs them), then `playAITurn`
     computes legal moves and sets `aiDiceRolling = true` (when the effective roll window > 0).
     With a model it enters `aiThinking` and the search runs **concurrently with the dice tumble**;
     the random fallback and the forced pass skip straight to `animating`. (In manual-dice mode,
     #110, `setManualDice` calls `playAITurn(animateDiceRoll: false)` so the roll window is 0 — no
     tumble, since the human already entered the dice.)
  2. Once the move is chosen, `animateAITurn` (phase → `animating`) sleeps out the *remainder* of
     the tumble window (`rollDuration`, 0 for manual entry), then clears `aiDiceRolling` — the dice
     settle on the real values.
  3. For each half-move in stored order it publishes an **`AIAnimatedHop`** (`id` = ordinal —
     distinguishes consecutive hops with identical endpoints on a Pasch — plus `from`/`to`/
     `color`/`duration`), sleeps `aiMoveAnimationDuration`, then **lands** it: `applyHalfMove` on
     the live board, `moveBuilder.commit` (so the dice grey die-by-die), `aiHopInFlight = nil`.
     The board advances point by point; all four hops of a Pasch are individually visible.
  4. After the last hop: a fresh empty `MoveBuilder` (a stale `built` would re-enable the
     within-turn Undo for the human), the `winProbability` update, `recordTurn`, `finishTurn`.
     A forced pass (`move == nil`) still tumbles and settles the dice, holds them for a short
     beat (`passBeat` — 0.45 s at standard timings, scaled down with the knobs so near-zero test
     timings stay near-instant), then records the pass.
  **Cancellation.** The driver task is stored (`aiAnimationTask`) and re-validates
  `[weak self] + !Task.isCancelled + aiTurnEpoch` after every suspension; `newGame()` bumps the
  epoch, cancels the task, and resets the published animation state, so neither a half-played
  animation nor a stale search result (the search's `MainActor.run` completion checks the epoch
  too) can mutate the fresh game. Covered by `GameSessionAnimationTests` (sequential hops match
  the recorded ply, point-by-point landings, `.off` synchronous escape, `newGame` cancellation,
  full animated game terminates with checkers conserved).
- **Undo — two intents, two surfaces (#59).** Every committed ply (human or AI move, or a forced
  pass) is appended to a private `undoHistory` of `UndoRecord`s — `(mover, move?, dice)` — via
  `recordTurn`, in lockstep with the entry added to `record.plies`. The live `Move` objects let
  `board.undo(move)` reverse board mutations exactly; passes carry `move == nil`.
  - `undo()` — half-move only (the **within-turn editing primitive**): peels the last committed
    half-move off `moveBuilder` while a move is being composed; no-op otherwise. `canUndo` is
    true only while `moveBuilder.built` is non-empty.
  - `undoOrStepBack()` / `canUndoOrStepBack` — what the persistent **Undo** button in `ControlsView`
    actually calls. It is `undo()` plus, in **manual-dice mode** (#110), a step back when nothing is
    left to peel: `stepBackToManualRoll()` either *unrolls* the current rolled-but-unrecorded turn
    (same mover) or pops the last recorded ply (reversing it on the board, trimming `undoHistory` +
    `record.plies`, clearing `diceReplays`), landing in `.awaitingRoll` for that ply's mover via
    `enterManualRoll(for:)` — so a sequence played at one set of dice can be rewound a ply at a time
    and re-rolled with different dice. Unlike `undoLastDecision` it steps a single ply (the human
    drives both sides here) and lands *before* the roll. In auto mode it is exactly `undo()`.
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
  rolls and `playAITurn` computes legal moves (empty = forced pass) — except in manual-dice mode
  (#110), where it pauses for the human to enter the AI's dice (see *Manual-dice mode* above) —
  then: with no model it picks a random legal
  move (applied synchronously under `.off` timings); with a model it enters `aiThinking` and runs
  the **multi-ply expectimax search** (`agent.getBestMove`) on a detached task **off the main
  actor**, hopping back via `MainActor.run` to apply the move — directly, or through the animated
  replay when `animationTimings.isAnimated` (see *AI-turn animation* above). `Agent` calls are
  wrapped in `try?` so a Core ML failure falls back to a random move. `winProbability` (WHITE's
  view: `mover == .white ? score : 1 - score`) updates only from a real model score and stays at
  its `0.5` default under the random fallback.
  Validated headless by `GameSessionAITests` (real-model game + missing-model fallback + the #110
  manual-dice both-players path; these pin `searchConfig: SearchConfig(maxDepth: 1)` and
  `animationTimings: .off` so full-game tests stay fast and synchronous — the search itself is
  covered by `AgentSearchTests`).

  **Board-copy isolation.** The search must not race the live `game.board`: the main actor keeps
  reading/scoring it (UI render, debug overlay) while the search applies/undoes thousands of times,
  and sharing one board would interleave the unbalanced pop/push and corrupt the checker counts. So
  `takeAITurn` snapshots `game.board.captureStacks()` + the dice on the main actor, and the detached
  task rebuilds an **isolated `GameBoard` copy** (`restoreStacks`) to search. Move generation is
  deterministic, so the copy's move list matches `liveMoves` index-for-index; the search returns the
  chosen **index**, which the main actor maps back to the live `Move` before applying. An
  out-of-range/`nil` index (Core ML failure) falls back to a random live move.

- **In-play analysis (#146).** With `inPlayAnalysis: true` (settable as `inPlayAnalysisEnabled`,
  default off in the engine, on via the app setting), `GameSession` accumulates each ply's 2-ply
  analysis *while the game is played*, into `analysisByPly` (exposed sorted as
  `inPlayAnalysis: [AnalysisEntry]`). The app logs it with the finished game so the review opens
  instantly (see *Save & load*). Two free sources:
  - **Opponent (AI) plies — captured from the AI's own search.** `getBestMove` already returns the
    chosen move, its score, and the depth it reached; `playAITurn` threads `depth` through to
    `applyAIMove`/`animateAITurn`, which call `captureAIAnalysis` right after `recordTurn`. The AI
    plays its best, so the stored entry has `played == best`, `playedScore == bestScore == score`
    (already the mover's win prob), and `depth` = the reached depth (2 under `.standard`). A forced
    AI move (single legal move → `getBestMove`'s sentinel score 0) and the random/no-model fallback
    are **not** captured (`legalMoves.count > 1` + non-nil score/depth guard); the review re-scores
    those plies instead.
  - **Human plies — ranked in the background during thinking time.** `beginTurn` (the single human
    chokepoint) calls `startHumanAnalysis`: off the main actor, on an **isolated board copy** (same
    `captureStacks`/`restoreStacks` isolation as the search), it runs the *same*
    `evaluateMovesNply(depth: 2)` over the *same* `legalMoves` the review uses — so the captured
    scores match a from-scratch review **exactly**. The result is staged in `humanAnalysisScores`
    (aligned to `legalMoves`) only if the turn hasn't moved on (an `analysisEpoch` staleness check).
    On commit, `completeMove` → `captureHumanAnalysis` keys the played move to its score (net-delta
    match) and the best to the argmax via the reused `GameReview.matchRecorded`/`argmax`, storing a
    `depth: 2` entry. If the ranking isn't ready (the player committed faster), nothing is stored
    and the post-game review fills that ply in.
  - **Cancellation.** `cancelHumanAnalysis` (cancel task, drop staged scores, bump `analysisEpoch`)
    runs from `newGame` (which also clears `analysisByPly`), `surrender`, and `enterManualRoll`. A
    within-turn `undo` deliberately does **not** cancel: the position returns to the same turn-start
    the ranking was computed for, so it stays valid (no recompute on move edits). Covered by
    `GameSessionAnalysisTests` (human capture == from-scratch review, opponent self-consistency,
    cancellation, seeded refine, disabled = no-op).

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
- **`GameSave.swift`** — the `GameRecord` value type (now with a stable `gameId: UUID`, #104) plus
  the Codable wire format. `PlyRecord { die1, die2, halfMoves: [[Int]] }` and `GameSave {
  schemaVersion, gameId?, name, savedAt, startingPlayer, aiColor?, outcome?, history, analysis? }`.
  **Schema versions (#104):** `currentSchemaVersion = 2`. A custom `Codable` keeps full back-compat —
  decoding treats `gameId`/`outcome`/`analysis` as optional (a v1 file has none), and **encoding
  derives the version from content**: a save *without* analysis is written at `schemaVersion: 1`
  (byte-compatible with a v1 reader), gaining the `2` marker only once an `analysis` block is
  attached. `AnalysisEntry { plyNumber, playedMove, playedScore, bestMove, bestScore, depth }` is the
  durable per-ply analysis (no `boardStacks` — reconstructed by replay; scores as `Double`; field
  names match the Python schema). `[AnalysisEntry](reviewResult:)` projects a `GameReviewResult`.
  Bridges: `GameSave(record:name:savedAt:analysis:)` flattens (carrying `gameId`/`outcome`), and
  `GameSave.record` reads back (a pre-#104 save gets a fresh `gameId`). Colors serialize as `rawValue`.
- **`SaveStore.swift`** — file-backed store, one pretty-printed JSON file per game under
  `directory` (the app uses `Documents/SavedGames`), `.iso8601` dates. One reserved **autosave**
  slot (`autosave.json`) plus any number of named manual saves (`save-<uuid8>.json`, so repeated
  names never clobber). The single autosave slot is overwritten on every move, so only the
  **last** in-progress game is ever kept. All IO is **synchronous** so the autosave completes
  before the app suspends. `list()` returns `SaveMetadata` (filename, name, savedAt, plyCount, isAutosave)
  newest-first, **skipping** unreadable or wrong-`schemaVersion` files; `load(filename:)` instead
  **throws** `SaveStoreError.incompatibleSchema` on a version mismatch. `writeAutosave` /
  `loadAutosave` / `clearAutosave` manage the reserved slot; `writeManual` returns the generated
  filename. `SaveStore.default()` roots it at `Documents/SavedGames`. Reads any schema **≤**
  `currentSchemaVersion` (so v1 *and* v2 both load); only a *newer* version throws/skips (#104).
- **`GameLogStore.swift`** (#104) — append-only log of **every finished game**, one JSON file per
  `gameId` (`game-<uuid>.json`) under `Documents/GameLog`, written from `GameSession.onGameOver`
  regardless of outcome or whether the game was ever manually saved (distinct from the single
  resume autosave slot, which `SaveStore` keeps). Reuses `GameSave` as the wire format, so a logged
  game is itself replayable. `append` writes/overwrites by id; `list()` returns `GameLogMetadata`
  (adds outcome/aiColor/`hasAnalysis`); `analysis(forGameId:)` reads a game's saved analysis and
  `attachAnalysis(_:forGameId:)` patches it back (bumping that file to v2). After a review,
  `GameReviewModel` writes its `analysis` back here, and on a later review/drill of the same game
  it loads the cached analysis and rebuilds via `GameReview.cachedResult` — no model, near-instant.
  **In-play analysis (#146):** the game-over hook also writes `session.inPlayAnalysis` straight into
  the logged game (`GameSave(record:name:analysis:)`, empty ⇒ stays v1), so the **first** review of a
  game played with analysis on already loads cached and only refines (see *Post-game blunder review*).

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
  At each ply where it's the **human's** move and the move was **not a forced pass** (empty
  half-moves), it ranks *every* legal move with `Agent.evaluateMovesNply` at `depth`
  (default **2** — fast, and the depth on-device play uses; the same parity-validated scoring the
  live AI uses), with **no wall-clock deadline** since analysis is offline. `evaluateMovesNply`
  capture/restores stacks, so the working board is never corrupted. The played move is located among
  the legal moves by **multiset-comparing `(from, to)` pairs** (order-independent — the recorded
  order may differ from the generator's; the Swift analogue of the CLI's structural `_pairs`/`_find`
  match). `onEvaluation` fires per evaluated ply **as it is scored** (lets the UI stream blunders —
  show the first one immediately while the rest are still being found); `progress` fires once per
  evaluated human ply with `(done, total)`. **Forced single-legal-move plies are evaluated too**
  (#131): they score their one move (best == played, zero gap) and are flagged `hadChoice: false`,
  so the review timeline runs unbroken to the final move instead of stopping short at the first
  forced bear-off ply. Earlier the `len(moves) <= 1` skip dropped them and the review visibly
  ended before the real game end.
- **`GameReview.analyzeProgressive(record:agent:humanColor:depths:…onEvaluation:onPassComplete:progress:)`**
  (#103) — deepening analysis that streams. Replays the record **once** into a list of `PlyContext`
  (each captures a human ply's pre-move `boardStacks`, dice, mover, played pairs), then scores them
  in passes: **1-ply** over all plies first (so the graph + drill are usable immediately), then
  **2-ply** over **every real-choice ply** — clear blunders included, because the *displayed best
  move* must be accurate and ranking the candidates is what finds it — then **3-ply** for only the
  ones still too close to call (`absoluteGap ≥ 0.5%` and `relativeGap` in **5–15%**, the band around
  the 10% threshold where the extra depth can flip the verdict). Each pass rebuilds an isolated
  board from the stored stacks (no live `Move`/`Point` kept across passes). Every (re)scored ply is
  emitted via `onEvaluation` carrying its current `depth`; the consumer **keys by `plyNumber`** and
  replaces shallower results. `onPassComplete(pass, depth)` fires per finished pass (pass 0 = the
  1-ply base). Forced plies (`hadChoice == false`) never deepen. With **`includeOpponent: true`**
  (#132) the AI's plies are evaluated too, so the review can step through and annotate them — they
  deepen to **2-ply** like the human's (a 1-ply best is too noisy to match what the strong AI
  actually played) but **not to 3-ply** (only the human's plies are flagged/drilled, so the
  borderline refinement is theirs alone). Each evaluation carries its `mover`, so the consumer keeps
  blunder flagging and the drill to the human's own plies.
  **`seed:` (#146)** — pre-computed analysis (the in-play 2-ply written during the game, or a full
  prior review) to start from. Each seeded ply is placed into the working set at its stored `depth`,
  and a pass **skips** any ply already at/beyond that pass's depth (`alreadyDeep`). So a complete
  2-ply seed makes the 1-/2-ply passes no-ops and leaves only the human's borderline plies to refine
  at 3-ply — the review opens with no visible 2-ply pass. An empty seed reproduces the original
  full 1→2→3-ply behaviour exactly (pre-#146 logs / analysis-off games review unchanged).
- **`PlyEvaluation`** — one analyzed human ply: 1-based `plyNumber`, dice, the **pre-move**
  `boardStacks` snapshot (for rendering the position faced), `mover`, the `playedMove`/`bestMove`
  `[from,to]` pairs and their win-probability scores (for `mover`), `hadChoice` (false ⇒ a forced
  ply the UI labels "Only move available" rather than praising), `depth` (the search depth this
  result was scored at — 1/2/3 under progressive analysis), plus derived `relativeGap`
  `(best − played)/best`, `absoluteGap`, and `isBlunder(threshold:)`.
- **`GameReviewResult`** — every analyzed ply (`evaluations`); `blunders(threshold:)` filters to
  those whose relative gap meets the threshold. The consumer filters at any threshold (the iPad UI
  fixes it at **10%**, matching the CLI default; a configurable one is tracked in #77).

The app side (`GameReviewView` + its `@MainActor GameReviewModel`) first reads any saved analysis
(`GameLogStore.analysis(forGameId:)` — the in-play 2-ply, #146, or a prior review, #104), **seeds**
the view from it via `GameReview.cachedResult` (so the graph/pager/drill are instant) and passes it
as `seed:` to `analyzeProgressive`. With a complete 2-ply seed only the 3-ply borderline refinement
runs, and since the phase is already `.reviewing`, `report` never shows the "Analyzing…" pass. Then
it runs `analyzeProgressive` on a detached task and streams results back via `onEvaluation`,
**upserting by `plyNumber`** so a deeper pass replaces the shallower result in place, and writes the
merged (possibly deepened) analysis back with `attachAnalysis`. With no seed (a game played with
analysis off, or a pre-#146 log) it runs the full pass exactly as before. The pager opens as soon as
the first ply is scored; the
win-probability graph and the drill become available once the 1-ply base pass completes
(`firstPassComplete`, set from `onPassComplete(pass: 0)`), while the 2-/3-ply passes refine live (a
small spinner by the move counter shows until all passes finish). The screen is a **full-screen,
board-centric** mode (a `fullScreenCover` from the win overlay): the position the player faced fills
the screen, with a panel (played→best + win-prob gap, the Your-move/Compare overlay) and
Prev/Next/swipe to page through moves. Both sides' moves are shown (#132): each card is tagged You
or **TavTav** (the AI persona), opponent cards annotate TavTav's played/best, and an "All moves /
My blunders" toggle jumps navigation only between your own blunders. Blunder flagging, the chart
rings, and the drill stay scoped to the human's plies (filtered by `mover == humanColor`). The drill
is launched the same way, with the current `GameReviewResult` handed over as a precomputed result.

## Post-game drill (#63)

The interactive sibling of the review — the on-device analogue of the CLI's `drill` command
(`play/loop.py:_handle_drill` / `_drill_inner`): step through the same blunders, and for each, ask
the player to find a better move **on the real board**. It reuses #62's blunder detection
(`GameReview`/`PlyEvaluation`) and two small additions to `GameSession`:

- **Attempt mode** (`onMoveAttempt: (@MainActor (Move) -> Void)?`). When set, the session runs in
  attempt mode: completing a move (via the normal `commitHalfMove`/`confirm` tap flow) reports it
  to the hook instead of recording it and advancing the turn. `record.plies`/`undoHistory` and the
  turn are left untouched, so a finished game's record is never mutated. By default the move is then
  **rolled back** immediately (`board.undoHalfMove` per built half-move, then `beginTurn()` re-arms
  `.picking` at the same dice) so the player can re-attempt. With **`holdAttempts == true`** (#114)
  the move instead **stays on the board** (input locked: selection/legal-moves cleared) and
  `heldAttempt` holds it; `retryAttempt()` is the explicit rollback (undo + `beginTurn()`). Both
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
solved/skipped for the "Drill complete" summary. Launched **from the review screen** (#130) — the
win overlay offers Review only; the in-review "Drill blunders" button hands over the already-computed
`GameReviewResult`, so the drill never re-analyzes.

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
│                                GameSessionAITests, GameSessionAnimationTests,
│                                GameSessionAnalysisTests, GameSavePersistenceTests
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
