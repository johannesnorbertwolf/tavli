# ios/ — native iPad + iPhone app (Swift)

A native, **offline** iPad + iPhone app (#109) for the Plakoto AI, also playing standard Plakoto, Fevga and
Portes (variant selector + per-variant board UI, #143). The value network runs on-device via
Core ML; the game engine and board encoder are re-implemented in Swift. Background:
`docs/ios_port_plan.md` (status + how to run), `docs/decisions.md`, `docs/history.md`.

**Deep engine detail (turn controller, persistence, stats, full directory layout) is in
[`REFERENCE.md`](./REFERENCE.md).** The SwiftUI rendering layer is documented in
[`TavliApp/TavliApp/Views/CLAUDE.md`](./TavliApp/TavliApp/Views/CLAUDE.md).

## What this is

The Python in `domain/`, `ai/`, `game/`, `config/` is the **source of truth**. The Swift here
is a faithful port, kept honest by a parity test suite. If the two ever disagree, the Python is
right and the Swift has a bug. The Swift was ported from the retired v1 OO domain and re-validated
against the current array-based domain v2; it keeps its OO/reference-type structure on purpose
(see gotchas), only its *behavior* is pinned to v2.

## Engine index

Pure engine + Core ML agent live in `TavliEngine/Sources/TavliEngine/` (SwiftUI-free, covered by
`swift test`). The headless turn layer — see `REFERENCE.md` for full semantics:

| Type | What it is |
|---|---|
| `GameVariant` + `PlakotoVariant` / `StandardPlakotoVariant` / `FevgaVariant` / `PortesVariant` (#136-#139) | The rules seam: protocol (id, model name, initial position, legal moves, apply/undo, `hasWon`, `isOpen`, encoder, **outcome seam** `maxPoints`/`isOver`/`outcome` (draw = nil winner)/`terminalValue`/`randomStartingPlayer`, **geometry hooks** `pathIndex`/`point(atPath:)`/`bearOffPoint`/`movableCount`/`intermediatePoints`/`isLegalStep` (one play's per-position rules, for `MoveBuilder`'s play order)) carried in `GameConfig.variant` (default Plakoto). Shared code calls rules **only** through it. Registry ids `plakoto`, `plakoto_standard`, `fevga`, `portes`; each new variant reproduces its Python generator's move list *in order* and its encoder (494 / 406 / 414 floats). Portes keeps bar + borne-off in the end stacks (see `REFERENCE.md`). |
| `GameSession` (`@MainActor`, `ObservableObject`) | Owns `Game`, drives the turn state machine (`awaitingRoll/picking/moving/aiThinking/animating/gameOver`); publishes the view contract; optional Core ML AI side (multi-ply expectimax search off the main actor); **animated AI turn** (#93: `AnimationTimings`, published `aiDiceRolling`/`aiHopInFlight`, hops land one at a time; `.off` = synchronous); two-surface undo; human resign (`surrender`, #74); `onGameOver` hook (wins) + `onGameFinished(winner?, points)` (every end incl. draws; `.gameOver(winner: nil)` = draw, `record.isDraw`/`record.points`); **attempt mode** (`onMoveAttempt`) + `drill(...)` seeder for the post-game drill (#63); **in-play analysis** (#146: `inPlayAnalysisEnabled` → `inPlayAnalysis` — **both** sides ranked at full-strength 2-ply in the background and graded honestly played-vs-best, #108, epoch-cancelled); **online (#134)**: `applyRemoteMove` applies a networked opponent's ply through the same animated path, validating it by resulting-board outcome. **Dice:** `roll()`, or deterministic `setDice(_:_:)` for tests/previews/`-uiTestGame`/drill seeder (manual dice entry removed, #176). |
| `MoveBuilder` | Incrementally composes a `Move` from half-moves against the live board; order-independent "bag" model; Pasch multi-hop + non-Pasch unmerge; halves accepted only in a **legal play order** (each play checked with the variant's `isLegalStep` for an unplayed die: Portes bar-first, bear-off only with all home, larger-die bear-off, Fevga lock); **routes (#169)** `routeOptions(from:to:)` = shortest hop chains to a far point grouped by resulting position (>1 → `GameSession.routeChoice`, the player taps the in-between point: `chooseRoute(via:)` / `cancelRouteChoice()`); per-gesture commit/undo (`commit(halfMoves:)`, `undoGesture`). |
| `SearchConfig` / `Agent` search (#58, #108) | On-device multi-ply expectimax: 2-ply baseline + anytime deepening on an isolated board copy. Leaf scoring mirrors the CLI; root strategy is iOS-specific. **AI-strength dial (#108):** `selectionNoise` (σ) + `maxDepth` are the difficulty knobs — full strength is 2-ply argmax, weaker is 1-ply with Gaussian selection noise (only in `getBestMove`'s final pick; analysis stays noise-free). See `REFERENCE.md`. |
| `AILevel.swift` (#189) | `AILevel`: levels 1–8 → `searchConfig(for:)` (8 = 2-ply, 7 = 1-ply, 6…1 = 1-ply + σ 0.010/0.020/0.035/0.050/0.070/0.100), `nearest(toLegacyStrength:)` + `migrate` (old `settings.aiStrength` slider → level, once), `load` (default 8). `PlayAsPreference.migrate` rewrites a stored Play as `ask` → `random`. Unit-tested (`AILevelTests`). |
| `GameRecord` / `GameSave.swift` | Canonical per-game value type (+ stable `gameId`, #104) + Codable wire format. Replay-based saves: store move history only, never board state (model-independent). Schema **v2** (#104) adds an optional `analysis` array (`AnalysisEntry` per ply: played/best moves + scores + `depth`); a save without analysis stays a v1 file, so v1 readers load it unchanged. Optional `pendingRoll` (#171, no version bump): the dice of the turn in progress, so `resume` + `start()` re-enter that turn with the same roll (human → picking, AI → plays it) instead of re-rolling. |
| `GameReview.swift` (#62, #63, #103, #104, #146) | Post-game blunder analysis: replays a `GameRecord` and re-ranks every human ply, returning the moves that fell ≥10% short of the AI's best. `analyzeProgressive` deepens 1→2→3-ply and streams each ply via `onEvaluation` (keyed by `plyNumber`, deeper replaces shallower) so the graph/drill are usable after the 1-ply pass; its `seed:` (#146) starts from saved 2-ply analysis so only the 3-ply borderline refinement runs. `analyze` is the original single-pass form. `cachedResult` rebuilds a result from a game's **saved** analysis (#104) with no model. Also exposes `Agent.scoreCandidate` (single-move grading for the drill). See `REFERENCE.md`. |
| `SaveStore.swift` | File-backed JSON saves under `Documents/SavedGames`; one overwritten autosave slot (written after every move **and every roll**, #171) + named manual saves; synchronous IO; reads any schema ≤ current (v1 + v2, #104). |
| `GameLogStore.swift` (#104) | Append-only log of **every** finished game (one JSON file per `gameId` under `Documents/GameLog`), written from `GameSession.onGameOver` regardless of outcome/manual save. Reuses `GameSave` as the wire format; `attachAnalysis` patches a game's analysis back in after review so a later review/drill loads it via `GameReview.cachedResult` instead of recomputing. #146: the game-over write already carries `session.inPlayAnalysis`, so even the **first** review of a game played with analysis on loads cached and only refines. |
| `HumanGameStats.swift` | iPad analogue of the CLI human-record summary + its file-backed log/store (`HumanStatsStore`). |
| `OnlineMatch.swift` (#134, #145) | `OnlineMatchPayload` — the Codable blob stored in a Game Center turn-based match's `matchData`. **Schema v2** (#145): `targetWins` + `games: [GameLog]` (each game's ply log + winner) + a per-`gamePlayerID` colour map; a single game is just `targetWins == 1` with one `GameLog`, and a v1 flat-`plies` payload still decodes. Encode/decode (+ version gating), `matchState`/`completedGameWinners` views, `pendingPlies(...)` game-aware diff, per-game `gameSave(forGameIndex:)`. The whole online match state is this payload, so sync/resume/reconnect stay "decode + replay". |
| `MatchState.swift` (#145, #143) | Pure `Codable` best-of-N score shared by the offline (vs-AI) and online surfaces: `targetWins` + `baseStartingPlayer` + `results: [MatchGameResult]` (winner + points; `.draw`). Scores **points** (`score(for:)` — a double game counts 2, a draw 0 and extends `maxGames`), `matchWinner`/`isComplete`, `currentGameNumber`, and `currentStartingPlayer` (alternates from the base). `recordGame(winner:points:)` advances it; `GameRecord.result` builds the result. |
| `FullTavliSession.swift` (#144) | Pure `Codable` Full Tavli session: fixed legs Portes → Fevga → Plakoto (house, or standard if that is the saved preference), per-leg `results`, points totals (doubles 2, house Plakoto 1, draw 0 and still advances), `winner`/`isDrawn` after leg 3, `isAIAvailable(in:)` (every leg's model), and `resume(savedGame:)` → mid-leg / between legs / complete. Persisted as the optional `GameSave.fullTavli`. |
| `MoveNotation.swift` (#178) | Pure readable move notation for history/review/drill: mover-relative points (`boardSize+1 − pathIndex`, so Fevga works), `bar`/`off`, one chained segment per checker (`13/7*/5` keeps only hit intermediates), doubles grouped `6/4(3)`, highest point first, `*` hit (Portes) / `^` new pin (Plakoto) on the first lander, `motherPinned` (standard Plakoto), high die first. Structured parts + plain `text` (`64: 13/7^ 8/4`); `describe(...before:/stacks:)` for one ply, `game(_:startingPlayer:config:)` replays a whole record. See `REFERENCE.md`. |
| `BoardLayout.swift` (#143) | Engine → display slots for the board views, driven only by the variant hooks: trays show borne-off checkers only, bar checkers (Portes) move to slots 26/27; source↔slot mapping, borne-off/bar counts, hit detection for the bar animation; `reportsEquity`/`equity(fromValue:)` for 2-point variants. |
| `ModelCatalog.swift` (#143) | Per-variant Core ML model lookup + `isAvailable` (the vs-AI gate; missing model = "Computer not available yet", never random moves) + `makeAgent`; `VariantPreference` persists the chosen variant id. |
| `Handicap.swift` / `HandicapDice.swift` (#148, tier 1) | `HandicapSetup` (Codable, versioned, per-side `HandicapItems`: head start 0…4 (capped by E1), moves first, weighted-dice β, rerolls 0…4, hints 0…5; `diceTiltSteps` = the one β grid) + `HandicapGameState` (setup + tokens left; the optional `GameSave.handicap`, no version bump) + `GameRecord.handicap`/`setUpInitialPosition` (head start = Python `pip_headstart`). `HandicapDice`: per-roll 1-ply values, tilt `p∝p·exp(βv)`, Python `weighted_faces` draw, harness reroll rule. `HandicapEstimator` (net position estimate + `HandicapTable.json` log-odds). `GameSession` hooks (`handicap`, `reroll()`, `requestHint()`/`hint`, weighted/AI-reroll rolls off the main actor, `handicapUniform` seam) are inert when `handicap == nil`. **Keep in sync with `domain/handicap.py` / `ai/handicap_sweep.py`** (see `REFERENCE.md`). |

The SwiftUI views bind to `GameSession`'s published read-state + intents (no game logic in views).

**Appearance (#191).** The app follows the iOS light/dark setting by default (Settings → Display →
Appearance: System / Light / Dark, applied in `App.swift` as the windows'
`overrideUserInterfaceStyle`). Every colour token is a light/dark pair; light mode is unchanged and
dark is the "C3 · Espresso + warm text" chrome with a walnut board (`design/dark-mode/`). Token
tables and rules: `TavliApp/TavliApp/Views/CLAUDE.md` + its `REFERENCE.md`.

**Online multiplayer (#134, #145, Game Center).** The GameKit bridge — `GameKitCoordinator`
(`TavliApp/Online/`, app target, not covered by `swift test`) — maps a `GKTurnBasedMatch` to a
human-vs-human `GameSession`: it pushes each completed local turn with `endTurn` and feeds the
opponent's plies in via `applyRemoteMove` (or rebuilds from the log via `resume` on reconnect).
**Best-of-three (#145)** runs a *sequence* of games inside one `GKTurnBasedMatch`: the score lives
in the synced payload, and when a game ends the coordinator advances to the next game (alternating
starter) or ends the match by match-winner. Online match length is a lobby toggle (default
best-of-three). Needs the Game Center capability (`TavliApp.entitlements`), a real
`DEVELOPMENT_TEAM`, and the app registered in App Store Connect with Game Center enabled. See
`REFERENCE.md` for the full flow.

## Build the app

```bash
bash ios/TavliApp/setup.sh            # generates the Core ML model (if missing) + TavliApp.xcodeproj
open ios/TavliApp/TavliApp.xcodeproj  # select an iPad or iPhone simulator, ⌘R
```

`setup.sh` generates `PlakotoValue.mlpackage` only when absent (shells out to `convert_to_coreml.py`
via the repo `.venv`); pass `--force-model` to regenerate after changing `gold_model_path` or the
encoder. A `preBuildScript` guard in `project.yml` fails the build if the model is missing, so the
app can never silently ship the random-move fallback. The other variants' models
(`PlakotoStandardValue`/`FevgaValue`/`PortesValue`) are optional: `setup.sh` converts each once
its config's gold checkpoint exists, or drop the `.mlpackage` into `TavliApp/Resources/` and
re-run `setup.sh`; without one that variant is two-player only ("Computer not available yet"). `SWIFT_VERSION` is pinned to 5.9 (Swift-6
strict concurrency errors on `MLModel` + the non-`Sendable` engine classes). Display fonts (Cormorant
Garamond + Inter) are committed TTFs registered via `Info.plist` `UIAppFonts`; the Core ML model is a
generated, gitignored artifact.

## Run the parity gate

```bash
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/generate_test_fixtures.py
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/convert_to_coreml.py
for v in plakoto_standard fevga portes; do   # fixtures + random-init net + .mlpackage each
  PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/generate_test_fixtures.py --variant $v
done
cd ios/TavliEngine && swift test
```

## Key conventions / gotchas

- **Reference types on purpose.** `Point`, `HalfMove`, `Move`, `GameBoard`, `Die`, `Dice` are
  `final class`: a `HalfMove` holds the board's `Point` objects, so `applyHalfMove` mutates the
  board in place and `undo` reverses it. Mirrors the retired v1 OO domain; validated against v2 by
  behavior, not structure.
- **Encoder must match exactly.** `BoardEncoder` reproduces `ai/board_encoder.py`'s `unary_v3` path
  bit-for-bit (486 floats). Any change to the Python encoder must be mirrored here, then fixtures
  regenerated.
- **Never assume `dst = src + color*die`** in shared code (Fevga Black wraps 24→1; Portes enters
  from the bar at index 0/25): go through the variant's geometry hooks. Variants address the board
  by **position** (`board.points[hm.from.position]`), not via the half-move's `Point` refs.
- **Wrap move-applying code that may exit early in `captureSnapshot()`/`restore(_:)`**, not
  `captureStacks`: the snapshot also rewinds `GameBoard.undoLog` (Portes hit bookkeeping).
- **Fixtures + model are generated, not hand-written.** Re-run both scripts after changing the Python
  engine/encoder or the `gold_model_path`. The `.mlpackage` lives in the test Fixtures dir so
  `swift test` can load it.
- **Tests use `computeUnits = .cpuOnly`** to match Python CPU inference and avoid ANE float drift.
  The agent parity test runs ~170k Core ML predictions and takes ~60s.
