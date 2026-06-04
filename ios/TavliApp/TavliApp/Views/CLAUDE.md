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
- **`drawCheckerDisc`** (module-level free function) — the drawing kernel shared
  by `CheckersView` and `DraggedCheckerView`. Takes a `lifted: Bool` flag; when
  true it deepens the drop shadow (`radius 8·s`, `y 5·s`, opacity 0.40 vs 3·s /
  2·s / 0.28 for flat) to simulate the checker being raised off the board.
- **`DraggedCheckerView`** (#40) — a single-checker `Canvas` overlay (`.allowsHitTesting(false)`)
  drawn at an arbitrary `location` in board coordinate space, using the lifted
  shadow variant. Rendered above all board layers (including dice) during a drag
  gesture, and again during the snap-back animation after a failed drop.
- **`CheckerStyle`** maps `TavliEngine.Color → (fill, hi, ring, edge, text)` from
  `CaramelPalette`; engine `.black` → red. `fileprivate` — used by `CheckersView`
  and `DraggedCheckerView` (both in the same file).
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
  center-bar dice); then **`DraggedCheckerView`** (floating checker during drag,
  #40) and the snap-back overlay, both above the dice. All layers rebuild an
  identical `BoardGeometry` from the same square fit, so they register exactly;
  the gesture geometry is built from the same `GeometryReader` size. The
  container is `.aspectRatio(1, .fit)`.
- **Why the dice are a sibling, not inside the gesture stack** (#46): the dice
  own a tap-to-roll gesture and the board owns tap/drag. Nesting them would make
  the two contend; keeping `BoardDiceView` a sibling with
  `.allowsHitTesting(canRoll)` means it claims taps only while awaiting a roll
  (when the board has no selectable sources anyway) and passes them through
  otherwise, so the two never collide.
- **Gesture** (#40) — a single `DragGesture(minimumDistance: 0)` with both
  `.updating` and `onEnded`. Intent dispatch stays in `onEnded` because mutating
  session from `onChanged` republishes and rebuilds the `GeometryReader`, cancelling
  the gesture on real devices. `.updating($liveDrag)` tracks the source point and
  current finger position via `@GestureState` — **read-only access to session**
  (no publish), so the gesture is never cancelled mid-drag. On release:
  - **Drag** (travel > `dragThreshold` 10pt *and* the press started on a
    selectable source): `selectPoint(source)`, then `hitTest` the drop over
    `validTargets` → `commitHalfMove`. A miss clears the selection and triggers
    a **snap-back animation** (spring, 0.22s) of the floating checker back to its
    stack position. A `@State snapBackTask` cancels any in-flight cleanup so
    rapid failed drops don't clobber each other.
  - **Tap** (everything else, via `handleTap`): `hitTest` over **`0…25`** (slots
    0/25 included so bear-off targets are tappable); if a target is tapped with a
    source already selected → `commitHalfMove`, else `selectPoint(tapped)` (a
    non-selectable index clears the selection, since `selectPoint` ignores it).
- **Drag visuals** (#40): while `@GestureState liveDrag` is set, `displayStacks`
  shows one fewer checker at the drag source; `highlightTargets` is computed
  from `session.moveBuilder.validDestinations(for: sourcePoint)` (pure read, no
  mutation); the ring shows around the remaining source checkers; and
  `DraggedCheckerView` floats above all other layers at the finger's position.
  On gesture end `@GestureState` auto-resets; the snap-back overlay takes over
  for failed drops, animated from the release point back to the stack origin.
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

- **`GameView`** (`@ObservedObject session`, plus `onBack: () -> Void = {}` — returns to
  the mode picker, `onNewGame: () -> Void = {}` — replaces the finished session with
  a fresh one, `onSave: (String) -> Void = { _ in }` (#61) — persists the game under the
  given name, and `onAutosave: () -> Void = {}` (#61) — writes the single autosave slot; all
  default to no-ops so `#Preview`s compile). A `GeometryReader`
  switches layout on `width >= height`:
  - **Landscape:** `HStack` with `PlayableBoardView(session:)` filling the height and
    **bound to the leading edge** (`.frame(maxWidth:.infinity, maxHeight:.infinity,
    alignment: .leading)`, `8pt` pad) and a fixed 260pt `sidePanel` on the trailing edge
    (turn indicator + the two borne-off counters on top, controls anchored at the bottom;
    top-padded `44` so the indicator clears the corner Back/debug overlays). **The board
    owns the leftover width via that frame, not `Spacer`s** (#46): two flanking spacers and
    the equally-flexible aspect-fit board split the width three ways, shrinking the board to
    a third of the height — the spacers are gone. `.leading` pins the square to the left so
    the slack between board and panel sits on the right and the board never shifts as the
    panel chrome changes. (The board *frame* art is unchanged; only the surrounding empty
    space shrank.)
  - **Portrait:** `VStack(spacing: 12)` — the `topBar` (counters + turn indicator as a
    **centered** group, leaving the top corners free) pinned to the top, a flexible
    `Spacer(minLength: 0)`, then the controls row and the board (`8pt` horizontal pad),
    with the `VStack` filling the height (`.frame(maxWidth:.infinity, maxHeight:.infinity)`
    + `12pt` vertical pad). A square board can't fill a tall screen, so some vertical margin
    is unavoidable; #46 controls **where** it goes. The board is **bound to the bottom edge**:
    the chrome pins to the top, the `Spacer` pools the slack into the middle, and the board
    sits at the bottom with the contextual controls hugging just above it. Anchoring the
    board this way stops it from jumping — the earlier *centered* group re-centred on every
    turn/phase change (the "Tap dice to roll" caption, the Undo/Done row), visibly shifting
    the board. `.layoutPriority(1)` on the board lets it claim its full-width square first so
    the `Spacer` (not the board) absorbs the slack; without it two equally-flexible children
    (Spacer + aspect-fit board) split the height and the board shrinks below full width.
    Verified by rotating the sim headlessly with `XCUIDevice.orientation` in a throwaway UI
    test and inspecting the screenshot attachment.
  - Floating chrome in the `ZStack`: a top-leading `HStack { BackButton; SaveButton }` and a
    top-trailing `DebugOverlayToggle(session:, onHistory:)` (see `DebugOverlay.swift`), each
    pinned via `.frame(maxWidth/Height: .infinity, alignment:)`. The `SaveButton` is hidden once
    `session.isTerminal` (finished games aren't saved, #61).
  - **Move-history sheet (#60):** `DebugOverlayToggle` is passed `onHistory: { showHistory = true }`,
    which threads through to `DebugOverlay`'s "Move history" button. The `.sheet(isPresented: $showHistory)`
    is attached to the `ZStack`; `WinOverlayView` also carries its own History button so the log
    stays reachable after the game when the scrim covers the debug pane.
  - **Manual save (#61):** tapping Save runs `presentSaveDialog` — seeds `saveName` with a
    timestamped default (`"Game · <date>"`) and flips `showingSaveDialog`. A `.alert("Save
    game", isPresented:)` hosts a `TextField` + "Save"/"Cancel"; "Save" trims the field and
    calls `onSave(name)` (falling back to the timestamp default if left empty). `RootView`
    provides `onSave` to write a named manual save via the `SaveStore`.
  - **Auto-save (#61):** `.onChange(of: session.history.count) { onAutosave() }` fires once per
    ply — `history` grows by one per finished turn (human, AI, or forced pass) — so the
    in-progress game is persisted after **every move**, not just on background. `RootView`'s
    `persistAutosave` overwrites the single autosave slot (or clears it once the game is over).
  - `WinOverlayView` is layered **last** (above Back/Save/debug) whenever `session.phase` is
    `.gameOver`.
  - Page background is `#ece6dc` (matches `RootView`'s picker).
- **`BackButton`** — a caramel pill (chevron + "Back") tinted from `ChromeTheme`,
  calling the injected `onBack`.
- **`SaveButton`** (#61) — a caramel pill (download glyph + "Save") tinted from
  `ChromeTheme.doneTint`, calling the injected open-dialog action.
- **`TurnIndicatorView`** — maps `session.phase` to a headline: `.awaitingRoll` →
  "`<Name>`'s turn" + "Tap dice to roll" caption; `.picking` → "Pick a checker";
  `.moving` → "Choose destination"; `.aiThinking` → "AI thinking…"; `.animating` →
  "`<Name>` moving…"; `.gameOver(w)` → "`<Name>` wins!". `<Name>` and the player come
  from `ChromeTheme` + `session.currentPlayer`.
- **`BorneOffView(session:color:)`** — a checker-colored disc + count + label. Counts
  read straight off the board on each session publish: white =
  `board.points[board.boardSize + 1].count`, black = `board.points[0].count`. They
  refresh because `phase`/`selectableSources` republish on every transition.
- **`ControlsView`** — **Undo** is persistent (#59): always rendered, calling
  `session.undo()`, greyed (`.disabled` + `0.4` opacity) when `session.canUndo` is
  false. It peels the last committed half-move within the current turn only; it
  greys out when nothing has been built yet (between turns, AI thinking, game over).
  **Done** (`session.confirm()`) is still contextual: shown only when
  `moveBuilder.canFinishNow && !built.isEmpty`. Both styled by `ControlButtonStyle`
  (palette pill). The dice no longer live here — they moved to the board's center bar
  (`BoardDiceView`, #46). Decision-level undo lives in the debug pane (see below).
- **`WinOverlayView(winner:onNewGame:onHistory:)`** — dimmed scrim, serif "`<Name>` wins!", a
  "Play Again" button calling the injected `onNewGame` closure (provided by `RootView`
  to replace the finished session with a fresh one — see `RootView.swift`), and a secondary
  "History" button (`onHistory`) so the log stays reachable after the game, when the scrim
  covers the in-chrome `HistoryButton`.
- **`HistoryView(session:)`** (#60) — the move-log sheet: a header ("Move history" + a Done
  button calling `@Environment(\.dismiss)`), then a `ScrollViewReader` + `ScrollView` listing
  one `HistoryRow` per ply, auto-scrolling to the newest on appear and on `history.count` change.
  Empty history shows "No moves yet". Bound via `@ObservedObject`, so a freshly committed ply
  appears immediately. `#ece6dc` background. `PlyRecord` is the persistence format (no `index` /
  `mover` fields), so the view derives the 1-based index from `enumerated()` offset and the mover
  from `session.startingPlayer` alternating every ply (`index % 2 == 1 → startingPlayer`, else
  `startingPlayer.opponent`). `ForEach` uses `id: \.offset`; `scrollToLast` targets
  `session.history.count - 1`.
  - **`HistoryRow(index:mover:ply:)`** — a row showing the 1-based `index`, a
    `ChromeTheme.checkerColor(mover)` disc, the dice (`d=<d1> <d2>`), and the move text
    (`ply.halfMoves` formatted as `from→to` pairs joined by `, `; or a dimmed "(pass)" when
    `halfMoves` is empty). Monospaced so the columns align.
- **`ChromeTheme`** — centralizes the engine-`Color` → display mappings so a future
  visual style swaps them in one place: `displayName` (`.white` → "White", `.black` →
  **"Red"**) and `checkerColor` (white → ivory `#fbeed1`, black → deep red `#a83a2a`),
  plus `ink`/button tints. Reuses `Color(hex:)` from `BoardView.swift`.
- **Previews:** `"Landscape"` / `"Portrait"` on a fresh session, `"Undo/Done"`
  which scripts a half-move (`setManualDice` → `commitHalfMove`) to surface the
  contextual buttons without T7, and `"History"` which scripts a ply and shows
  `HistoryView` directly.

## DebugOverlay.swift (T11 — debug eval overlay)

A toggleable, off-by-default panel exposing the AI's evaluation of the current
position. Two `View`s, both bound to a `GameSession` (`@ObservedObject`), read-only
with **no effect on gameplay**. `GameView` (T10) hosts `DebugOverlayToggle` as a
top-trailing overlay on the game screen.

- **`DebugOverlayToggle`** — the drop-in any screen hosts. A `ladybug.fill` bug-icon
  button with `@State isOn = false` (off by default): tinted yellow when on, dim white
  when off. When on it reveals `DebugOverlay` below it with a 0.15s opacity transition.
- **`DebugOverlay`** — a ~200pt translucent-black panel with four rows:
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
  4. **"Move history"** (#60) — a clock-icon button calling the `onHistory` closure
     (injected via `DebugOverlayToggle(session:onHistory:)` from `GameView`); opens the
     move-log sheet. Replaces the former standalone bottom-leading `HistoryButton`.
  5. **"↩ Undo decision"** — calls `session.undoLastDecision()`; yellow when
     `session.canUndoLastDecision`, dim otherwise. This is the only surface for
     decision-level undo (stepped back from `ControlsView` which now only peels half-moves).

  Uses plain SwiftUI `Color` (`.black`/`.yellow`/`.white`); unlike the other views it does
  not need `Color(hex:)` or `ChromeTheme`.

## OpeningRollView.swift (#33 — opening roll ceremony)

Pre-game screen that resolves the starting player before creating a `GameSession`. Shown
between mode picker and game (and again after "Play Again"), so every game picks its own
starter. Calls `onStart(EngineColor)` with the winner; `onBack` returns to the mode picker.
The board is the main visual; chrome mirrors `GameView`'s layout and text style exactly.

- **Layout** — responsive, matching `GameView`:
  - *Landscape*: board fills the height (`maxWidth:.infinity, alignment:.leading`, 8pt pad),
    chrome side panel (260pt, 12pt trailing + vertical pad; top-padded 44pt to clear the Back
    button corner).
  - *Portrait*: `VStack` — status block at top, `Spacer`, manual-row just above the board,
    board at bottom with `.layoutPriority(1)` (same pattern as `GameView`'s `ControlsView`).
  - Floating Back button in top-leading corner, styled identically to `GameView.BackButton`
    (amber tint `.opacity(0.22)` background, `.opacity(0.6)` stroke, `CaramelPalette.frameText`
    foreground).
- **`OpeningRollView`** — `humanColor`, `onStart`, `onBack` injected. State machine:
  - `.idle` — empty dice (`DieFace(value: 0)` = no pips), halo pulsing, "Tap the board to roll".
  - `.rolling` — 0.42s tumble animation (4× 0.09s easeInOut, same as `BoardDiceView`); halo hidden.
  - `.tied(h, a)` — shows tied values, "Tie (X vs Y) — rolling again…"; halo reappears; auto
    re-rolls after 1 second. The `if case .tied = rollState` guard prevents double fire if the
    auto-timer and a board tap race.
  - `.resolved(humanDie, aiDie, winner)` — "You / AI go first!" caption; manual-override row
    hidden. Auto-starts the game via `startGame(winner)` after 1 s. Tapping the board is a no-op.
- **Auto-start** — `startGame(_ winner:)` guards with `@State private var started: Bool` so
  neither the auto-timer nor the manual-override buttons can call `onStart` twice.
- **Board overlay** — `BoardView()` + a `GeometryReader` overlay calling `openingDice(in:)`,
  `.aspectRatio(1,.fit)`, `.contentShape(Rectangle())`, `.onTapGesture { startRoll() }`.
  `openingDice` builds a `BoardGeometry`, sizes dice at `geo.diceSize` (identical to game dice),
  and places:
  - *AI die*: `(boardCenter.x, boardCenter.y − step)` where `step = dieSize + 12·scale`
    (the same spacing used between normal horizontal game dice).
  - *Human die*: `(boardCenter.x, boardCenter.y + step)`. Rendered with `isHighlighted: showHalo`.
  Both dice use `DieFace(value:, size:)` (value 0 = empty face = "not yet rolled"). Each die
  gets its own `.rotationEffect` / `.scaleEffect` so it tumbles around its own center.
  The human die reuses `DieFace.isHighlighted` (the same `CaramelPalette.hl` gold ring that the
  game dice show during `awaitingRoll`) rather than a bespoke overlay.
- **Chrome text** (`statusBlock`) — `.headline` + `.caption` layout matching `TurnIndicatorView`
  exactly: `CaramelPalette.frameText` ink at full and 0.6 opacity.
- **`manualRow`** — `@ViewBuilder`; shows "You start" / "AI starts" (amber tint) while not
  resolved; hidden (`EmptyView`) once resolved (game is auto-starting).
- **`ORButton`** — pill `ButtonStyle` matching `GameView`'s `ControlButtonStyle`: tinted
  `.opacity(0.22/0.45)` background, `.opacity(0.6)` stroke, `CaramelPalette.frameText` foreground.

## RootView.swift (T10 — root navigation + mode picker; #61 save/load)

The app's top-level view: switches between the caramel **mode picker**, the opening roll,
and a live game. Owns all save/load wiring (#61) through a single `SaveStore.default()`.

- **`RootView`** — `@State` vars: `session: GameSession?`, `humanColor: EngineColor`,
  `pendingHumanColor: EngineColor?`, `autosaveName: String` (the current game's stable display
  name — a timestamped `"Game · <date>"` default via `newAutosaveName()` for a fresh game, or the
  resumed game's own name). Body is a three-way branch inside `Group { }.onChange(of: scenePhase)`:
  - `session != nil` → `GameView(session:onBack:onNewGame:onSave:onAutosave:)`. `onBack`
    auto-saves then resets `session = nil`. `onNewGame` (Play Again) sets `session = nil` and
    `pendingHumanColor = humanColor`, routing through the opening roll. `onSave` writes a named
    manual save; `onAutosave` is `persistAutosave`.
  - `pendingHumanColor != nil` → `OpeningRollView`. On resolution mints a fresh `autosaveName`,
    stores `humanColor`, clears `pendingHumanColor`, and creates the session.
  - else → `ModePickerView`. Tapping a color sets `pendingHumanColor`.
  `makeSession(humanColor:startingPlayer:)` builds `GameSession(startingPlayer:, aiColor:
  humanColor.opponent)` and calls `start()`. The UI-test hook bypasses the opening roll and
  passes `startingPlayer: .black` explicitly.
- **Save/load lifecycle (#61).**
  - **Auto-save** (`persistAutosave`) fires after **every move** (`GameView`'s
    `.onChange(of: session.history.count)`), as well as on `scenePhase == .background`
    (`@Environment(\.scenePhase)` + `.onChange`) and on Back. It writes the in-progress game to
    the single reserved autosave slot under the game's stable `autosaveName`
    (`store.writeAutosave(session.snapshot(name:))`), overwriting it each time so only the
    **last** in-progress game is kept. It **clears** the slot instead if `session.isTerminal`
    (finished games are never resumed), and no-ops on the picker (`session == nil`) so a prior
    autosave survives. IO is synchronous so it completes before the app suspends.
  - **`newAutosaveName()`** mints the timestamped `"Game · <date>"` name (medium date + short
    time, the same convention the manual-save dialog defaults to), generated once per game and
    kept stable across that game's per-move autosaves so the slot reads as one coherent identity.
  - **Auto-resume** (`autoResume`, called from `init`) loads a non-terminal autosave and replays
    it via `GameSession.resume(from:agent:)` + `start()`, landing the cold launch back in the
    game (acceptance criterion 1); a terminal autosave is discarded so launch shows the picker.
    The `-uiTestGame` launch arg still takes priority (deterministic Black-to-move game).
  - **Resume from the list** (`resume(_:)`) loads the chosen `SaveMetadata`, derives `humanColor`
    from `save.aiColor.opponent`, carries `save.name` forward into `autosaveName` (so continued
    play keeps the same identity), and switches into the replayed session.
  - Human color is recovered from `save.aiColor` (the human is the AI's opponent); a save with no
    AI color defaults the human to White.
- **`ModePickerView(store:onSelect:onResume:)`** — `#ece6dc` background, a large Cormorant
  Garamond "Tavli" wordmark, two caramel `ModeButton`s ("Play vs AI / You play White|Black"),
  and (#61) a **`SavedGamesList`** below them when any saves exist. Loads `store.list()` in
  `@State saves` on `onAppear` (`reload`); `delete` removes a save and reloads. `onSelect` sets
  `pendingHumanColor` (routes through the opening roll). The design
  reference's "Watch AI vs AI" mode is **deferred** (out of scope).
- **`SavedGamesList(saves:onResume:onDelete:)`** (#61) — a titled "Saved games" section: a
  scrollable (`maxHeight 240`) `VStack` of `SavedGameRow`s.
- **`SavedGameRow(meta:onResume:onDelete:)`** (#61) — one row: an icon (autosave →
  `arrow.clockwise.circle.fill`, else `doc.fill`), the save's `meta.name` (every row, autosave
  included, now carries its own timestamped name), a subtitle (medium date + `N moves` from
  `meta.savedAt` / `meta.plyCount`), and a trailing trash button. The autosave row adds a small
  uppercase **"Continue last game"** capsule badge **above** the name (marking the resumable
  last game without replacing its identity). Tapping the body resumes; the trash button deletes.
  Caramel-tinted card (white @ 0.35 fill, `frameBot` hairline).
- **`ModeButton` / `ModeButtonStyle`** — a caramel wood pill (frame-palette top→mid
  gradient, `frameBot` border, `frameText` ink, press-dim via `.brightness`).
- `EngineColor` is a `private typealias` for `TavliEngine.Color` to disambiguate from
  `SwiftUI.Color` (mirrors `GameView`'s `SColor`).

## App.swift

`@main`. Minimal — `WindowGroup { RootView() }`. (Earlier the T7 sign-off bootstrap
hosted `PlayableBoardView` on a fixed scenario here; T10 moved the entry to `RootView`.)
