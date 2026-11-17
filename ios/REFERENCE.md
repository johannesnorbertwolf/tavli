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
  **Legal play order (#169).** The bag would accept a legal move's halves in any order, incl.
  orders no player may play (the engine's canonical order is not always one either: house Plakoto
  lists `[22→25, 18→19]` for dice 3·1, standard Plakoto sorts its halves). So every play must also
  pass the variant's `isLegalStep(from:to:color:die:on:)` at the position it is played, for one of
  the still-unplayed dice (`diceStates`, a set of remaining-dice multisets per built half — a
  bear-off may be playable by more than one die). Portes/Fevga/standard Plakoto answer it with
  their own generator's step rule (`isStep`), house Plakoto with the protocol default. Enforced:
  Portes bar-first; bear-off only once every checker is home (bar included); larger-die bear-off
  only from the rearmost point; Fevga's first-checker lock. Before this, the builder let a player
  break each of these in all four variants. Commits are judged on the turn-start position replayed
  through `built`; far-endpoint chains are simulated on a scratch board. Without dice
  (`die1 == 0`, tests) only board playability is checked.
  **Routes (#169).** Portes never merges (a two-dice checker move is two halves in the legal list,
  since an intermediate hit matters), so the same chaining also offers its far endpoints — but
  `src→a→dst` and `src→b→dst` may end in different positions. `routeOptions(from:to:)` collects
  the **shortest** hop chains to `dst` that are prefixes of a surviving move (so the legal list,
  incl. bar-first and use-max-dice, decides what exists), applies each on a scratch board copy and
  keeps one chain per distinct resulting position (first in search order). One option → play it;
  several → the session asks (never auto-resolved). Plakoto/Fevga unmerged routes always end in the
  same position (a pin made in passing is released), so they keep playing directly; doubles have
  fixed intermediates, so they never ask. Engine move representation and Python parity untouched.
  **Gestures.** `commit(halfMoves:)` commits one player gesture's hops together (`commit(halfMove:)`
  is a one-hop gesture); `lastGesture` / `undoGesture()` take the whole last gesture back.
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
  same guards the intents already use. Intents: `roll` / `setDice(_:_:)`
  (deterministic dice for scripted play — tests, previews, the `-uiTestGame` hook, the drill
  seeder; always starts a human turn, #176) / `selectPoint` / `commitHalfMove(from:to:)` /
  `undo` / `undoLastDecision` / `confirm` / `surrender` / `newGame`. On roll it computes `legalMoves` via
  the variant's `legalMoves` (Plakoto: `PossibleMoves`); an empty set is a **forced pass** that advances the turn. `commitHalfMove`
  applies the half-move to the board and auto-finishes when the move is complete or the only
  continuation is itself legal. Win detection uses `game.getWinner()`; `finishTurn` records the
  ply, switches turn, and returns to `awaitingRoll`.
  **Pending roll (#171).** `pendingRoll: PendingRoll?` (published) is set by `markRolled()` the
  moment dice exist for the side on move — `rollDice()` (tap, auto-roll, the AI's roll, replayed
  dice), `setDice`, `undoLastDecision` — and cleared by `recordTurn` (the roll became a
  ply), `surrender`, `newGame` and `replay`. `rollRevision`
  (published `Int`) is bumped on every set and when the roll is dropped without a ply; `GameView` observes it to
  write the autosave as soon as a roll exists (alongside the existing per-ply
  `history.count` trigger). Half-moves already picked are **not** tracked: a resumed turn
  restarts with the full roll.
  Published read-state (`phase`, `legalMoves`, `selectedPoint`, `validTargets`, `selectableSources`,
  `winProbability`, plus `aiDiceRolling`/`aiHopInFlight` for the AI-turn animation, #93) is the
  view contract. No rendering lives here.

- **Manual dice entry removed (#174, #176).** The manual-dice mode (#110: human enters the AI's
  dice, `manualDiceEntry`, the Undo step-back to dice entry) is gone from the engine.
  `takeAITurn` is just `rollDice()` + `playAITurn(animateDiceRoll: true)`.

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
     the random fallback and the forced pass skip straight to `animating`. (A resumed pending roll,
     #171, calls `playAITurn(animateDiceRoll: false)` so the roll window is 0 — no tumble.)
  2. Once the move is chosen, `animateAITurn` (phase → `animating`) sleeps out the *remainder* of
     the tumble window (`rollDuration`, 0 for a restored roll), then clears `aiDiceRolling` — the dice
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
  - `undo()` — the **within-turn editing primitive**: peels the last committed **gesture** off
    `moveBuilder` (`lastGesture`, reversed on the board) while a move is being composed — a single
    step, or all hops of a Pasch multi-hop / Portes two-dice gesture at once (#169; before #169 a
    multi-hop gesture was peeled hop by hop); no-op otherwise. `canUndo` is
    true only while `moveBuilder.built` is non-empty.
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
  rolls and `playAITurn` computes legal moves (empty = forced pass), then: with no model it picks a random legal
  move (applied synchronously under `.off` timings); with a model it enters `aiThinking` and runs
  the **multi-ply expectimax search** (`agent.getBestMove`) on a detached task **off the main
  actor**, hopping back via `MainActor.run` to apply the move — directly, or through the animated
  replay when `animationTimings.isAnimated` (see *AI-turn animation* above). `Agent` calls are
  wrapped in `try?` so a Core ML failure falls back to a random move. `winProbability` (WHITE's
  view: `mover == .white ? score : 1 - score`) updates only from a real model score and stays at
  its `0.5` default under the random fallback.
  Validated headless by `GameSessionAITests` (real-model game + missing-model fallback + these pin `searchConfig: SearchConfig(maxDepth: 1)` and
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

- **In-play analysis (#146, #108).** With `inPlayAnalysis: true` (settable as `inPlayAnalysisEnabled`,
  default off in the engine and off via the app setting — the background sweep competed with the AI's
  own move search and slowed its turn, so play stays snappy and the review deepens progressively when
  opened instead), `GameSession` accumulates each ply's 2-ply
  analysis *while the game is played*, into `analysisByPly` (exposed sorted as
  `inPlayAnalysis: [AnalysisEntry]`). The app logs it with the finished game so the review opens
  instantly (see *Save & load*). **Both sides are ranked the same way** (#108): the AI's *play*
  search can be weakened (1-ply + selection noise, see *AI strength*), so its plies must be graded by
  the same full-strength yardstick as the human's rather than reusing the play search.
  - **Background ranking, both sides.** Each turn's chokepoint — `beginTurn` for the human,
    `playAITurn` for the AI — calls `startMoveAnalysis`: off the main actor, on an **isolated board
    copy** (same `captureStacks`/`restoreStacks` isolation as the search), it runs the *same*
    `evaluateMovesNply(depth: 2)` over the *same* `legalMoves` the review uses — so the captured
    scores match a from-scratch review **exactly**, and at depth 2 regardless of the difficulty
    setting (the σ noise lives only in `getBestMove`'s final pick, never in `evaluateMovesNply`). The
    result is staged in `humanAnalysisScores` (aligned to `legalMoves`) only if the turn hasn't moved
    on (an `analysisEpoch` staleness check). On commit (`completeMove` for the human,
    `applyAIMove`/`animateAITurn` for the AI), `captureMoveAnalysis` keys the played move to its score
    (net-delta match) and the best to the argmax via the reused `GameReview.matchRecorded`/`argmax`,
    storing a `depth: 2` entry — honest `played`-vs-`best`, so a weakened AI's suboptimal plies show
    up like a human's. If the ranking isn't ready (the mover committed faster than it computed —
    common for the AI with animations off), nothing is stored and the post-game review fills that ply
    in.
  - **Cancellation.** `cancelHumanAnalysis` (cancel task, drop staged scores, bump `analysisEpoch`)
    runs from `newGame` (which also clears `analysisByPly`), and `surrender`, and
    at the start of each `startMoveAnalysis`. A within-turn `undo` deliberately does **not** cancel:
    the position returns to the same turn-start the ranking was computed for, so it stays valid (no
    recompute on move edits). Covered by `GameSessionAnalysisTests` (human capture == from-scratch
    review, weakened-opponent honest grading, cancellation, seeded refine, disabled = no-op).

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
  `selectionNoise` (σ, default 0) is the **AI-strength dial** (see *AI strength*).

- **AI strength (#108).** The settings slider tunes how strongly the AI plays by mapping `aiStrength`
  (0…1, default 1.0) onto two `SearchConfig` knobs (`AppSettings.searchConfig`): **full strength**
  (slider max) is the unchanged 2-ply argmax (`maxDepth: 2`, `selectionNoise: 0`); **below max** the
  *play* search drops to `maxDepth: 1` and `selectionNoise` rises linearly to `aiSigmaMax` at the
  weakest, so a weaker opponent occasionally — and, at the weakest, only seldom blunders — passes up
  its best 1-ply move. The noise is applied **only** in `getBestMove`'s 1-ply selection (below), so
  leaf scoring and the in-play/review analysis stay full-strength and noise-free. `GameSession.searchConfig`
  is mutable and the view keeps it in sync (`GameView`), so the slider takes effect on the AI's next
  move mid-game. Online matches have no AI side and ignore it.

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
  - `getBestMove(…timeBudget:…maxDepth:rootSoftBudget:minRootBranches:maxRootBranches:selectionNoise:noiseSeed:)`
    — **2-ply baseline + anytime deepening** under a wall-clock `DispatchTime` deadline (this replaced
    the earlier iterative-deepening loop). Single move → fast path (depth 1, index 0). When
    `maxDepth <= 1` (the strength slider's weakened mode, #108): score every move 1-ply and select over
    **all** of them via `selectIndex` — plain argmax at `selectionNoise == 0`, else argmax of the
    scores perturbed by iid Gaussian(0, σ) (Box–Muller, seedable via `noiseSeed`/`SplitMix64` for
    tests), returning that pick at depth 1. Otherwise (full strength): (1) score every root move 1-ply
    and take the best-first candidate set within `relativeCutoff`, capped at `maxRootBranches`; (2) **2-ply baseline** — score the whole candidate set at depth 2 (the
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

## Game variants (#136; ports #137 Portes, #138 Fevga, #139 standard Plakoto)

The rules seam — `GameVariant.swift` — mirrors the Python `RuleSet` ABC
(`domain/ruleset.py`). Each concrete variant ports its Python module and is pinned to it
by generated parity fixtures.

- **`protocol GameVariant: Sendable`** — rules: `id` (stable persisted string),
  `modelResourceName`, `setUpInitialPosition(on:)` (must `board.clear()` first — the board is
  reused by `newGame`), `legalMoves(on:color:dice:) -> [Move]` (deterministic; empty = forced
  pass), `applyHalfMove`/`undoHalfMove(_:on:)` (strict inverses), `apply`/`undo(_ move:on:)`
  (default: halves in order / reverse), `hasWon`, `isOpen(_:for:on:)`, `resultPoints`,
  `makeEncoder(config:) -> any BoardEncoding`.
- **Outcome seam** (protocol requirements with Plakoto defaults, mirroring `RuleSet`):
  `maxPoints` (1), `randomStartingPlayer` (false), `isOver(on:)` (either side `hasWon`),
  `outcome(on:) -> (winner: Color?, points: Int)` (`nil` winner = draw, 0 points; WHITE
  checked first), `terminalValue(on:perspective:) = 0.5 + signed/(2·maxPoints)` (1/0 for
  Plakoto, 0.5 draw, 0.75/0.25 for a 2-point variant's single win), and
  `endsOnlyByMoverWin` (true unless the variant overrides `isOver` — Python's
  `_mover_win_only`). Extension helpers: `winner(on:)` (nil while running **or drawn**),
  `startingPlayer(default:)` (coin flip when `randomStartingPlayer`).
- **Geometry hooks** (shared code must not assume `dst = src + color*die`):
  `pathIndex(of:for:boardSize:)` / `point(atPath:for:boardSize:)` (default: White = point,
  Black = `boardSize+1-point`; off = `boardSize+1`; Portes bar = path 0), `bearOffPoint`,
  `movableCount(at:for:on:)` (default `Point.movablePieces`; Portes counts bar checkers), and
  `intermediatePoints(of:die1:die2:on:)` — the midpoints through which a **merged** single-half
  two-dice move can legally be split. `MoveBuilder.unmerge` and its playability check use only
  these hooks. The default is Plakoto's (exact distance `d1+d2` along the path, landable
  midpoint); standard Plakoto / Fevga check each hop with their own rules (incl. larger-die
  bear-off and Fevga's first-checker rule, so an "open but illegal" midpoint is never offered);
  Portes returns `[]` (it never merges).
- **`BoardEncoding`** — `inputSize` + `encode(_:isWhitesTurn:)`. `BoardEncoder` (`unary_v3`,
  486), `PlakotoStdEncoder` (`plakoto_std_v1` = unary_v3 + 8 mother/borne-off features, 494),
  `FevgaEncoder` (`fevga_v1`, 406, mover's path order = rotation by 12 for Black),
  `PortesEncoder` (`portes_v1`, 414). Ratios are computed in `Double` then narrowed, like numpy.
- **Variants.**
  - `PlakotoVariant` — adapter over the unchanged port (`GameBoard`, `PossibleMoves`,
    `BoardEncoder`); `resultPoints` 1. Only change: `setUpInitialPosition` clears the board
    first (a reused board used to keep its trays).
  - `StandardPlakotoVariant` (`plakoto_standard`) — Plakoto stack mechanics; port of
    `domain/plakoto_standard_moves.py` (max-dice, larger-die rule, larger-die bear-off from the
    highest point; merged single half for one checker on both dice); mother rule (draw when both
    mothers pinned, 2 points for a mother win, 2 when the loser bore off none);
    `endsOnlyByMoverWin == false`.
  - `FevgaVariant` (`fevga`) — single-colour stacks, trays hold borne-off; Black's path wraps
    (13…24, 1…12, off at 0) via `FevgaGeometry`; port of `fevga_legal_moves` (DFS over sequences
    and prefixes, dedup by an additive position hash, R1/R2 end-of-move filter, dice obligation),
    one `Move` per resulting position in Python's insertion order; mars = 2.
  - `PortesVariant` (`portes`) — port of `domain/portes_move_generation.py` (bar entry first,
    hits, larger-die rules; never merged halves); gammon = 2, no triple.
  All three have `maxPoints == 2` and `randomStartingPlayer == true`.
- **Board state.** `GameBoard` (stack of colours per point, `0`/`boardSize+1` = the ends) is the
  shared container; a pin is just stack order. **Portes' bar** uses the same indices as Python
  (White bar = 0, Black bar = 25, so `[0, d]` is a White entry and `[s, 25]` a White bear-off).
  Each end stack holds one colour's borne-off checkers *below* the other colour's bar checkers —
  `points[0] = [Black off…, White bar…]`, `points[25] = [White off…, Black bar…]` — so the
  position lives entirely in the stacks: `captureStacks`, replay, review/drill boards
  (`boardStacks`), saves and online payloads (which store only move pairs) need no new fields
  and stay backward-compatible. A hit can't be recovered from the after-position, so Portes
  pushes one flag per applied half on `GameBoard.undoLog` (LIFO, popped by undo).
  `captureSnapshot()`/`restore(_:)` capture stacks **and** the log depth; use them (not
  `captureStacks`) around code that might abandon an apply (Agent 1-ply scoring, session
  replay validation). `PortesVariant.setPosition`/`signedSlots`/`barCount`/`borneOffCount`
  convert to/from the Python layout.
- **Game end through the variant.** `Game.isOver()`/`getWinner()`/`outcome()` call the variant.
  `GameSession` ends a turn when `isOver`: `.gameOver(winner: Color?)` (`nil` = draw),
  `record.outcome`/`isDraw`/`points` (points only when `maxPoints > 1`, so Plakoto records are
  unchanged), `onGameOver(winner)` for wins only (as before) and `onGameFinished(winner, points)`
  for every end. `GameSave` writes `outcome: "draw"` for a draw (not a `Color` raw value, so
  older readers see "no winner") and an optional `points` key (absent for Plakoto). Replay and
  `GameReview` stop on `isOver`.
- **Agent.** Leaves mirror `ai/agent.py`: after a candidate, `endsOnlyByMoverWin ?
  hasWon(mover) : isOver` decides terminal, scored `terminalValue(perspective: mover)` (exactly
  1.0 for Plakoto). `GameReview.matchRecorded(_:_:on:mover:)` disambiguates moves with the same
  net delta (Portes: `10→14→15` hitting on 14 vs `10→11→15`) by resulting position.
- **Persistence ids.** `GameRecord.variantID`, `GameSave.variant`, `OnlineMatchPayload.variant`
  are always written; absent ⇒ `"plakoto"`. `GameConfig(variantID:)` resolves unknown ids to
  Plakoto. `GameSession.makeAgent` loads `variant.modelResourceName` via `ModelCatalog.main`.
- **Models + gating (#143, `ModelCatalog.swift`).** `ModelCatalog` resolves a variant's model
  (`.mlmodelc`, else `.mlpackage` compiled at load) from a bundle / directory / custom lookup;
  `isAvailable(variant)` is the vs-AI gate — the app never builds a vs-AI session (new, resumed
  or auto-resumed) for a variant without its model; it shows "AI not available yet" and offers
  two-player play instead. The new variants' models (`PlakotoStandardValue`, `FevgaValue`,
  `PortesValue`) are optional: `setup.sh` converts each from its config's `gold_model_path`
  once that checkpoint exists, and any `<Name>Value.mlpackage` dropped into
  `TavliApp/Resources/` (then `setup.sh` to regenerate the project) enables it. Only
  `PlakotoValue` is required by the `project.yml` build guard (the others only warn).
  `VariantPreference` persists the chosen id under `settings.variant` (unknown → Plakoto).
- **Display mapping (#143, `BoardLayout.swift`).** Views draw *display slots*: engine 0…25,
  with each colour's bar checkers split out of the end stacks into slots 26 (White) / 27
  (Black). Purely hook-driven: a checker of colour `c` at end `e` is borne off iff
  `e == bearOffPoint(c)`, on the bar iff `pathIndex(e, c) == 0`. `displayStacks`,
  `displaySlot(forSource:)` / `sourcePosition(forDisplaySlot:)` (trays are never sources),
  `borneOffCount`/`barCount`, and `hits(from:to:)` (bar growth → hit animation). For every
  variant but Portes the display is the engine stacks plus two empty bars.
- **Results + matches (#143).** `GameRecord.result` → `MatchGameResult` (winner + points, or
  `.draw`). `MatchState` stores `results` and scores **points** (`score(for:)`; a double game
  counts 2, a draw 0 and extends `maxGames`); `wins(for:)` still counts games. Codable writes
  `results` plus the legacy `gameWinners`; legacy JSON decodes as 1-point wins. Online
  `GameLog` gains optional `drawn`/`points` keys (omitted for Plakoto, so its payloads are
  unchanged); `OnlineMatchPayload.matchState` is built from `completedGameResults`.
  `reportsEquity`/`equity(fromValue:)` convert a `maxPoints > 1` value to expected points.
- **Full Tavli (#144, `FullTavliSession.swift`).** Pure `Codable` session: the fixed legs
  `portes`, `fevga`, `plakotoVariantID` (`plakotoLegVariantID(preferredID:)` — `plakoto_standard`
  only when that is the saved preference, else house `plakoto`; fixed at creation), `aiColor`
  (`nil` = two-player) and `results: [MatchGameResult]`. `record`/`recordGame(winner:points:)`
  appends the current leg (points clamped to the leg's `maxPoints`, so house Plakoto = 1; a
  draw = 0 and still advances; no-op once complete). `score(for:)` sums points; after three legs
  `winner` is the higher total, equal totals `isDrawn` (no tiebreak). `currentLegIndex`/
  `currentVariant` (nil when complete), `legIndex(ofVariantID:)`. AI gate:
  `isAIAvailable(in: ModelCatalog)` needs **every** leg's model (`unavailableLegVariantIDs`).
  Persistence: `GameSave.fullTavli` (optional key, written only when present — schema version
  unchanged, older files decode as `nil`; `SaveMetadata.fullTavli` for the picker);
  `GameSession.snapshot(name:fullTavli:)`. `resume(savedGame:)` → `.inLeg(index)` /
  `.betweenLegs(nextIndex)` / `.complete`, judging "finished" by the saved record's
  outcome/draw (a surrendered game replays non-terminal) and recording a finished leg the
  session had not counted yet (never twice). Covered by `FullTavliSessionTests`.
- **Parity tests** (`VariantParityTests.swift`, fixtures from `generate_test_fixtures.py
  --variant <id>`, gitignored like Plakoto's): metadata, encodings (≤1e-6), exact ordered
  legal-move lists for all 21 rolls per sampled position plus apply → Python afterstate and undo
  → original for every move, outcomes (draws, 2-point wins, terminal values), and agent 1-ply /
  2-ply scores against Python with a seeded random-init net exported to Core ML by the same
  script (`convert_to_coreml.py --variant/--checkpoint/--out`). `VariantPlayTests.swift` covers
  MoveBuilder composition, full sessions + save replay, the draw path and timings.
- **Hot path.** Calls go through `any GameVariant` (one witness-table hop each). Release-build
  `legalMoves` per call over mid-game samples: Plakoto ≈36 µs, standard Plakoto ≈19 µs, Fevga
  ≈35 µs, Portes ≈37 µs (`VariantPlayTests.testLegalMoveTiming`).

## Move notation (#178)

`MoveNotation.swift` turns one turn — dice + recorded `[from, to]` pairs + the mover — into
readable backgammon-style notation, shared by the history sheet, review and drill. Pure; it
copies the given position and replays the pairs on the copy, because hits, pins and the mother
are not stored in `PlyRecord`.

**API.** `describe(_ pairs:die1:die2:mover:before:)` (a `GameBoard`, untouched) or
`describe(...stacks:config:)` (e.g. `PlyEvaluation.boardStacks`); `game(_ plies:startingPlayer:
config:)` replays a record from the variant's starting position, movers alternating (as
`GameSession.replay`). Result: `highDie`/`lowDie`, `segments: [Segment]` (each `from: Place`,
`stops: [Stop]` (place + optional `Mark`), `count`), `motherPinned`, `noMove`, and the plain
renderings `diceText` (`64`), `moveText` (`13/7^ 8/4` / `No move`), `text`
(`64: 13/7^ 8/4`, ` (mother pinned)` appended when set).

**Rules.**
- **Numbering** from the mover's side: `number = boardSize + 1 − variant.pathIndex(point,
  mover)`; `≥ 25` → `bar` (Portes path index 0), `≤ 0` → `off`. Via the path hooks, so Fevga's
  wrapped Black path and Portes' bar/off ends (index 0/25 swap meaning with the mover) need no
  special cases. White's start is its 24 point; Black's physical numbering in Plakoto/Portes
  already equals its notation.
- **Segments**: each half is chained onto the segment whose checker just arrived at its source
  (`lastIndex` of a segment ending there), so Plakoto/Fevga doubles (one half per die) and
  Portes (one half per die, never merged) read as one checker path; an intermediate stop is
  kept only when it was a **hit** (`13/7*/5`). A merged Plakoto/Fevga half is already one
  segment. Sorted by `from` descending (bar = 25, off = 0), ties by the farther landing first;
  identical paths group to `(n)` with their marks merged.
- **Hit** (`*`): the opponent had checkers on the landing point before the half and none after,
  on a board point (Portes only in practice; a Plakoto pin keeps the opponent underneath).
- **Pin** (`^`): Plakoto house + standard — a point the mover has captured in the **final**
  position but not before (`Point.isCaptured(by:)`), so a blot landed on and left mid-double
  is not marked and adding to an existing pin is not a new pin. Never for Portes/Fevga.
- A landing mark goes on the **first** segment (display order) landing on that point.
- **Mother** (standard Plakoto only): `StandardPlakotoVariant.motherPinned(opponent)` false
  before and true after — the engine's own mother rule, so it is exactly the pin that decides
  the game. House Plakoto never sets it.
- **No move**: empty pairs → `noMove`, no segments.

Tests: `MoveNotationTests` (all four rule sets, both colours, off/bar, doubles, hit chains,
pins, mother, pass, ordering, whole-game replay).

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
  ever taken at clean turn boundaries for the *history* — partially built half-moves are never
  serialized (a deliberate simplification); only the turn's rolled dice are, as `pendingRoll`
  (#171, see `GameSave.swift` below). `newGame` resets the whole `record` (preserving `aiColor`).
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
  **Pending roll (#171).** When the save carries a valid `pendingRoll` and the replayed game is
  not over, `resume` sets those dice, publishes them as the session's `pendingRoll` (so an
  immediate re-snapshot keeps them) and arms a private `restoreRollOnStart`; the session still
  sits at `.awaitingRoll`. `start()` (or a stray `roll()`) then consumes it via
  `resumePendingRoll()` **instead of** rolling: human mover → `beginTurn` (→ `.picking`, or the
  ordinary forced-pass path when the roll has no legal move — incl. the auto-roll 0.5 s pass
  beat); AI mover → `playAITurn(animateDiceRoll: false)` (searches and plays those dice, no
  tumble). This bypasses the auto-roll gate, so it holds with auto-roll on (an explicit
  `setDice` before `start()` supersedes it), in two-player
  games, in every variant and inside a Full Tavli leg. Online sessions never carry one (their
  state is the Game Center payload, unchanged; their `GameView` has no autosave hook).
- **`GameSave.swift`** — the `GameRecord` value type (now with a stable `gameId: UUID`, #104) plus
  the Codable wire format. `PlyRecord { die1, die2, halfMoves: [[Int]] }` and `GameSave {
  schemaVersion, gameId?, name, savedAt, startingPlayer, aiColor?, outcome?, history, analysis? }`.
  **Schema versions (#104):** `currentSchemaVersion = 2`. A custom `Codable` keeps full back-compat —
  decoding treats `gameId`/`outcome`/`analysis` as optional (a v1 file has none), and **encoding
  derives the version from content**: a save *without* analysis is written at `schemaVersion: 1`
  (byte-compatible with a v1 reader), gaining the `2` marker only once an `analysis` block is
  attached. **`pendingRoll` (#171)** — `PendingRoll { die1, die2 }`, the dice of the turn in
  progress (a double is two equal values), mover implied by the history parity. Written only when
  present (like `fullTavli`, it never changes `schemaVersion`), so a save between turns is
  byte-identical to the pre-#171 format and an older reader just ignores the key. Decoding is
  tolerant: a malformed value or dice outside 1…6 decode as `nil` (the save still loads, awaiting
  a roll). `snapshot(name:)` / `snapshot(name:fullTavli:)` copy the session's `pendingRoll`;
  `GameSave(record:…)` (the game log) never sets it. `AnalysisEntry { plyNumber, playedMove, playedScore, bestMove, bestScore, depth }` is the
  durable per-ply analysis (no `boardStacks` — reconstructed by replay; scores as `Double`; field
  names match the Python schema). `[AnalysisEntry](reviewResult:)` projects a `GameReviewResult`.
  Bridges: `GameSave(record:name:savedAt:analysis:)` flattens (carrying `gameId`/`outcome`), and
  `GameSave.record` reads back (a pre-#104 save gets a fresh `gameId`). Colors serialize as `rawValue`.
- **`SaveStore.swift`** — file-backed store, one pretty-printed JSON file per game under
  `directory` (the app uses `Documents/SavedGames`), `.iso8601` dates. One reserved **autosave**
  slot (`autosave.json`) plus any number of named manual saves (`save-<uuid8>.json`, so repeated
  names never clobber). The single autosave slot is overwritten on every move and every roll (#171), so only the
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

The app wiring (autosave after every move, every roll (#171) and on background, auto-resume on launch, the
saved-games list, and the in-game manual save) lives in `RootView`/`GameView` — see
`Views/CLAUDE.md`.

## Online multiplayer (#134, Game Center)

Two people on separate devices play over the internet via **Game Center turn-based matches**
(`GKTurnBasedMatch`) — no server to run. The whole feature rests on the replay-based state
model above: **a match's entire state is its ply log**, so sync, persistence, and reconnection
are all "decode + replay", with no board state to reconcile.

- **The match data is an `OnlineMatchPayload` (`OnlineMatch.swift`, engine).** Schema **v2** (#145):
  `{ schemaVersion, targetWins, startingPlayer (raw "W"/"B", the game-1 starter), colorByPlayerID:
  [gamePlayerID → raw colour], games: [GameLog] }`, where `GameLog = { plies: [PlyRecord], winnerRaw }`.
  Each game's ply log uses the same `PlyRecord` wire type as a save; an explicit colour assignment lets
  each device compute its own side independent of turn order. The last `games` element is the
  current/just-finished game; every earlier game is complete (has a `winner`). A **single game is just
  `targetWins == 1` with one `GameLog`**, so the #134 and #145 paths share one shape. Helpers:
  `completedGameWinners`, `matchState` (a `MatchState` view of the score), `currentGameIndex`,
  `startingPlayer(forGameIndex:)` (alternates from the base), `gameSave(forGameIndex:)` (a `GameSave`
  view for the rebuild path), and `pendingPlies(fromGameIndex:plyCount:)` (the diff applied during
  live play, which may cross a game boundary). `encoded()`/`decoded(from:)` rejects a newer
  `schemaVersion`; **a v1 payload still decodes** — its flat `plies` map to one `GameLog`, `targetWins`
  1. Stored verbatim in `GKTurnBasedMatch.matchData`; a best-of-three is a few KB, far under Game
  Center's limit. Covered by `OnlineMatchTests`.

- **Match score — `MatchState` (`MatchState.swift`, engine).** A pure `Codable` value type shared by
  the offline (vs-AI) and online surfaces: `{ targetWins, baseStartingPlayer, gameWinners: [Color] }`
  with derived `wins(for:)`, `completedGames`, `currentGameNumber`, `maxGames`, `matchWinner` /
  `isComplete` (a 2–0 short-circuits the third game), and `currentStartingPlayer` (alternates from the
  base so games 2+ need no opening-roll ceremony and both online devices agree). `recordGame(winner:)`
  is a no-op once decided. Covered by `MatchStateTests`.

- **Applying a remote ply — `GameSession.applyRemoteMove(_:) -> Bool` (#134).** An online game is an
  ordinary **human-vs-human** session (`aiColor == nil`); a networked move is structurally the AI
  move the session already animates, so it funnels through the same path (`animateAITurn`, or a
  synchronous apply when `animationTimings.off`). The ply carries its own dice (the active player
  rolled locally and broadcast them); the receiver sets those dice, regenerates the legal moves, and
  **validates by outcome** — the ply is legal iff applying it reaches the same board as some legal
  move. Outcome comparison (not half-move identity) is required because the *same* physical move is
  recorded differently by side: a single-checker two-die move is stored **merged** (`1→9`) by the
  move generator but **unmerged** (`1→4,4→9`) when a human plays it via `MoveBuilder`, and both
  replay to the identical position. Returns `false` without mutating on an illegal/malformed ply or
  one arriving outside `.awaitingRoll` (a desync) — the coordinator then rebuilds from the
  authoritative log. An empty `halfMoves` is a forced pass, legal only when there are no legal moves.
  Covered by `GameSessionRemoteTests` (accept/reject/pass/Pasch + exact equivalence with `replay`).

- **The bridge — `GameKitCoordinator` (`TavliApp/Online/`, app target, `@MainActor`).** Owns all
  `GameKit` plumbing: authentication, the matchmaker invite UI, the turn-event listener, the match
  score (`matchState`), and the **current game's** HvH `GameSession`. **Inbound** —
  `receivedTurnEventFor` decodes the payload and either rebuilds from the log (first open /
  reconnection, via `resume` of the current game) or, for the open match, applies whatever this device
  has not yet seen via `pendingPlies(...)` through `applyRemoteMove` (live update, animated) — which may
  finish the current game and continue into the next. **Outbound** — it observes `session.$record`;
  when a new ply's mover is the local colour, it `endTurn`s with the re-encoded payload. **Dice** stay
  local-roll-and-broadcast; there is no shared RNG. Colours: creator plays White and moves first
  (deliberately simple for v1); the creator persists the opening payload (with the lobby's chosen
  `targetWins`) via `saveCurrentTurn` so the joiner can read its colour before the first move.

- **Best-of-three flow (#145).** When a local move wins the current game, the coordinator appends the
  winner to `matchState` and the finished `GameLog` to its history. If the **match** is now decided it
  `endMatchInTurn`s with each participant's outcome set by the **match** winner; otherwise it starts
  the next game locally (empty log, alternating starter), raises `pendingGameResult`, and hands the
  turn to that starter — `endTurn` when the opponent starts, or `saveCurrentTurn` (keep the turn) when
  the local player does. On the receiving side, a finished current game with the match still going
  advances the local session to the next game behind the between-games overlay, so subsequent incoming
  first-moves apply cleanly. `pendingGameResult` (the just-finished game's winner) drives that overlay;
  the chrome clears it on "Next game". Single-game online (`targetWins == 1`) keeps the original #134
  behaviour (game-over → back-to-lobby win overlay). Not covered by `swift test` (GameKit needs a
  signed build + two devices + sandbox accounts) — verified manually; the codec, `MatchState`, the
  `pendingPlies` diff, and `applyRemoteMove` it calls are tested headlessly. UI wiring (lobby +
  match-length toggle, online turn lock, "Leave match", scoreboard, match transition overlay) is in
  `Views/CLAUDE.md`.

**Variants online (#143).** The lobby's variant picker (shared `settings.variant`) goes to
`presentInvite(targetWins:variantID:)`; the creator writes it into the opening payload, and
game 1's starter is `variant.startingPlayer(default: .white)` (White for house Plakoto, a coin
flip for the bkgm-rules variants — when Black starts, the creator ends its turn right away).
Every variant works online (two humans, no model). A finished game — win of 1/2 points or a
draw — is logged as `GameLog(plies:result:)`, recorded into `MatchState` by points, and
`pendingGameResult` is a `MatchGameResult`; a draw never ends the match (even a single game
rolls into a replay). Older builds don't know the new variant ids and would fall back to
Plakoto, so both players need this build.

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
  each point via `setPoint`, then `setDice` → `.picking` with `mover` to play.

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
│   ├── Sources/TavliEngine/     Color, GameConfig, GameVariant, Point, HalfMove, Move, Dice,
│   │                            GameBoard, PossibleMoves, BoardEncoder, Agent,
│   │                            SearchConfig, MoveBuilder, GameSession,
│   │                            GameSave, SaveStore, MatchState, FullTavliSession, …
│   └── Tests/TavliEngineTests/  ParityTests, AgentParityTests, AgentSearchTests,
│                                FixtureSupport, MoveBuilderTests, GameSessionTests,
│                                GameSessionAITests, GameSessionAnimationTests,
│                                GameSessionAnalysisTests, GameSavePersistenceTests,
│                                PendingRollPersistenceTests (#171)
│       └── Fixtures/            fixtures.json + PlakotoValue.mlpackage (generated; see below)
├── TavliApp/                    SwiftUI iPad + iPhone app (xcodegen project; .xcodeproj is generated)
│   ├── project.yml              xcodegen spec — iPhone + iPad (device family 1,2, #109), iOS 17, Swift-5 mode,
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
│       ├── Info.plist           iPad all orientations, iPhone portrait + landscape; UIAppFonts
│       └── Resources/           bundled into the app:
│           ├── PlakotoValue.mlpackage   (generated; Xcode compiles → .mlmodelc)
│           ├── {PlakotoStandard,Fevga,Portes}Value.mlpackage  (optional, #143)
│           ├── CormorantGaramond.ttf    (variable font, committed)
│           └── Inter.ttf                (variable font, committed)
└── scripts/
    ├── generate_test_fixtures.py   Python → fixtures.json (encodings, legal moves, scores)
    └── convert_to_coreml.py        gold_v9.pth → PlakotoValue.mlpackage, written to BOTH the
                                     test Fixtures dir and TavliApp/Resources (+ self parity check)
```
