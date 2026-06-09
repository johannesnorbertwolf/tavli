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
| `CheckersView.swift` | T4 — checker stacks; pure function of a `[[Color]]` snapshot. Also `DraggedCheckerView`, `drawCheckerDisc`, `CheckerStyle`. |
| `DiceView.swift` | T8/#46 — `DieFace`/`DiceRow`, the center-bar `BoardDiceView`, `ManualDiceControl`, `usedDiceFlags`. |
| `PlayableBoardView.swift` | T7 — interactive board; tap/drag → `GameSession` intents; `TargetHighlightView`, `SourceRingView`, `HighlightStyle`. |
| `GameView.swift` | T9/T10 — responsive game chrome + assembly; turn indicator, controls, win overlay, history sheet, save dialog. Defines `ChromeTheme`. |
| `DebugOverlay.swift` | T11 — off-by-default eval panel (win-prob meter, top-3 moves, decision undo). Read-only. |
| `OpeningRollView.swift` | #33 — opening-roll ceremony resolving the starting player. |
| `RootView.swift` | T10/#61 — app root: mode picker ↔ opening roll ↔ game; owns all save/load + stats wiring. |
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
- **All metrics scale by `geo.scale`** off the 900-unit design reference, so any board size
  reproduces the reference 1:1. Each view rebuilds an identical `BoardGeometry` so layers register.
