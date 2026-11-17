# Views — SwiftUI rendering layer reference

Reimplementation-grade per-view detail for the SwiftUI rendering layer. The
directory `CLAUDE.md` carries the per-view index and shared conventions; this
file holds the full breakdown. Views own all drawing/aesthetics; pure geometry
lives in the `BoardGeometry` package (engine-free) and game logic in
`TavliEngine`. Views depend on both; neither depends on views.

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
- **`AIFlightCheckerView`** (#93) — the AI's checker arcing `hop.from → hop.to`
  while `GameSession` publishes an `AIAnimatedHop`. Purely presentational: it
  never touches game state — the engine applies the half-move (and clears the
  hop) when the flight time elapses. Takes the **pre-hop** stacks (the flying
  checker still counted at `from`) and derives the endpoints from
  `geo.checkerCenter`: lift-off at the source's top visible slot
  (`min(count, 5) − 1`), landing at the destination's next visible slot
  (`min(count, 4)`, merging into the 5-stack cap). The path is a quadratic
  Bézier whose control point sits above both endpoints in *screen* space
  (upward whatever the board orientation): `lift = min(24·s + 0.22·span,
  130·s)` over the midpoint. `onAppear` runs `withAnimation(.easeInOut(duration:
  hop.duration)) { progress = 1 }`; a zero duration snaps to the end.
- **`ArcFlightEffect`** (private, #93) — a `GeometryEffect` whose
  `animatableData` is the flight progress: it evaluates the Bézier at `t` and
  builds a `ProjectionTransform` translating the content's center to the curve
  point, scaled about that center by `1 + 0.10·sin(π·t)` so the checker swells
  slightly as the arc crests. A `GeometryEffect` (not an `Animatable` view) so
  the interpolation is guaranteed to drive rendering without re-layout.
- **`FlightDisc`** (private, #93) — the flying disc itself: a small `Canvas`
  (side `2·(r + 16·s)`, padded so the lifted shadow isn't clipped) drawing
  `drawCheckerDisc(lifted: true)` at its center. Anchored at the board origin
  via `.position(x: 0, y: 0)`; `ArcFlightEffect` does all the moving.
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
  **AI dice roll (#93):** the engine sets the AI's dice values up front (the
  search needs them) and publishes `aiDiceRolling` for `aiDiceRollDuration`.
  `.onChange(of: session.aiDiceRolling, initial: true)` — `initial: true`
  because an AI that opens the game starts tumbling before the view appears —
  drives `beginAITumble` / `settleAITumble`: two full rotations easing out over
  the engine's window (`spin += 720`) plus the 0.92 scale dip, while a
  `Task` cycles **random masking faces** (`aiMaskFaces`, two dice, swapped every
  90 ms) so the real roll stays hidden until settle; a pasch reveals its four
  dice only then. The row's rotation is plain `.degrees(spin)` (not gated on
  `tumbling`): both tumbles end on a multiple of 360°, so the settled row
  renders unrotated and no gate-flip can animate a backward unwind. Greying
  still works during the AI's moves because the engine commits each landed hop
  into `moveBuilder` — `usedDiceFlags` greys the used die as each hop lands.
- `#Preview`s: a "Dice — states" matrix over `DiceRow` (normal, each side
  consumed, pasch, partially/fully consumed — including a right-die-consumed
  case demonstrating the #46 fix). (The manual-dice tap-grid, #110, was removed in #174 —
  the human's dice are always rolled: by tap or by auto-roll.)

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
  #40), the snap-back overlay, and **`AIFlightCheckerView`** (the AI's arcing
  checker, #93), all above the dice. All layers rebuild an identical
  `BoardGeometry` from the same square fit, so they register exactly; the
  gesture geometry is built from the same `GeometryReader` size. The container
  is `.aspectRatio(1, .fit)`.
- **Display slots (#143)** — every layer works on `BoardLayout.displayStacks` of the live
  board (28 slots: engine 0…25 with trays = borne-off only, plus White/Black bar slots 26/27,
  which `BoardGeometry` places on the centre bar — `lowerBarSlot`/`upperBarSlot`). Sources are
  mapped with `displaySlot(forSource:)` for hit-testing/rings/drag, and back with
  `sourcePosition(forDisplaySlot:)` (trays → never a source) before calling `selectPoint` /
  `commitHalfMove`; targets are identical in both spaces. So a Portes bar checker is tapped /
  dragged from the bar, and AI bar entries lift off the bar. **Hit animation:** `.onChange` of
  the display stacks runs `BoardLayout.hits(from:to:)`; each hit spawns an `ArcFlightView`
  from the hit point to the bar slot (duration = `aiMoveAnimationDuration`, skipped when 0),
  with that bar shown one short until it lands — for AI and human moves alike.
  `ArcFlightView` (`CheckersView.swift`) bows a row-changing flight (Plakoto 12→13, Fevga
  Black's 24→1 wrap) outward toward the nearer side edge instead of over the top frame.
  `CheckersView`/`MoveHighlightView` accept engine stacks + `variant:` (split internally) or
  display stacks; `MoveHighlightView` rings a bar-entry source on the bar.
- **AI flight (#93)** — while `session.aiHopInFlight` is non-nil,
  `displayStacks` drops the top checker at `hop.from` (same trick as the drag
  source) and `AIFlightCheckerView` renders it arcing to `hop.to`, fed the
  **pre-hop** `boardStacks` so the lift-off/landing slots match what
  `CheckersView` shows. `.id(hop.id)` forces a fresh view per hop so the flight
  restarts even when consecutive hops share endpoints (a Pasch moving two
  checkers along the same route — the engine publishes `nil` between hops, but
  the two assignments land in one main-actor turn, so identity must come from
  the ordinal). No input gating is needed here: the engine keeps
  `selectableSources` empty and the phase guards reject intents during
  `aiThinking`/`animating`, and the dice ignore taps via
  `.allowsHitTesting(canRoll)`.
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
  `MoveBuilder.routeOptions`), so the view still just renders `validTargets` and routes one
  `commitHalfMove` per tap or drop.
- **Route choice (#169, Portes).** When a far drop/tap has routes ending in different positions
  (hit vs no hit, different blots), the session sets `routeChoice` and plays nothing: the board
  rings the source, frames the destination amber and the candidate intermediate points in
  `CaramelPalette.hlRoute` (the review blue, via `TargetHighlightView(tint:)`), and the turn
  indicator / drill feedback line read "Choose where to land in between" (EN/DE/NL). While it is
  pending no drag starts; the next touch goes to `handleTap` → `session.chooseRoute(via:)` — a
  candidate plays that route as one gesture, anything else cancels with nothing played.
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
  scripted dice `3·5` and point 1 selected, reproducing the design's reference
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

**Variants (#143).** The turn-status block opens with the variant's name (uppercase caption,
`accessibilityIdentifier("variantName")`). `BorneOffView` counts via
`BoardLayout.borneOffCount` (never the raw end stack). The win overlay shows for
`.gameOver(winner: nil)` too: title "Draw" + `ResultCopy.drawSubtitle`; a win in a 2-point
variant gets a "Double game · 2 points" / "Single game · 1 point" subtitle and the turn label
"… wins a double game". The vs-AI record card is hidden for two-player games
(`WinOverlayView.showsStats`). `GameView.Match.lastGameResult: MatchGameResult?` replaces
`lastGameWinner` (offline falls back to `session.record.result`); `MatchScoreboardView` /
`MatchOverlayView` show `score(for:)` (points) and a draw title/subtitle. `WinProbabilityBar`,
the resign confirmation's chance line and `DebugOverlay` go through `EvalScale` ("Equity +0.52" for 2-point
variants). Review falls back to `makeAgent(config:)` for a two-player game.

- **`GameView`** (`@ObservedObject session`, plus `stats: HumanGameStats = .empty` (#64) — the
  human's record shown in the win overlay, `onBack: () -> Void = {}` — returns to the mode
  picker, `onNewGame: () -> Void = {}` — replaces the finished session with a fresh one,
  `onSave: (String) -> Void = { _ in }` (#61) — persists the game under the given name, and
  `onAutosave: () -> Void = {}` (#61) — writes the single autosave slot; all non-session args
  default to no-ops so `#Preview`s compile). A `GeometryReader`
  switches layout on `width >= height`:
  - **Landscape (#101):** `HStack` with `PlayableBoardView(session:)` filling the height and
    **bound to the leading edge** (`.frame(maxWidth:.infinity, maxHeight:.infinity,
    alignment: .leading)`, `8pt` pad) and a fixed 280pt `sidePanel` on the trailing edge.
    **The board owns the leftover width via that frame, not `Spacer`s** (#46): two flanking
    spacers and the equally-flexible aspect-fit board split the width three ways, shrinking
    the board to a third of the height — the spacers are gone. `.leading` pins the square to
    the left so the slack between board and panel sits on the right and the board never
    shifts as the panel chrome changes. The panel is a card stack holding ALL the chrome
    (nothing floats over the board's frame): a `Back` + `DebugToggleButton` row, the docked
    `DebugOverlay` when open, the status card (`TurnIndicatorView` + the two `BorneOffView`
    chips in a `.chromeCard`), a `Spacer`, then — hidden once `session.isTerminal` — the
    Save/Resign row and `ControlsView` anchored at the bottom.
  - **Portrait (#101):** `VStack(spacing: 12)` — the `portraitTopBar` (one organized bar:
    Back/Save/Resign leading, the two `BorneOffView` chips trailing) pinned to the top, a
    flexible `Spacer(minLength: 0)`, then the turn status (`TurnIndicatorView`) stacked with
    `ControlsView` just above the board (near where the player looks; both hidden/reduced
    once terminal), and the board (`8pt` horizontal pad), with the `VStack` filling the
    height (`.frame(maxWidth:.infinity, maxHeight:.infinity)` + `12pt` vertical pad). A
    square board can't fill a tall screen, so some vertical margin is unavoidable; #46
    controls **where** it goes. The board is **bound to the bottom edge**: the chrome pins
    to the top, the `Spacer` pools the slack into the middle. `.layoutPriority(1)` on the
    board lets it claim its full-width square first so the `Spacer` (not the board) absorbs
    the slack; without it two equally-flexible children (Spacer + aspect-fit board) split
    the height and the board shrinks below full width. The debug toggle + pane float
    top-trailing (`.padding(.top, 64)` clears the top bar), over the empty band.
    Verified by rotating the sim headlessly with `XCUIDevice.orientation` in a throwaway UI
    test and inspecting screenshots (portrait via XCTAttachment; landscape via host-side
    `simctl io screenshot` polling — attachments garble during rotation on current runtimes).
  - The `SaveButton` and `SurrenderButton` are hidden once `session.isTerminal` (finished
    games aren't saved/resigned, #61/#74). The `SurrenderButton` (destructive brick "Resign")
    is additionally `.disabled`/dimmed when `!session.canSurrender`, so it greys out — rather
    than vanishing — while the AI is thinking. All buttons use `ChromeButton` roles
    (`ChromeKit.swift`, #101).
  - **Move-history sheet (#60):** `DebugOverlay` is passed `onHistory: { showHistory = true }`
    for its "Move history" button. The `.sheet(isPresented: $showHistory)` is attached to the
    `ZStack` with `.presentationDetents([.medium, .large])` + a drag indicator (#101);
    `WinOverlayView` also carries its own History button so the log stays reachable after the
    game when the scrim covers the debug pane.
  - **Manual save (#61):** tapping Save runs `presentSaveDialog` — seeds `saveName` with a
    timestamped default (`"Game · <date>"`) and flips `showingSaveDialog`. A `.alert("Save
    game", isPresented:)` hosts a `TextField` + "Save"/"Cancel"; "Save" trims the field and
    calls `onSave(name)` (falling back to the timestamp default if left empty). `RootView`
    provides `onSave` to write a named manual save via the `SaveStore`.
  - **Auto-save (#61):** `.onChange(of: session.history.count) { onAutosave() }` fires once per
    ply — `history` grows by one per finished turn (human, AI, or forced pass) — so the
    in-progress game is persisted after **every move**, not just on background. `RootView`'s
    `persistAutosave` overwrites the single autosave slot (or clears it once the game is over).
    #171: a second `.onChange(of: session.rollRevision) { onAutosave() }` also writes it as soon
    as a roll exists (human tap / auto-roll, and the AI's roll), so the save
    carries `pendingRoll` and a crash mid-turn resumes with the same dice. Online passes no
    `onAutosave`, so both are no-ops there.
  - **Surrender / resign (#74):** one confirmation everywhere (iPad Resign button and the
    iPhone "⋯" menu both call `onSurrenderTapped`). It captures `surrenderChanceLine` — "You still
    have a X% chance of winning." (or "TavTav still rates your position at +0.52 points." for a
    2-point variant via `EvalScale`) only when `session.humanWinProbability` is known **and** above
    `surrenderWarningThreshold` (10%), else `nil` — then flips `showSurrenderConfirm`. A single
    `.alert("Give up this game?")` shows that line as its message (no message when `nil`) with
    "Keep playing" (cancel) and "Give up" (destructive). "Give up" calls `session.surrender()` then
    `onAutosave()` (or the tournament's `onGiveUp`) — surrender records no ply, so the per-move
    auto-save hook never fires; this clears the now-terminal game's auto-save slot, matching a
    played-out loss.
  - **Game-over overlays** are layered **last** whenever `session.phase` is `.gameOver` (or an
    online match's `showResultOverlay`): a `black.opacity(0.65)` scrim as a **direct ZStack
    child** (hosting it inside the overlay sized it to the board column in landscape, leaving
    the panel bright), then exactly one of `FullTavliLegOverlayView` / `MatchOverlayView` /
    `WinOverlayView` (win or draw). All three render through the shared **`GameOverCard`**
    (`GameOverCard.swift`), so they look identical — see below.
  - **Winner wording** comes from one `WinnerNaming(localColor:opponentName:)` built by
    `GameView.naming` and used by every overlay and `TurnIndicatorView`: vs the AI "You win" /
    "TavTav wins", online "You win" / "`<opponent>` wins" (Game Center name), two-player
    "White wins" / "Red wins"; `doubleTitle` adds "a double game". (Tournament keeps its German
    verdict.)
  - **Review gating:** `hasReviewableMoves` (any ply in `session.history` with half-moves) — a
    game resigned before any move offers no "Review game" in any overlay. Full Tavli also needs
    the leg's model; the match overlay only vs the AI; online never.
  - Page background is `#ece6dc` (matches `RootView`'s picker).
- **`BackButton`** — chevron + "Back", `ChromeButton(role: .secondary)`, calling the
  injected `onBack`.
- **`SaveButton`** (#61) — download glyph + "Save", `ChromeButton(role: .secondary)`,
  calling the injected open-dialog action.
- **`SurrenderButton`** (#74) — flag + "Resign", `ChromeButton(role: .destructive)`.
- **`TurnIndicatorView`** — maps `session.phase` to a headline: `.awaitingRoll` →
  "`<Name>`'s turn" + "Tap dice to roll" caption; `.picking` → "Pick a checker";
  `.moving` → "Choose destination"; `.aiThinking` → "AI thinking…"; `.animating` →
  "`<Name>` moving…"; `.gameOver(w)` → `naming.title(w)` ("You win" / "TavTav wins" /
  "Red wins", or `doubleTitle` for a 2-point result). `<Name>` and the player come from
  `ChromeTheme` + `session.currentPlayer`; the winner wording from the `WinnerNaming` passed in.
- **`BorneOffView(session:color:)`** — a horizontal chip (#101): checker-colored disc,
  `displayName` in secondary ink, bold monospaced-digit count, on an `ink.opacity(0.06)`
  rounded fill. Counts read straight off the board on each session publish: white =
  `board.points[board.boardSize + 1].count`, black = `board.points[0].count`. They
  refresh because `phase`/`selectableSources` republish on every transition.
- **`ControlsView`** — **Undo** is persistent (#59): always rendered (while the game is
  live; the call sites hide the whole row once terminal, #101), calling `session.undo()`,
  greyed (`.disabled` + `0.4` opacity) when `session.canUndo` is false. It peels the last
  committed half-move within the current turn (within-turn only; the engine's manual-dice step-back
  was removed in #174/#176 — whole-decision rewind stays in the debug overlay's
  `undoLastDecision`). **Done** (`session.confirm()`) is still
  contextual: shown only when `moveBuilder.canFinishNow && !built.isEmpty`, and carries
  `ChromeButton(role: .primary)` — the one solid button on the board screen — while Undo is
  `.secondary`. The dice no longer live here — they moved to the board's center bar
  (`BoardDiceView`, #46). Decision-level undo lives in the debug pane (see below).
- **`GameOverCard`** (`GameOverCard.swift`) — the one game-over surface: a single centred
  solid card (`.chromeCard()`, padding 28 / 16 compact, `frame(maxWidth: 440)`, full width minus
  a 16 pt gutter on a phone) over `GameView`'s scrim, so its ink text never collides with the
  status text / dice / checkers behind. Top to bottom: `TavTavAvatar` (96 pt, **iPad only**),
  the serif verdict (`ChromeType.winTitle`, ink, ≤ 2 lines, scales to 0.6), an optional
  subtitle (points / draw reason, `inkSecondary`), an optional `GameOverScore` block styled
  like the in-game scoreboard (names in callout, digits `title3.bold().monospacedDigit()` on an
  `ink.opacity(0.06)` inset, caption beneath), optional extra content, the full-width
  `.primary` action, "Review game" / "History" as `.secondary` full-width buttons side by side
  (stacked when they can't fit; Review omitted when `onReview == nil`), then an optional exit
  ("Back to menu") as `.quiet`. Wrapped in `FitOrScroll(enabled: compact)` so it scrolls only
  if a phone can't fit it. `GameOverAction` / `GameOverScore` are the plain value inputs.
  `WinnerNaming` (same file) is the shared winner wording.
- **`WinOverlayView`** (#101) — single-game win/draw on the `GameOverCard`: the verdict
  (`GameView.verdict(_:)` → `naming.title`), subtitle, the human's record as an embedded
  `StatsPanelView(stats:embedded:true)` (auto-shown after every vs-AI game, #64; condensed to
  the overall line in iPhone landscape so the card fits), primary "Play Again" (or "Back to
  lobby" online / the tournament exit), Review (hidden online or with nothing reviewable) and
  History. The just-finished game is already counted: `session.onGameOver` records into
  `RootView`'s store, whose `@Published` change re-renders `RootView` → passes fresh `stats`
  down before the overlay paints.
- **`MatchOverlayView`** (#145) — best-of-three on the `GameOverCard`: per-game verdict (or the
  match verdict once decided), score block "You 0 – 1 TavTav" with the caption "Game N of M"
  where **N is the game that just finished** (`state.results.count`, not `currentGameNumber`,
  which already points at the next game) or "Final", primary "Next game" / "Rematch" / "Back to
  lobby", Review / History, and "Back to menu".
- **`HistoryView(session:naming:)`** (#60, #178) — the move-log sheet: a header ("Move history" +
  a Done button calling `@Environment(\.dismiss)`), then a `ScrollViewReader` + `ScrollView`
  listing one `HistoryRow` per turn, auto-scrolling to the newest on appear and on
  `history.count` change. Empty history shows "No moves yet". Bound via `@ObservedObject`, so a
  freshly committed ply appears immediately. `#ece6dc` background. `PlyRecord` is the
  persistence format (dice + `[from, to]` pairs only), so the view computes every row's
  notation with `MoveNotation.game(session.history, startingPlayer:, config:)` (replays the
  game from its start — hits/pins/mother need the position) and derives the mover from
  `session.startingPlayer` alternating every ply. `naming` is `GameView`'s `WinnerNaming`, whose
  `name(_:)` labels the mover "You" / "TavTav" / the online opponent / "White" / "Red".
  `ForEach` uses `id: \.offset`; `scrollToLast` targets `session.history.count - 1`. Phone:
  12 pt side padding instead of 20.
  - **`HistoryRow(index:mover:moverName:notation:)`** — the 1-based `index`, a
    `ChromeTheme.checkerColor(mover)` disc + mover name (fixed 120 / 76 pt column, truncating),
    the roll as `NotationDice` (22 / 18 pt die faces, high die first), and a `MoveNotationLine`
    that takes the remaining width and wraps rather than truncating. Rows zebra-stripe (#101):
    odd offsets get an `ink.opacity(0.04)` rounded background instead of divider lines.
- **`ChromeTheme`** — centralizes the engine-`Color` → display mappings so a future
  visual style swaps them in one place: `displayName` (`.white` → "White", `.black` →
  **"Red"**) and `checkerColor` (white → ivory `#fbeed1`, black → deep red `#a83a2a`),
  plus `ink`/button tints. Reuses `Color(hex:)` from `BoardView.swift`.
- **`ChromeType`** (#92) — centralizes the chrome's typography as fixed sizes one step
  larger than the SwiftUI text styles the chrome originally used (the app targets older
  players reading at arm's length). System-style mirrors: `title2` 26, `title3` 24,
  `headline` 22 semibold, `body` 20, `callout` 19, `subheadline` 18, `caption` 16,
  `caption2` 14. Display faces: `winTitle` 54 bold serif, `statsTitle` Cormorant 38 (never
  for digits — `scoreDisplay` 34 bold system is the big-score face),
  `wordmark` Cormorant 96. Debug pane: `debugMono` 12 monospaced, `debugLabel` 13.
  Weight/design variants are applied at the use site (`.bold()`, `.monospaced()`,
  `.weight(:)`). Dynamic Type is a deliberate non-goal for now. Used by **all** chrome
  views (`GameView`, `OpeningRollView`, `RootView`, `StatsPanelView`, `DebugOverlay`);
  the board, dice faces and checkers keep their own geometry-scaled sizing.
- **Previews:** `"Landscape"` / `"Portrait"` on a fresh session, `"Undo/Done"`
  which scripts a half-move (`setDice` → `commitHalfMove`) to surface the
  contextual buttons without T7, and `"History"` which scripts a ply and shows
  `HistoryView` directly.

## MoveNotationViews.swift (#178 — move notation rendering)

Presentation of the engine's `MoveNotation` (see the engine reference), shared by the history
sheet, the review panel and the drill panel. Notation tokens (`bar`, `off`, point numbers,
`*`, `^`, `(n)`) are never translated; only "No move" and "Mother pinned" are localized
(DE/NL in `Localizable.xcstrings`).

- **`MoveNotationText(notation:font:color:accent:)`** — one concatenated `Text` built from the
  structured segments (`from` + `/stop` per stop + `(count)`), monospaced in `font`/`color`; a
  pin `^` is `.heavy` in `accent` (default `ChromeTheme.undoTint`, the app tint), a hit `*` is
  bold in the text colour. A pass renders "No move" italic in `ChromeKit.inkSecondary`. Wraps
  vertically (`fixedSize(horizontal: false, vertical: true)`).
- **`NotationDice(notation:size:)`** — the roll as two `DieFace`s, high die first (a double
  shows two equal faces); one accessibility element reading the two numbers.
- **`MotherPinnedLabel`** — small amber capsule "Mother pinned" (`caption2` bold, undo-tint
  text on a 14% fill + 45% stroke).
- **`MoveNotationLine(notation:font:color:)`** — `MoveNotationText` with the
  `MotherPinnedLabel` stacked under it when `notation.motherPinned`.
- **Use sites:** `HistoryRow` (whole game via `MoveNotation.game`); the review's "You
  played"/"Best move" lines and its dice row (`NotationDice`, replacing "Dice a · b") and the
  drill's "You played"/"You tried"/"Best move" rows, both via `MoveNotation.describe(_:die1:
  die2:mover:stacks:config:)` on the evaluation's pre-move `boardStacks` — so played and best
  moves read identically however their halves were ordered.
- **Preview** `"Notation"`: a standard-Plakoto mother pin + a pass.

## ChromeKit.swift (#101 — chrome component kit)

The chrome's shared visual language: flat tinted surfaces, soft shadows, one button
system, one card style. Everything outside the board (picker, game chrome, overlays,
sheets, debug pane) builds on it; the board, dice and checkers keep their own Canvas
styling. Sized for older players: every button renders ≥ 44 pt tall and secondary text
never drops below 0.72 ink opacity.

- **`ChromeKit`** — tokens: `cardRadius` 16, `buttonRadius` 12, `cardColor` `#f6f0e3`
  (a touch brighter than the `#ece6dc` page so cards lift without borders), `cardShadow`
  (black @ 0.10), and `inkSecondary` (`ChromeTheme.ink.opacity(0.72)`) — the single
  allowed dimmed text color (replaces the scattered 0.5/0.6 opacities).
- **`.chromeCard(padding:)`** (View extension) — pads content (default 20), card fill,
  `cardRadius` corners, soft drop shadow (radius 10, y 3).
- **`ChromeButton(role:fullWidth:)`** — the one button `ButtonStyle`: `ChromeType.callout`
  bold label, 12 pt vertical padding (≥ 44 pt total), `buttonRadius` corners, whole-shape
  hit area. Roles map to **intent, not screen**: `.primary` solid amber fill + white label
  (the single most important action on a surface — e.g. Done, Play Again); `.secondary`
  flat caramel tint + ink (everyday actions); `.destructive` flat brick tint + brick label
  (Resign); `.quiet` no fill + secondary ink. (Game-over overlays use the normal roles on
  their solid `GameOverCard`; there is no on-scrim role.) Pressed states deepen the fill. On a compact
  screen (#109) the insets drop to 14 × 10 with an explicit 44 pt minimum height.

### Compact (iPhone) layout — #109

The iPhone/iPad split lives in one pure helper, **`ChromeLayout`** (package
`BoardGeometry`, unit-tested): from a container size + safe-area insets it returns the
`mode` (`.regular` / `.compactPortrait` / `.compactLandscape`), the square `boardRect`,
the chrome `panelRect`, `boardPadding` and `fontScale`. A container whose shorter side is
< 500 pt is compact (every iPhone, both orientations; never a full-screen iPad); `.regular`
reproduces the pre-#109 iPad numbers (8 pt board padding, 280 pt panel + 12 pt inset), so
**every iPhone change is a separate `if layout.isCompact` branch** and the iPad code paths
are untouched. Compact: portrait — board = full safe width, bottom of the safe area;
landscape — board = full safe height, leading safe edge, chrome in a rail (rail ≥ 220 pt).

App-side helpers in `ChromeKit.swift`:
- `ChromeLayout(proxy)` — builds the layout from a `GeometryReader` (size + insets).
- `\.chromeMode` environment value — set by `GameView` so overlays tighten up.
- `ChromeType.scale` / `ChromeType.isCompact` — set once in `App.init` from the screen
  (`ChromeLayout.fontScale(forScreen:)`: 1 on iPad, 0.86 on a phone ≈ −2…3 pt). Use
  `ChromeType.isCompact` for paddings on scrolling pages (start screen, lobby, settings,
  Full Tavli screens: 40 → 16 via `.compactPadding(_:compact:)`).
- `AdaptiveRow` (row → column when it doesn't fit; compact only), `FitOrScroll` (content
  as is, or in a `ScrollView` when too tall), `.compactSingleLine()` (wordmarks shrink
  instead of clipping DE/NL), `.chromeSecondaryButtonSurface()` (a `Menu` label that looks
  like a secondary button).

**No TavTav mascot on compact layouts** (owner's call — it goes in a future rebrand and
only costs space on a phone): no logo tile in the game / opening-roll chrome, no avatar
in the win / match / Full Tavli overlays or the Full Tavli result screen. iPad unchanged.

Per screen (compact only):
- **GameView** — portrait: icon nav bar (Back · Settings · ⋯ menu with Save/Resign or
  Leave, Move history, debug pane; compact borne-off chips trailing), free space, then
  turn status + one-line scoreboard + win bar + Undo/Done
  right above the board, all in `FitOrScroll`. Landscape: the same pieces in the rail
  beside a full-height board. The debug pane floats over the board (by design); its
  ladybug closes it. Win / match / Full Tavli leg overlays: the `GameOverCard` at full
  width minus a 16 pt gutter, spacing 12, padding 16, in `FitOrScroll`; in landscape the
  vs-AI record is condensed to its overall line so the card fits a 13 mini without scrolling.
- **OpeningRollView** — same arrangement (Back, status, manual choice, board).
- **GameReviewView** — portrait: Close + "Drill blunders" bar, edge-to-edge board,
  Prev/Next pinned under it, move detail + chart in a scrollable card; landscape: board
  + rail (bar, scrolling detail, Prev/Next). The panel is split into `panelInfo` /
  `navRow` / `drillButton`; the regular `panel` recomposes them unchanged.
- **DrillView** — portrait: board edge-to-edge between the prompt and the feedback/
  actions; landscape: the header moves into the card's rail (`railHeader`).

## DebugOverlay.swift (T11 — debug eval overlay)

A toggleable, off-by-default panel exposing the AI's evaluation of the current
position. Read-only with **no effect on gameplay**. The open/closed state lives in
`GameView` (`@State showDebugPane`, #101) so each orientation places the open pane
where it fits: floating under the button in portrait, docked into the side panel
flow in landscape (never covering other chrome).

- **`DebugToggleButton(isOn:)`** — a `ladybug.fill` bug-icon button on a card-colored
  circle: amber when on, secondary ink when off.
- **`DebugOverlay(session:onHistory:width:)`** — a caramel card (`ChromeKit.cardColor`,
  ink text; `width` 240 fixed when floating, `nil` = fill the container when docked)
  with these rows:
  1. **Win-probability meter** — an olive (`doneTint`) `Capsule` fill over an
     `ink.opacity(0.12)` track, width = `geo.size.width * session.winProbability`
     (always WHITE's view), plus the numeric `%`.
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
     (injected from `GameView`); opens the move-log sheet. Replaces the former
     standalone bottom-leading `HistoryButton`.
  5. **"↩ Undo decision"** — calls `session.undoLastDecision()`; amber when
     `session.canUndoLastDecision`, dim otherwise. This is the only surface for
     decision-level undo (stepped back from `ControlsView` which now only peels half-moves).

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
- **Chrome text** (`statusBlock`) — `ChromeType.headline` title plus the roll prompt at
  `ChromeType.body` in **full ink** (#101): "Tap the board to roll" is the screen's call to
  action, not a dimmed caption.
- **`manualRow`** — `@ViewBuilder`; "Or choose manually:" caption + "You start" / "AI starts"
  (`ChromeButton(role: .secondary)`) while not resolved; hidden (`EmptyView`) once resolved
  (game is auto-starting).
- **Layout (#101)** mirrors `GameView`: landscape = board leading + a 280pt panel (Back row,
  then the `statusBlock` in a `.chromeCard`, then `manualRow` directly beneath — nothing
  pinned to a far corner); portrait = a top bar (Back leading, `statusBlock` centered via
  `ZStack`) with `manualRow` right below, then the bottom-anchored board.

## RootView.swift (T10 — root navigation + mode picker; #61 save/load)

The app's top-level view: switches between the caramel **mode picker**, the opening roll,
and a live game. Owns all save/load wiring (#61) through a single `SaveStore.default()`.

**Variants (#143, #174).** The variant is chosen in Settings (`settings.variant`); the start
screen only names it in a quiet "<variant> · change in Settings" line that opens the sheet.
When the selected variant's model is missing (`AppSettings.aiAvailable`) the play card is
replaced by a "TavTav is still learning …" note; "Two players on this iPad" (`beginTwoPlayer`) is always offered — White-facing board,
starter from `variant.startingPlayer(default: .white)`, no match, no W/L record, review via the
variant's model if bundled. `makeSession(humanColor:startingPlayer:variant:vsAI:)` builds the
session with `GameConfig(variant:)` + `makeAgent(config:)`. Play Again / Next game / Rematch
keep the on-screen game's variant and mode. Resume (picker + cold launch) loads the agent for
the **save's** variant and refuses a vs-AI save whose model is missing (`SavedGameRow` shows it
disabled with the badge; subtitles name the variant / "two players"). The finish hook is
`onGameFinished(winner?, points)`: W/L only for decided vs-AI games, every game logged (draws
too), and `match.recordGame(winner:points:)`.

- **`RootView`** — `@StateObject statsStore: HumanStatsStore` (the human W/L history, #64) plus
  `@State` vars: `session: GameSession?`, `humanColor: EngineColor`,
  `pendingHumanColor: EngineColor?`, `autosaveName: String` (the current game's stable display
  name — a timestamped `"Game · <date>"` default via `newAutosaveName()` for a fresh game, or the
  resumed game's own name). Body is a three-way branch inside `Group { }.onChange(of: scenePhase)`:
  - `session != nil` → `GameView(session:stats:onBack:onNewGame:onSave:onAutosave:)` (`stats =
    statsStore.stats`, #64). `onBack` auto-saves then resets `session = nil`. `onNewGame` (Play
    Again) sets `session = nil` and `pendingHumanColor = humanColor`, routing through the opening
    roll. `onSave` writes a named manual save; `onAutosave` is `persistAutosave`.
  - `pendingHumanColor != nil` → `OpeningRollView`. On resolution mints a fresh `autosaveName`,
    stores `humanColor`, clears `pendingHumanColor`, and creates the session.
  - else → `ModePickerView`. Tapping a color sets `pendingHumanColor`.
  `makeSession(humanColor:startingPlayer:)` builds `GameSession(startingPlayer:, aiColor:
  humanColor.opponent)` and calls `start()`. The UI-test hook bypasses the opening roll and
  passes `startingPlayer: .black` explicitly.
- **Save/load lifecycle (#61).**
  - **Auto-save** (`persistAutosave`) fires after **every move** (`GameView`'s
    `.onChange(of: session.history.count)`) and **every roll** (#171, `.onChange(of:
    session.rollRevision)` — the snapshot then carries the turn's `pendingRoll`, and the resume
    paths' `start()` re-enter that turn with the same dice instead of rolling), as well as on `scenePhase == .background`
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
- **Win/loss recording (#64).** A `.task(id: session.map(ObjectIdentifier.init))` modifier on the
  branch arms each live session's game-over hook: `session.onGameOver = { winner in
  store.record(humanWon: winner == humanColor) }` (capturing the `statsStore` + color by value).
  Keying on session identity means it covers **every** entry point uniformly — opening roll,
  resume from the list, and cold-launch auto-resume — rather than wiring at the (static) creation
  sites; it skips the `-uiTestGame` session so test runs never write stats. It runs synchronously
  (no `await`) well before any game can end, so the hook is always armed in time. Observing
  `statsStore` re-renders `RootView` when a game is recorded, so the win overlay and picker read
  fresh `stats`.
- **`ModePickerView(store:stats:onSelect:onTwoPlayer:onResume:onPlayOnline:)`** (#101, slimmed
  in #174) — `#ece6dc` background. Top to bottom:
  - **Top bar** — three 44 pt icon buttons, trailing: My Record (`chart.bar.fill` → the fitted
    `statsSheet`: "My Record" header + **Done** around `StatsPanelView`, `.height(480)` detent),
    Saved games (`tray.full.fill` → `SavedGamesSheet`), Settings (`gearshape.fill` → `SettingsView`).
  - The Cormorant Garamond **"Tavli"** wordmark.
  - **`ContinueCard`** — only while an autosave exists (`saves.first(where: \.isAutosave)`):
    one tappable `.chromeCard()` — amber `arrow.clockwise.circle.fill`, "Continue last game",
    the mode line (variant, "· two players", "Full Tavli ·" prefix) and a date · moves line;
    chevron, or `AIUnavailableBadge` + disabled when its vs-AI model is missing.
  - **`playCard`** — `preferredColor` (default **White**, #174) fixed → one full-width primary
    "Play vs TavTav" button with that colour's swatch; `.ask` → a "Play vs TavTav as" caption
    over two primary White / Red buttons. No model → the "TavTav is still learning …" note
    (a card on a phone). On iPad the play section is a `.chromeCard()` headed by a 128 pt
    `TavTavLoco` (no mascot on a phone, #109).
  - **`matchLengthPicker`** — segmented `MatchLengthSetting.shortLabel` (Single · Best of 3 ·
    Full Tavli) bound to `settings.matchLength`, with a one-line `caption` beneath that keeps
    the height stable ("One game" / "First to two games wins" / "Portes → Fevga → Plakoto").
  - **Secondary rows** — "Two players on this iPhone/iPad" (`onTwoPlayer`) and "Play Online"
    (`onPlayOnline`, #134), full-width `.secondary` buttons with a leading icon + chevron.
  - **`variantLine`** — quiet "<variant.name> · change in Settings" (opens Settings). Hidden
    (opacity 0, keeps its room so the layout never shifts) in Full Tavli mode, which ignores it.

  **Layout.** Phone: one column (≤ 440 pt), spacing 14, inside `FitOrScroll` — fits a 13 mini
  without scrolling; big Dynamic Type / landscape scrolls. iPad: same order in two 380 pt
  columns 32 pt apart — left `leadColumn` (Continue + play card), right `trailColumn` (match
  length, the two secondary rows, variant line) — centred under the wordmark. Loads
  `store.list()` into `@State saves` on appear and again when the saved-games sheet closes.
- **`SavedGamesSheet(store:onResume:)`** (#174) — "Saved games" header + **Done**; the
  **manual** saves only (the autosave is the Continue card) as a scrollable list of
  `SavedGameRow`s, or an empty state ("No saved games yet"). Tapping a row dismisses the sheet
  and resumes; the trash button deletes and reloads.
- **`SavedGameRow(meta:onResume:onDelete:)`** (#61) — `doc.fill` icon, the save's name, its mode
  line and date · moves line (`SaveCopy.mode`/`detail`), a trailing 44 pt trash button. Disabled
  + `AIUnavailableBadge` when a vs-AI save's model is missing (`SaveCopy.resumable`; a Full Tavli
  save needs every leg's). Flat card row: `ChromeKit.cardColor` fill, small shadow.
- `EngineColor` is a `private typealias` for `TavliEngine.Color` to disambiguate from
  `SwiftUI.Color` (mirrors `GameView`'s `SColor`).

## Full Tavli (#144 — `FullTavliViews.swift` + `RootView` wiring)

- **Mode choice.** `ModePickerView`'s match-length pill offers "Full Tavli"
  (`MatchLengthSetting.fullTavli`; the online lobby iterates `onlineCases` without it), captioned
  with the leg order "Portes → Fevga → Plakoto" (#174). In Full Tavli mode the play card is gated on
  every leg's model (`FullTavliSession(...).isAIAvailable()`) with a "still learning some of the
  Full Tavli games" note; "Two players on this iPad" always works.
- **Running it.** `beginFullTavli(humanColor:)` (`nil` = two players) creates the session via
  `AppSettings.newFullTavli` (Plakoto leg per `VariantPreference`), names every leg
  `"Full Tavli · <date>"`, and `startFullTavliLeg` builds each leg's session for the leg's
  variant (its own agent). Starter = single-game rules: vs AI the starting-player setting or the
  opening-roll ceremony (`pendingVariant`/`pendingHumanColor`; backing out of leg 1 cancels the
  session, later legs return to the transition screen), two players
  `variant.startingPlayer(default: .white)`. `onGameFinished` records the leg (game log + W/L as
  for any game) and immediately autosaves the finished leg with the updated session.
- **Screens.** During play `GameView.FullTavli` shows `FullTavliScoreboardView`; at game over
  `FullTavliLegOverlayView` on the shared `GameOverCard` (verdict + points, score, Continue /
  Review if the leg's model is bundled and the leg has moves / History / Back to menu). The
  between-legs and result screens' score card sets the digits in `ChromeType.scoreDisplay`
  (system face, bold, monospaced — lining figures like the in-game scoreboard; the Cormorant
  display face's old-style numerals read "o — ɪ"). Continue sets `fullTavliScreen` to `.transition`
  (`FullTavliTransitionView`) or `.result` (`FullTavliResultView`, "New Full Tavli").
- **Persistence.** `persist(session:fullTavli:name:store:)` writes `snapshot(name:fullTavli:)`;
  a terminal game is cleared only when there is no unfinished session. Manual saves carry the
  session too. `prepareResume` (picker + cold launch) reconciles via
  `FullTavliSession.resume(savedGame:)`: mid-leg → the replayed session, between legs → the
  transition screen, complete → the result screen (cold launch then clears the autosave). A
  vs-AI session save needs every leg's model (`resumeAgent`, `SaveCopy.resumable`); its row
  subtitle is prefixed "Full Tavli ·".

## SettingsView.swift (#77, regrouped in #174)

A sheet (from the start screen's gear and the in-game gear), Caramel-styled — not a stock
`Form`: a "Settings" title + **Done**, then `.chromeCard` sections (uppercase headline) inside
a `ScrollView` capped at 560 pt. Every control binds to `@AppStorage`; each default equals its
`AppSettings` accessor.

- **Game** — *Variant* (`VariantPickerView`, + "Applies to the next new game…"), *Play as*
  (`PreferredColorSetting` Ask / White / Red, default **White**), *TavTav's strength* (slider,
  Relaxed ↔ Best, default Best → `AppSettings.searchConfig`), *Auto-roll* (default **on**).
- **Advanced** — *First move* (`StartingPlayerSetting`: opening roll / I start / TavTav
  starts), *Analyze during play* (#146, default off).
- **Display** — *Animate AI moves* (default on), *Win-probability bar* (default off).

Row builders: `choiceRow` (title + segmented picker + caption), `toggleRow`, `sliderRow`.
Manual dice entry (`DiceModeSetting`) was removed in #174; a stale `settings.diceMode` value
in `UserDefaults` is simply never read.

## StatsPanelView.swift (#64 — human W/L panel)

The iPad analogue of the CLI's post-game summary box. A **pure** view of a
`HumanGameStats` (from `TavliEngine`) — no persistence or game logic; the store lives in
`RootView`. Hosted in two places: inside `WinOverlayView` (auto-shown after every game,
`embedded: true` — a tinted inset instead of a second card; `condensed: true` in iPhone
landscape shows only a caption header + the overall line) and from the mode picker's
"My Record" sheet.

- **`StatsPanelView(stats:)`** — a flat `.chromeCard` (#101; max content width 352) with a
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
  dark scrim.

## App.swift

`@main`. Minimal — `WindowGroup { RootView().preferredColorScheme(.light) }`; `init` sets
`ChromeType.scale` from the screen size (#109, compact type on a phone). **Light only:** the
app has one caramel design, so it never follows system dark mode — `.preferredColorScheme(.light)`
at the root plus `UIUserInterfaceStyle = Light` in `Info.plist` (which also covers sheets,
alerts and Game Center's own controllers); otherwise system segmented pickers turn
dark-styled and unreadable on the light cards. (Earlier the T7 sign-off bootstrap
hosted `PlayableBoardView` on a fixed scenario here; T10 moved the entry to `RootView`.)
