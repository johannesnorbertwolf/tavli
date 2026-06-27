# ios/ — native iPad app (Swift)

A native, **offline** iPad app for the Plakoto AI. The value network runs on-device via
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
| `GameSession` (`@MainActor`, `ObservableObject`) | Owns `Game`, drives the turn state machine (`awaitingRoll/picking/moving/aiThinking/animating/gameOver`); publishes the view contract; optional Core ML AI side (multi-ply expectimax search off the main actor); **animated AI turn** (#93: `AnimationTimings`, published `aiDiceRolling`/`aiHopInFlight`, hops land one at a time; `.off` = synchronous); two-surface undo; human resign (`surrender`, #74); `onGameOver` hook; **attempt mode** (`onMoveAttempt`) + `drill(...)` seeder for the post-game drill (#63); **in-play analysis** (#146: `inPlayAnalysisEnabled` → `inPlayAnalysis` — opponent plies captured free from the AI search, human plies ranked at 2-ply in the background during thinking time, epoch-cancelled). |
| `MoveBuilder` | Incrementally composes a `Move` from half-moves against the live board; order-independent "bag" model; Pasch multi-hop + non-Pasch unmerge. |
| `SearchConfig` / `Agent` search (#58) | On-device multi-ply expectimax: 2-ply baseline + anytime deepening on an isolated board copy. Leaf scoring mirrors the CLI; root strategy is iOS-specific. See `REFERENCE.md`. |
| `GameRecord` / `GameSave.swift` | Canonical per-game value type (+ stable `gameId`, #104) + Codable wire format. Replay-based saves: store move history only, never board state (model-independent). Schema **v2** (#104) adds an optional `analysis` array (`AnalysisEntry` per ply: played/best moves + scores + `depth`); a save without analysis stays a v1 file, so v1 readers load it unchanged. |
| `GameReview.swift` (#62, #63, #103, #104, #146) | Post-game blunder analysis: replays a `GameRecord` and re-ranks every human ply, returning the moves that fell ≥10% short of the AI's best. `analyzeProgressive` deepens 1→2→3-ply and streams each ply via `onEvaluation` (keyed by `plyNumber`, deeper replaces shallower) so the graph/drill are usable after the 1-ply pass; its `seed:` (#146) starts from saved 2-ply analysis so only the 3-ply borderline refinement runs. `analyze` is the original single-pass form. `cachedResult` rebuilds a result from a game's **saved** analysis (#104) with no model. Also exposes `Agent.scoreCandidate` (single-move grading for the drill). See `REFERENCE.md`. |
| `SaveStore.swift` | File-backed JSON saves under `Documents/SavedGames`; one overwritten autosave slot + named manual saves; synchronous IO; reads any schema ≤ current (v1 + v2, #104). |
| `GameLogStore.swift` (#104) | Append-only log of **every** finished game (one JSON file per `gameId` under `Documents/GameLog`), written from `GameSession.onGameOver` regardless of outcome/manual save. Reuses `GameSave` as the wire format; `attachAnalysis` patches a game's analysis back in after review so a later review/drill loads it via `GameReview.cachedResult` instead of recomputing. #146: the game-over write already carries `session.inPlayAnalysis`, so even the **first** review of a game played with analysis on loads cached and only refines. |
| `HumanGameStats.swift` | iPad analogue of the CLI human-record summary + its file-backed log/store (`HumanStatsStore`). |

The SwiftUI views bind to `GameSession`'s published read-state + intents (no game logic in views).

## Build the app

```bash
bash ios/TavliApp/setup.sh            # generates the Core ML model (if missing) + TavliApp.xcodeproj
open ios/TavliApp/TavliApp.xcodeproj  # select an iPad simulator, ⌘R
```

`setup.sh` generates `PlakotoValue.mlpackage` only when absent (shells out to `convert_to_coreml.py`
via the repo `.venv`); pass `--force-model` to regenerate after changing `gold_model_path` or the
encoder. A `preBuildScript` guard in `project.yml` fails the build if the model is missing, so the
app can never silently ship the random-move fallback. `SWIFT_VERSION` is pinned to 5.9 (Swift-6
strict concurrency errors on `MLModel` + the non-`Sendable` engine classes). Display fonts (Cormorant
Garamond + Inter) are committed TTFs registered via `Info.plist` `UIAppFonts`; the Core ML model is a
generated, gitignored artifact.

## Run the parity gate

```bash
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/generate_test_fixtures.py
PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/convert_to_coreml.py
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
- **Fixtures + model are generated, not hand-written.** Re-run both scripts after changing the Python
  engine/encoder or the `gold_model_path`. The `.mlpackage` lives in the test Fixtures dir so
  `swift test` can load it.
- **Tests use `computeUnits = .cpuOnly`** to match Python CPU inference and avoid ANE float drift.
  The agent parity test runs ~170k Core ML predictions and takes ~60s.
