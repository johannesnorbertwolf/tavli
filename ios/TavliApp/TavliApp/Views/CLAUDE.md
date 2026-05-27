# Views — SwiftUI rendering layer

SwiftUI views for the Caramel board. These own all drawing/aesthetics; pure
geometry lives in the `BoardGeometry` package (engine-free) and game logic in
`TavliEngine`. Views depend on both but neither depends on views.

## BoardView.swift (T3 — static empty board)

Renders the **empty** Caramel board: beechwood frame, mahogany play surface, 24
ivory triangles with tip pips, the slim center bar line, two diamond ornaments,
and the italic `TAVLI` wordmark. No checkers, dice, highlights, or
interactivity — those land in later tickets.

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
`hlEdge` `#7a5400`; `hlFill` `#f6c623` — the fill-mode target). `Color(hex:
UInt32)` unpacks `0xRRGGBB`. Add later-ticket colors (dice) here as those views
land.

## CheckersView.swift (T4 — checker stacks)

Renders the checker stacks on top of `BoardView` — a **pure function of board
state** (`[TavliEngine.Point]`, indexed 0…25). No highlights, interaction, or
animation (later tickets). Like `BoardView` it's a single `Canvas` +
`.aspectRatio(1, .fit)` building `BoardGeometry(rect:)`, so an overlaid
`ZStack { BoardView(); CheckersView(points:) }` shares the same centered-square
fit and the checkers register with the triangles.

- **Stacks** (`drawStack`, porting the reference `Stack`): for each playable
  point 1…24 with a non-empty stack, draw `min(count, 5)` checkers at
  `geo.checkerCenter(point:slot:)` (slot 0 = base, growing away from the
  baseline). Each checker uses its **actual per-slot color** (`pieces[slot]`), so
  a pinned point shows the trapped opponent checker in its own color at the base
  — the color *is* the distinct rendering (no extra marker). When `count > 5`, a
  Cormorant Garamond count label is drawn on the base checker (slot 0), in
  `pieces[0]`'s text color. Bear-off slots (0/25) are **not** drawn (the Caramel
  design never renders bear-off; out of scope for T4).
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
  point (`setPoint(13, [.black, .white, .white])`) with tall stacks to exercise
  the count label.

## PlayableBoardView.swift (T7 — move input + highlighting)

The interactive board: composes the static board, highlight overlays, and
checkers, and turns tap / drag gestures into `GameSession` intents. Binds to a
`GameSession` via `@ObservedObject`; **no game logic lives here** — it only reads
the published view contract (`selectableSources`, `validTargets`, `selectedPoint`,
`game.board.points`) and calls `selectPoint` / `commitHalfMove`.

- **Layer order** (a `GeometryReader` + `ZStack`, bottom → top): `BoardView()` →
  `TargetHighlightView` (below the checkers so a fill sits under them) →
  `CheckersView(points:)` → `SourceRingView` (above, so the ring haloes the
  selected stack). All layers rebuild an identical `BoardGeometry` from the same
  square fit, so they register exactly; the gesture geometry is built from the
  same `GeometryReader` size. The container is `.aspectRatio(1, .fit)`.
- **Gesture** — a single `DragGesture(minimumDistance: 0)` serves both
  interactions, discriminated by travel vs. `dragThreshold` (10pt):
  - **Tap** (travel ≤ threshold, resolved in `onEnded`): `hitTest` over `1…25`;
    if a target is tapped with a source already selected → `commitHalfMove`,
    else `selectPoint(tapped)` (a non-selectable index clears the selection,
    since `GameSession.selectPoint` ignores it).
  - **Drag** (travel > threshold): on first movement, `hitTest` the *start*
    location over `selectableSources` and `selectPoint` it (lift); on `onEnded`,
    `hitTest` the drop over `validTargets` → `commitHalfMove`. A missed drop
    leaves the source selected so the user can still tap a target.
  - No floating ghost checker — the ring + target marks are the feedback, per the
    Caramel design.
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
    a `hlEdge` `2·s` edge. The Caramel design has no bear-off art, so this box is
    the only bear-off visual; there is no persistent tray chrome (borne-off
    checker rendering remains a separate, later concern).
