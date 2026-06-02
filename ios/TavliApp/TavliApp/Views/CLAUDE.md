# Views — SwiftUI rendering layer

SwiftUI views for the Caramel board. These own all drawing/aesthetics; pure
geometry lives in the `BoardGeometry` package (engine-free) and game logic in
`TavliEngine`. Views depend on both but neither depends on views.

## BoardView.swift (T3 — static empty board)

Renders the **empty** Caramel board: beechwood frame, mahogany play surface, 24
ivory triangles with tip pips, the slim center bar line, two diamond ornaments,
the italic `TAVLI` wordmark, and (since #31) the two persistent bear-off tray
recesses. No checkers, dice, highlights, or interactivity — those land in later
tickets.

- **Bear-off tray chrome** (#31): a subtle always-present recess on each half of
  the right frame strip (White 25 top, Black 0 bottom), drawn from
  `geo.point(0/25).hitRect` inset `(4·s, 8·s)` as a rounded-rect (corner `8·s`),
  filled with `trayFill` @ 0.22 + a `trayEdge` @ 0.45 hairline. Slightly larger
  than the T7 gold target box's `(5·s, 10·s)` inset so that box reads cleanly
  *inside* the tray. The Caramel reference has no bear-off art — this is the
  project's tray chrome, giving borne-off checkers and the gold cue a tray to sit
  in. Drawn right after the play surface (below the triangles); it does not
  overlap the diamonds or wordmark.

- **Single `Canvas`.** `body` is one `Canvas { context, size in … }` with
  `.aspectRatio(1, .fit)`. It builds `BoardGeometry(rect: CGRect(origin: .zero,
  size:))`, which fits a centered square into the available rect, so the board
  stays square at any iPad size and centers on the long axis.
- **Everything scales by `geo.scale`.** All literals (stroke widths, pip radius,
  tile size, font size, corner radius, insets) come from the 900-unit design
  reference `docs/design/tavli/project/Tavli Board.html` and are multiplied by
  `geo.scale`, so a 900×900 rect reproduces the reference 1:1.
- **Draw order** (matches the SVG): frame rounded-rect (3-stop vertical
  beechwood gradient) + faint highlight stroke → inner play surface (2-stop
  mahogany gradient) + soft dark inner edge approximating the SVG inset shadow →
  24 triangles (`baselineLeft → baselineRight → tip`, ivory fill, 2.6pt dark
  round-join stroke) → tip pips (9pt ivory circles, thin dark stroke) at each
  `point(n).tip` → center bar line (`barTop`→`barBottom`, dark, 0.55 opacity) →
  two diamonds at `leftDiamondCenter`/`rightDiamondCenter` → wordmark.
- **`drawDiamond`** ports the reference `Diamond` component: dark backing
  diamond, a tessellated tile border (4 sides × 8 tiles; each tile is a 6.8u
  square translated along the edge and rotated `edgeAngle + 45°` via a copied
  `GraphicsContext`, alternating `diamondTileDark`/`diamondTileLight`), an inset
  ivory inner diamond (`inset = 9` → `iw = w − 18`, `ih = h − 14.4`), and a
  central dark dot. Diamond extent comes from `geo.diamondSize`.
- **Wood grain is intentionally omitted.** The SVG uses `feTurbulence`; per the
  design's fidelity caveat we approximate with the flat gradients above.

### CaramelPalette + `Color(hex:)`

`CaramelPalette` is an `enum` of `static let Color`s ported verbatim from the
`CARAMEL` table in the reference. It carries the empty-board colors, the T4
checker colors (`whiteFill/Hi/Ring/Edge/Text`, `redFill/Hi/Ring/Edge/Text`), and
the T7 move-highlight colors (`hl` `#f4b400` — source ring + target frame;
`hlEdge` `#7a5400`; `hlFill` `#f6c623` — the fill-mode target), and the #31
bear-off tray chrome (`trayFill` `#2a1408`, `trayEdge` `#1a0a04`, both applied at
low opacity). `Color(hex: UInt32)` unpacks `0xRRGGBB`. Add later-ticket colors
(dice) here as those views land.

## CheckersView.swift (T4 — checker stacks)

Renders the checker stacks on top of `BoardView` — a **pure function of board
state**, taking `stacks: [[TavliEngine.Color]]` (per-slot piece colors, indexed
0…25). **Value type on purpose:** the engine `Board` mutates `Point` *reference*
objects in place, so a `[Point]` input is reference-identical across moves and
SwiftUI skips repainting the Canvas — the board freezes while the model advances
(the move-input bug). The `[[Color]]` snapshot (`points.map(\.pieces)`, built once
in `PlayableBoardView` and shared with `SourceRingView`) changes by value, so each
committed move reliably repaints. No highlights, interaction, or animation (later
tickets). Like `BoardView` it's a single `Canvas` +
`.aspectRatio(1, .fit)` building `BoardGeometry(rect:)`, so an overlaid
`ZStack { BoardView(); CheckersView(stacks:) }` shares the same centered-square
fit and the checkers register with the triangles.

- **Stacks** (`drawStack`, porting the reference `Stack`): for **every** slot
  `0…25` with a non-empty stack, draw `min(count, 5)` checkers at
  `geo.checkerCenter(point:slot:)` (slot 0 = base, growing away from the
  baseline). Each checker uses its **actual per-slot color** (`pieces[slot]`), so
  a pinned point shows the trapped opponent checker in its own color at the base
  — the color *is* the distinct rendering (no extra marker). When `count > 5`, a
  **bold** Cormorant Garamond count label (`size r·1.2`) is drawn **centered on
  the owning team's checker** (#46): a pinned point has `pieces[0] != pieces[1]`
  (the trapped opponent sits alone at the base), so the label lands on slot 1 —
  the owner's first checker — instead of the opponent's; otherwise slot 0. It
  uses that checker's text color and no background chip — the number sits
  directly on the disc. Slots 0/25 are the **bear-off trays** (#31): borne-off
  checkers (Black at 0, White at 25 — the board model accumulates them there)
  stack via the same path, full-size discs floating over the right frame strip
  (the strip chrome itself lives in `BoardView`). Same `count > 5` badge, so a
  borne-off stack up to 15 reads consistently with on-board stacks.
- **Checkers** (`drawChecker`, porting the reference `Checker`): wrapped in a
  `context.drawLayer` with a `.shadow` filter (the spec's drop shadow). Inside:
  the disc filled with a radial gradient (`hi → fill`, center `(cx−0.24r,
  cy−0.36r)`, end radius `1.56r`, mapping SVG `cx=0.38, cy=0.32, r=0.78`) + a
  thin `edge` stroke; two concentric `ring` detail circles (`r·0.66` @ 0.85,
  `r·0.52` @ 0.55); and a soft white specular arc approximated by a quad curve
  from `(cx−0.55r, cy−0.35r)` to `(cx+0.55r, cy−0.35r)` (control `(cx,
  cy−0.85r)`), opacity `0.55` white / `0.28` red. All design stroke widths scale
  by `geo.scale`; radius-relative offsets use the scaled `geo.checkerRadius`.
- **`CheckerStyle`** maps `TavliEngine.Color → (fill, hi, ring, edge, text)` from
  `CaramelPalette`; engine `.black` → red.
- Two `#Preview`s: the start position (over `BoardView`) and a constructed pinned
  point (`setPoint(13, [.black] + .white×6)` — a black checker pinned under a tall
  white owner stack, so the count label must land on the white checker, not the
  black one) plus other tall on-board/borne-off stacks to exercise the count label.

## DiceView.swift (T8 dice — relocated to the board center bar in #46)

The dice. Pure faces driven by explicit values + per-die `used` flags, plus two
session-bound hosts.

- **`usedDiceFlags(values:built:)`** (free helper) — which displayed dice are
  consumed, matched **by the die actually used, not left-to-right** (#46 bug
  fix). The engine has no bear-off overshoot, so a committed `HalfMove`'s die
  value is exactly its signed point delta (`to − from` for white, `from − to`
  for black). For each built half-move it greys the first still-free slot whose
  value matches; duplicate values (a pasch) fall into successive slots. Returns
  a `[Bool]` parallel to `values`.
- **`DieFace`** — one ivory die (`#f5ead0` fill, `#2a1408` edge + pips, faint
  white inner highlight, soft drop shadow); pip positions are the design's
  normalized `PIP_LAYOUTS`. All metrics scale off `size` (default 56). `isUsed`
  greys it (opacity 0.4 + desaturation, animated).
- **`DiceRow`** — pure row of `DieFace`s, driven by explicit `values` + a
  **parallel `used: [Bool]`** array (not a count), so it renders any state in
  previews and greys the die actually consumed.
- **`DiceView`** — binds `DiceRow` to a `GameSession` (a pasch shows four dice;
  `used = usedDiceFlags(values:built:)`); tap runs a brief tumble then
  `session.roll()`, gated on `phase == .awaitingRoll`. Retained for its
  `#Preview`; the live game uses `BoardDiceView` instead.
- **`BoardDiceView`** — the dice on the board's **center bar** (#46, the
  traditional placement, freeing the side rails). A `GeometryReader` builds a
  `BoardGeometry` and lays each `DieFace(size: geo.diceSize)` at
  `geo.diceCenters(count:)` (two side-by-side horizontally; a pasch is all four
  in one horizontal row). Same value-matched greying and tumble-then-`roll()`.
  `.allowsHitTesting(canRoll)` so it claims taps only while awaiting a roll and
  otherwise passes them through to the board beneath — see `PlayableBoardView`
  for why it's a **sibling** of the gesture stack, not inside it.
- **`ManualDiceControl`** — two 1…6 steppers + "Set dice" →
  `session.setManualDice(d1, d2)`; only active while awaiting a roll.
- `#Preview`s: a "Dice — states" matrix over `DiceRow` (normal, each side
  consumed, pasch, partially/fully consumed — including a right-die-consumed
  case demonstrating the #46 fix) and the manual control.

## PlayableBoardView.swift (T7 — move input + highlighting)

The interactive board: composes the static board, highlight overlays, and
checkers, and turns tap / drag gestures into `GameSession` intents. Binds to a
`GameSession` via `@ObservedObject`; **no game logic lives here** — it only reads
the published view contract (`selectableSources`, `validTargets`, `selectedPoint`,
`game.board.points`) and calls `selectPoint` / `commitHalfMove`.

- **Layer order** (a `GeometryReader` + `ZStack`, bottom → top): an **inner
  `ZStack`** of `BoardView()` → `TargetHighlightView` (below the checkers so a
  fill sits under them) → `CheckersView(stacks:)` → `SourceRingView` (above, so
  the ring haloes the selected stack), carrying the `.contentShape` + board
  `.gesture`; then **`BoardDiceView(session:)` as a sibling above it** (#46 — the
  center-bar dice). All layers rebuild an identical `BoardGeometry` from the same
  square fit, so they register exactly; the gesture geometry is built from the
  same `GeometryReader` size. The container is `.aspectRatio(1, .fit)`.
- **Why the dice are a sibling, not inside the gesture stack** (#46): the dice
  own a tap-to-roll gesture and the board owns tap/drag. Nesting them would make
  the two contend; keeping `BoardDiceView` a sibling with
  `.allowsHitTesting(canRoll)` means it claims taps only while awaiting a roll
  (when the board has no selectable sources anyway) and passes them through
  otherwise, so the two never collide.
- **Gesture** — a single `DragGesture(minimumDistance: 0)` whose intent dispatch
  is resolved **entirely in `onEnded`**. This is deliberate: mutating session
  state from `onChanged` (the earlier design's mid-drag `selectPoint`) republishes
  and rebuilds the enclosing `GeometryReader`, which **cancels the in-flight
  gesture so `onEnded` never fires and the drop is lost** — a real-device failure
  (selection highlights, but the move never commits) that the simulator and
  XCUITest's synthetic events do not reproduce. On release:
  - **Drag** (travel > `dragThreshold` 10pt *and* the press started on a
    selectable source): `selectPoint(source)`, then `hitTest` the drop over
    `validTargets` → `commitHalfMove`. A miss just leaves the source selected.
  - **Tap** (everything else, via `handleTap`): `hitTest` over **`0…25`** (slots
    0/25 included so bear-off targets are tappable); if a target is tapped with a
    source already selected → `commitHalfMove`, else `selectPoint(tapped)` (a
    non-selectable index clears the selection, since `selectPoint` ignores it).
  - No floating ghost checker — the ring + target marks are the feedback, per the
    Caramel design.
- **Multi-hop targets need no view change.** On a Pasch (and when a single checker plays both
  dice of a non-Pasch roll), `validTargets` may include endpoints several hops away: a tap on a
  far endpoint commits multiple half-moves and a tap on an intermediate stop lets the same checker
  continue. Both are resolved entirely in `GameSession.commitHalfMove(from:to:)` (via
  `MoveBuilder.path`), so the view still just renders `validTargets` and routes one
  `commitHalfMove` per tap.
- **Test hook** — the ZStack carries `accessibilityIdentifier("board")` plus an
  `accessibilityValue` of comma-joined per-slot checker counts (`boardSignature`),
  so `TavliAppUITests` can locate the board's frame (to map `BoardGeometry`
  coordinates to taps) and assert board mutations without inspecting Canvas pixels.
- **`HighlightStyle`** (`enum { frame, fill }`) — the design's "two readings".
  Default `.frame` (gold outline, preserves the wood/ivory look); `.fill` is the
  higher-visibility solid-gold variant, kept behind this constant
  (`PlayableBoardView(session:highlightStyle:)`).
- **`TargetHighlightView`** — a pure `Canvas` (`.allowsHitTesting(false)`)
  marking each legal target:
  - **Playable points (1…24)** — `markTriangle` redraws the triangle path
    (`baselineLeft → baselineRight → tip`): `.frame` strokes it `hl` width `5·s`;
    `.fill` fills `hlFill` + the normal `2.6·s` dark stroke.
  - **Bear-off (0/25)** — `markBearOff` draws a gold **tray box** on the
    corresponding half of the right frame strip (slot 25 top = White, slot 0
    bottom = Black): the slot's `hitRect` inset `(5·s, 10·s)` as a rounded-rect
    (corner `8·s`); `.frame` strokes it `hl` (`5·s`), `.fill` fills `hlFill` with
    a `hlEdge` `2·s` edge. Since #31 this gold target box reads *inside* the
    persistent tray chrome (drawn by `BoardView`, a touch larger), and borne-off
    checkers (drawn by `CheckersView`, layered above) stack on top of it.
- **`SourceRingView`** — a pure `Canvas` (`.allowsHitTesting(false)`) that, for
  the selected point's `min(count, 5)` visible checkers, strokes a gold circle at
  `geo.checkerCenter(point:slot:)` with radius `checkerRadius + 3.2·s`, width
  `3.4·s` — matching the reference's `selected` ring.
- `#Preview`s: frame + fill drive a `GameSession(startingPlayer: .white)` with
  manual dice `3·5` and point 1 selected, reproducing the design's reference
  highlight scenario (targets 4, 6, 9); a "Borne-off checkers in trays" preview
  (#31) seeds the session's board with borne-off checkers (`setPoint(25, …×8)`,
  `setPoint(0, …×3)`) to show the tray chrome + stacked borne-off checkers + count
  badge; two more drive `TargetHighlightView` directly with `targets: [0, 25]`
  (frame + fill) to show the bear-off tray boxes without building a
  near-end-of-game board.

## GameView.swift (T9 chrome + T10 assembly)

The non-board UI framing a game, assembled with the **interactive** `PlayableBoardView`
into a responsive layout. Pure presentation: every sub-view binds to a `GameSession`'s
published read-state and calls its intents — no game logic lives here. (T9 first wired
this against the static `BoardView`; T10 swapped in `PlayableBoardView` so the assembled
screen is fully playable, and added the Back button + hosted debug toggle.)

- **`GameView`** (`@ObservedObject session`, plus `stats: HumanGameStats = .empty` — the
  human's record shown in the win overlay (#64), `onBack: () -> Void = {}` — returns to
  the mode picker, and `onNewGame: () -> Void = {}` — replaces the finished session with
  a fresh one; the non-session args default so `#Preview`s compile). A `GeometryReader`
  switches layout on `width >= height`:
  - **Landscape:** `HStack` with `PlayableBoardView(session:)` greedily filling the
    height (`.frame(maxWidth:.infinity, maxHeight:.infinity)`, `8pt` pad) and a fixed
    260pt `sidePanel` on the trailing edge (turn indicator + the two borne-off counters
    on top, controls anchored at the bottom; top-padded `44` so the indicator clears the
    corner Back/debug overlays). **The board owns the leftover width via that frame, not
    `Spacer`s** (#46): two flanking spacers and the equally-flexible aspect-fit board
    split the width three ways, shrinking the board to a third of the height — the
    spacers are gone. The only empty space is now the thin margin where a square board
    can't cover the wide axis. (The board *frame* art is unchanged; only the surrounding
    empty space shrank.)
  - **Portrait:** `VStack(spacing: 12)` — a `topBar` (counters + turn indicator as a
    **centered** group, leaving the top corners free), the board (`8pt` horizontal pad),
    then the controls row, with the whole `VStack` centered via `.frame(maxHeight:.infinity)`
    + `12pt` vertical pad. A square board can't fill a tall screen, so some vertical margin
    is unavoidable; the point of #46 here is **how** that margin is distributed. The board
    deliberately does **not** get `.frame(maxHeight:.infinity)` in portrait — that would
    inflate the board's container and center the square inside it, floating the board with
    dead gaps *between* it and the chrome ("a bunch of space top and bottom" of the board).
    Instead the chrome **hugs** the board (`12pt` spacing) and the centered group pools the
    leftover into one clean band at the very top/bottom (behind the floating Back/debug
    corners). Verified by rotating the sim headlessly with `XCUIDevice.orientation` in a
    throwaway UI test and inspecting the screenshot attachment.
  - Floating chrome in the `ZStack`: a top-leading `BackButton` (calls `onBack`) and a
    top-trailing `DebugOverlayToggle(session:)` (see `DebugOverlay.swift`), each pinned
    via `.frame(maxWidth/Height: .infinity, alignment:)`.
  - `WinOverlayView` is layered **last** (above Back/debug) whenever `session.phase` is
    `.gameOver`.
  - Page background is `#ece6dc` (matches `RootView`'s picker).
- **`BackButton`** — a caramel pill (chevron + "Back") tinted from `ChromeTheme`,
  calling the injected `onBack`.
- **`TurnIndicatorView`** — maps `session.phase` to a headline: `.awaitingRoll` →
  "`<Name>`'s turn" + "Tap dice to roll" caption; `.picking` → "Pick a checker";
  `.moving` → "Choose destination"; `.aiThinking` → "AI thinking…"; `.animating` →
  "`<Name>` moving…"; `.gameOver(w)` → "`<Name>` wins!". `<Name>` and the player come
  from `ChromeTheme` + `session.currentPlayer`.
- **`BorneOffView(session:color:)`** — a checker-colored disc + count + label. Counts
  read straight off the board on each session publish: white =
  `board.points[board.boardSize + 1].count`, black = `board.points[0].count`. They
  refresh because `phase`/`selectableSources` republish on every transition.
- **`ControlsView`** — contextual buttons shown only while `phase == .picking ||
  .moving`: **Undo** (`session.undo()`) when `moveBuilder.built` is non-empty;
  **Done** (`session.confirm()`) when `moveBuilder.canFinishNow && !built.isEmpty`.
  Styled by `ControlButtonStyle` (palette pill). The dice no longer live here —
  they moved to the board's center bar (`BoardDiceView`, #46), which freed the side
  rails. These buttons only fully exercise once a human composes a partial move;
  until then they appear only in the scripted `#Preview`.
- **`WinOverlayView(winner:stats:onNewGame:)`** — dimmed scrim, serif "`<Name>` wins!", the
  `StatsPanelView(stats:)` (so the human's record is **auto-shown after every game**, #64), and a
  "Play Again" button calling the injected `onNewGame` closure (provided by `RootView`
  to replace the finished session with a fresh one — see `RootView.swift`). The just-finished
  game is already counted: `session.onGameOver` records into `RootView`'s store, whose
  `@Published` change re-renders `RootView` → passes fresh `stats` down before the overlay paints.
- **`ChromeTheme`** — centralizes the engine-`Color` → display mappings so a future
  visual style swaps them in one place: `displayName` (`.white` → "White", `.black` →
  **"Red"**) and `checkerColor` (white → ivory `#fbeed1`, black → deep red `#a83a2a`),
  plus `ink`/button tints. Reuses `Color(hex:)` from `BoardView.swift`.
- **Previews:** `"Landscape"` / `"Portrait"` on a fresh session, and `"Undo/Done"`
  which scripts a half-move (`setManualDice` → `commitHalfMove`) to surface the
  contextual buttons without T7.

## DebugOverlay.swift (T11 — debug eval overlay)

A toggleable, off-by-default panel exposing the AI's evaluation of the current
position. Two `View`s, both bound to a `GameSession` (`@ObservedObject`), read-only
with **no effect on gameplay**. `GameView` (T10) hosts `DebugOverlayToggle` as a
top-trailing overlay on the game screen.

- **`DebugOverlayToggle`** — the drop-in any screen hosts. A `ladybug.fill` bug-icon
  button with `@State isOn = false` (off by default): tinted yellow when on, dim white
  when off. When on it reveals `DebugOverlay` below it with a 0.15s opacity transition.
- **`DebugOverlay`** — a ~200pt translucent-black panel with three rows:
  1. **Win-probability meter** — a yellow `Capsule` fill over a black track, width =
     `geo.size.width * session.winProbability` (always WHITE's view), plus the numeric `%`.
  2. **Top moves** — the top-3 candidate moves. `agent.evaluateMoves(board, legalMoves,
     color:)` zipped with `legalMoves` → `(move.description, score)`, sorted desc,
     `prefix(3)`. Cached in `@State`; recomputed on `onAppear` and
     `onChange(of: positionSignature)` (a string of player/dice/legal-count/built-count/
     phase) — never per render, so Core ML isn't re-run needlessly. Recompute is **guarded
     to a clean turn-start** (`session.agent != nil && moveBuilder.built.isEmpty &&
     !legalMoves.isEmpty`) so a full move is never applied onto a partially-built sequence;
     shows `—` otherwise. `evaluateMoves` apply/undoes on the shared board on the main actor
     (the same actor that owns the board), leaving it unchanged.
  3. **Status line** — `session.currentPlayer` + the two dice values.

  Uses plain SwiftUI `Color` (`.black`/`.yellow`/`.white`); unlike the other views it does
  not need `Color(hex:)` or `ChromeTheme`.

## RootView.swift (T10 — root navigation + mode picker)

The app's top-level view: switches between the caramel **mode picker** and a live game.

- **`RootView`** — `@StateObject private var statsStore = HumanStatsStore()` (the human
  W/L history, #64), `@State private var session: GameSession?` plus `@State private var
  humanColor: EngineColor`. `nil` session → show `ModePickerView(stats:onSelect:)`;
  non-`nil` → show `GameView(session:stats:onBack:onNewGame:)`. `onBack` resets `session =
  nil` (returns to the picker). `onNewGame` and picking a color both go through
  `startSession(humanColor:)`, which builds a fresh session via `makeSession` and wires
  `session.onGameOver = { winner in store.record(humanWon: winner == humanColor) }` — so
  every completed game is recorded once (the closure captures the store + color by value,
  no `self`). Holding the session in `@State` keeps the reference stable across re-renders
  (`GameView` observes it); observing `statsStore` re-renders `RootView` when a game is
  recorded, so the win overlay / picker see fresh `stats`. `makeSession(humanColor:)`
  builds `GameSession(startingPlayer: .black, agent: GameSession.makeAgent(), aiColor:
  humanColor.opponent)` and calls `start()` — so Black always opens, and when the human
  chose White the AI (Black) moves first. The `-uiTestGame` bootstrap uses `makeSession`
  **without** the `onGameOver` hook, so UI-test runs don't write to the stats store. *(The
  real opening-roll rule — each side rolls one die, higher starts, with a manual override —
  is a separate, deferred ticket.)*
- **`ModePickerView(stats:onSelect:)`** — `#ece6dc` background, a large Cormorant Garamond
  "Tavli" wordmark in `CaramelPalette.frameText`, two caramel `ModeButton`s ("Play vs AI /
  You play White" → `.white`, "Play vs AI / You play Black" → `.black`), and a third "My
  Record" button (subtitle = the current `Ws – Ls`, or "No games yet") that presents the
  `StatsPanelView(stats:)` in a `.sheet` (#64 — stats accessible from the picker). The design
  reference's "Watch AI vs AI" mode is **deferred** (out of scope).
- **`ModeButton` / `ModeButtonStyle`** — a caramel wood pill (frame-palette top→mid
  gradient, `frameBot` border, `frameText` ink, press-dim via `.brightness`).
- `EngineColor` is a `private typealias` for `TavliEngine.Color` to disambiguate from
  `SwiftUI.Color` (mirrors `GameView`'s `SColor`).

## StatsPanelView.swift (#64 — human W/L panel)

The iPad analogue of the CLI's post-game summary box. A **pure** view of a
`HumanGameStats` (from `TavliEngine`) — no persistence or game logic; the store lives in
`RootView`. Hosted in two places: inside `WinOverlayView` (auto-shown after every game) and
from the mode picker's "My Record" sheet.

- **`StatsPanelView(stats:)`** — a parchment card (`#f3ecdf` fill, `frameBot` border) with a
  Cormorant Garamond "Human vs AI" header. When `stats.total == 0` it shows a "No games yet"
  empty state; otherwise three sections:
  1. **Overall** — `{wins}W – {losses}L (NN%)` over a thin win-rate `Capsule` bar
     (`width = proxy.width * stats.winRate`).
  2. **Sparkline** — a `Last 20` / `All N` label over a row of dots for `stats.recent`
     (oldest→newest): filled **green** (`#6a8a4a`) for a win, **brick-red** (`#b0563f`) for
     a loss.
  3. **Streak** — `"{n} wins/losses in a row ↑/↓"`, tinted to the streak color.
- Reuses `CaramelPalette` + `Color(hex:)` (same target) via a local `SColor` typealias (so a
  bare `Color` stays unambiguous against `TavliEngine.Color`); a small private `Palette`
  enum holds the panel-local colors. Carries `accessibilityIdentifier("statsPanel")`.
- `#Preview`s: a mixed record over the light picker background, and the empty state over the
  dark win-overlay scrim (the card reads on both).

## App.swift

`@main`. Minimal — `WindowGroup { RootView() }`. (Earlier the T7 sign-off bootstrap
hosted `PlayableBoardView` on a fixed scenario here; T10 moved the entry to `RootView`.)
