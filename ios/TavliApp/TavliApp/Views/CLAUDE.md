# Views — SwiftUI rendering layer

SwiftUI views for the Caramel board. These own all drawing/aesthetics; pure geometry lives in
the `BoardGeometry` package (engine-free) and game logic in `TavliEngine`. Views depend on both;
neither depends on views.

**Full per-view detail (draw order, gestures, layout math, previews) is in
[`REFERENCE.md`](./REFERENCE.md)** — read it when implementing or modifying a view.

## View index

| File | What it is |
|---|---|
| `BoardView.swift` | T3 — static empty Caramel board (frame, surface, triangles, diamonds, wordmark, bear-off trays). Single `Canvas`. Defines `CaramelPalette` + `Color(hex:)`. |
| `CheckersView.swift` | T4 — checker stacks; pure function of a `[[Color]]` snapshot. Also `DraggedCheckerView`, `AIFlightCheckerView` (the AI's arcing checker, #93), `drawCheckerDisc`, `CheckerStyle`. |
| `DiceView.swift` | T8/#46 — `DieFace`/`DiceRow`, the center-bar `BoardDiceView` (tumbles + masks the AI's roll while `aiDiceRolling`, #93), `ManualDiceControl`, `usedDiceFlags`. |
| `PlayableBoardView.swift` | T7 — interactive board; tap/drag → `GameSession` intents; `TargetHighlightView`, `SourceRingView`, `HighlightStyle`; overlays the AI flight (#93). `MoveHighlightView` (#133): renders a whole move for review/drill — rings **every** source (only the moved-checker count, top of stack), frames each landing triangle, **skips pass-through hop points**, and colour-codes your move amber / best blue / both green. |
| `ChromeKit.swift` | #101 — chrome component kit: flat `ChromeButton` roles (primary/secondary/destructive/quiet/scrim, ≥44pt), `.chromeCard()`, radius/shadow/`inkSecondary` tokens. |
| `GameView.swift` | T9/T10 — responsive game chrome + assembly; turn indicator, controls, win overlay, history sheet, save dialog. Defines `ChromeTheme` + `ChromeType` (chrome typography, #92). #77 adds the settings gear (`SettingsButton`), the optional `WinProbabilityBar`, and the manual-dice control + gating; #110 keeps `session.manualDiceEntry` in sync so manual entry covers the AI's roll too. |
| `SettingsView.swift` | #77 — in-app settings sheet (from the start screen gear + the in-game gear). Caramel-styled segmented choices (preferred color, first move, dice mode) + toggles (animate AI moves, win-probability bar), each bound to `@AppStorage`. Options/keys/defaults live in `AppSettings.swift` (target root). |
| `GameReviewView.swift` | #62/#105 — **full-screen** post-game review (from the win overlay). `GameReviewModel` runs `GameReview.analyze` off the main actor and **streams** evaluations in; the board-centric pager steps through **every scored move** (big board + Prev/Next/swipe), with a Your-move/Compare overlay (#133: always shows your move amber, Compare overlays the best in blue / both green via `MoveHighlightView`) and played→best + win-prob gap. #132: both sides' moves are shown — cards tagged You/`Tavtav` (`MoverChip`), opponent plies annotated too, and an "All moves / My blunders" toggle scopes navigation; blunder flagging stays human-only. Blunders are flagged two ways (#105): an amber `BlunderBadge` on the current move and amber rings on the chart; "Drill blunders" appears when any exist. `WinProbabilityChart`: a `Canvas` win-probability trajectory (time→x, White-perspective prob→y) on a mahogany "board window" (`CaramelPalette`) so the ivory-White trace has contrast; framed with labelled certain-White/even/certain-Red reference lines, soft checker-colour bands, a dark-cased two-colour trace, amber blunder rings, and tap/drag scrub to the nearest move. Pure presentation. |
| `DrillView.swift` | #63 — **full-screen** interactive post-game drill (reached **from inside the review** — the win overlay offers Review only, #130). Per blunder, seeds a live board via `GameSession.drill` and grades the player's attempt (`onMoveAttempt` → `Agent.scoreCandidate`) as correct/close/wrong. #114: the card loads showing the **originally-played move** (yellow `MoveHighlightView`); an attempt is **held on the board** (`GameSession.holdAttempts`/`retryAttempt`) so you can see its result, with **Try again** to reset and the win-% of your played move / attempt / best shown in the panel; a correct move stays on the board with **Next →**; "Show solution" returns to the start and compares played (yellow) vs best (blue). Responsive board-centric card; `DrillModel` drives it. |
| `DebugOverlay.swift` | T11 — off-by-default eval panel (win-prob meter, top-3 moves, decision undo). Read-only. Caramel card; floats in portrait, docks into the landscape panel (#101). |
| `OpeningRollView.swift` | #33 — opening-roll ceremony resolving the starting player. |
| `RootView.swift` | T10/#61 — app root: mode picker ↔ opening roll ↔ game; owns all save/load + stats wiring. #77: start-screen settings gear; a pinned preferred color collapses the per-game color pick; the starting-player setting can skip the opening roll; new/resumed sessions take their animation timings from settings. |
| `StatsPanelView.swift` | #64 — pure human W/L panel (overall, sparkline, streak). |
| `App.swift` | `@main` — `WindowGroup { RootView() }`. |

## Conventions / gotchas

- **No game logic in views.** Every view binds to `GameSession`'s published read-state and calls
  its intents; rendering/aesthetics only.
- **Pass a value-type board snapshot, not `[Point]`.** The engine mutates `Point` *reference*
  objects in place, so a `[Point]` is reference-identical across moves and SwiftUI skips the
  repaint (board freezes mid-game). `CheckersView`/`SourceRingView` take a `[[Color]]` snapshot
  (`points.map(\.pieces)`) so each committed move repaints.
- **Colors come from `CaramelPalette`** (defined in `BoardView.swift`, with `Color(hex:)`);
  engine→display name/color mapping is centralized in `ChromeTheme` (`GameView.swift`). Add new
  palette colors to `CaramelPalette`.
- **Chrome text sizes come from `ChromeType`** (`GameView.swift`, #92): fixed sizes one step
  above the system text styles, for older players. No hardcoded font sizes in chrome views;
  board/dice/checker sizing is geometry-scaled and exempt.
- **Buttons and cards come from `ChromeKit`** (#101): style buttons with `ChromeButton`
  roles and surfaces with `.chromeCard()` — no bespoke gradients, hairline borders, or
  sub-44pt tap targets in chrome views. Dimmed text uses `ChromeKit.inkSecondary`, nothing
  lower.
- **All metrics scale by `geo.scale`** off the 900-unit design reference, so any board size
  reproduces the reference 1:1. Each view rebuilds an identical `BoardGeometry` so layers register.
- **Persisted settings (#77) live in `AppSettings.swift`** (one level up, the target root): the
  option enums + the `SettingsKey` UserDefaults keys + static accessors for non-view contexts.
  Views bind via `@AppStorage` (keep each declaration's default equal to the matching accessor).
  Defaults reproduce the pre-settings behaviour, so the screen is purely additive.