- **`SourceRingView`** — a pure `Canvas` (`.allowsHitTesting(false)`) that, for
  the selected point's `min(count, 5)` visible checkers, strokes a gold circle at
  `geo.checkerCenter(point:slot:)` with radius `checkerRadius + 3.2·s`, width
  `3.4·s` — matching the reference's `selected` ring.
- `#Preview`s: frame + fill drive a `GameSession(startingPlayer: .white)` with
  manual dice `3·5` and point 1 selected, reproducing the design's reference
  highlight scenario (targets 4, 6, 9); two more drive `TargetHighlightView`
  directly with `targets: [0, 25]` (frame + fill) to show the bear-off tray boxes
  without building a near-end-of-game board.

## GameView.swift (T9 — game chrome)

The non-board UI framing a game, assembled with the static `BoardView` into a
responsive layout. Pure presentation: every sub-view binds to a `GameSession`'s
published read-state and calls its intents — no game logic lives here. The board
stays visually static: `GameView` embeds the empty `BoardView()` only — overlaying
the landed `CheckersView` (T4) and wiring move input (T7, still open) are deferred
to screen assembly (T10).

- **`GameView`** (`@ObservedObject session`). A `GeometryReader` switches layout on
  `width >= height`:
  - **Landscape:** `HStack` with `BoardView()` (`.aspectRatio(1, .fit)`) centered
    between spacers, and a fixed 300pt `sidePanel` on the trailing edge (turn
    indicator + the two borne-off counters on top, controls anchored at the bottom).
  - **Portrait (acceptable):** `VStack` — a `topBar` (counters flanking the turn
    indicator), the centered board, then the controls row at the bottom.
  - A `ZStack` overlays `WinOverlayView` whenever `session.phase` is `.gameOver`.
  - Page background is `#ece6dc` (matches `App.swift`).
- **`TurnIndicatorView`** — maps `session.phase` to a headline: `.awaitingRoll` →
  "`<Name>`'s turn" + "Tap dice to roll" caption; `.picking` → "Pick a checker";
  `.moving` → "Choose destination"; `.aiThinking` → "AI thinking…"; `.animating` →
  "`<Name>` moving…"; `.gameOver(w)` → "`<Name>` wins!". `<Name>` and the player come
  from `ChromeTheme` + `session.currentPlayer`.
- **`BorneOffView(session:color:)`** — a checker-colored disc + count + label. Counts
  read straight off the board on each session publish: white =
  `board.points[board.boardSize + 1].count`, black = `board.points[0].count`. They
  refresh because `phase`/`selectableSources` republish on every transition.
- **`ControlsView`** — the existing tap-to-roll `DiceView(session:)` plus contextual
  buttons shown only while `phase == .picking || .moving`: **Undo** (`session.undo()`)
  when `moveBuilder.built` is non-empty; **Done** (`session.confirm()`) when
  `moveBuilder.canFinishNow && !built.isEmpty`. Styled by `ControlButtonStyle` (palette
  pill). These are wired to the real contract but only fully exercise once move input
  (T7) lets a human compose a partial move; until then they appear only in the scripted
  `#Preview`.
- **`WinOverlayView(winner:onNewGame:)`** — dimmed scrim, serif "`<Name>` wins!", and a
  New Game button calling `session.newGame()`.
- **`ChromeTheme`** — centralizes the engine-`Color` → display mappings so a future
  visual style swaps them in one place: `displayName` (`.white` → "White", `.black` →
  **"Red"**) and `checkerColor` (white → ivory `#fbeed1`, black → deep red `#a83a2a`),
  plus `ink`/button tints. Reuses `Color(hex:)` from `BoardView.swift`.
- **Previews:** `"Landscape"` / `"Portrait"` on a fresh session, and `"Undo/Done"`
  which scripts a half-move (`setManualDice` → `commitHalfMove`) to surface the
  contextual buttons without T7.

## App.swift

`@main`. Hosts `PlayableBoardView` bound to a `@StateObject`
`GameSession(startingPlayer: .white)` rolled to `3·5` (the design's reference
scenario), padded inside a `#ece6dc` page background. This is a T7 sign-off
bootstrap — without a dice UI only the first turn is playable. T10 (mode picker +
screen assembly) will assemble the real screen from `GameView` (T9) + the
interactive board.
