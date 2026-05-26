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
`CARAMEL` table in the reference (only the colors the empty board uses).
`Color(hex: UInt32)` unpacks `0xRRGGBB`. Add later-ticket colors (checker fills,
highlight gold, dice) here as those views land.

## GameView.swift (T9 — game chrome)

The non-board UI framing a game, assembled with the static `BoardView` into a
responsive layout. Pure presentation: every sub-view binds to a `GameSession`'s
published read-state and calls its intents — no game logic lives here. The board
stays visually static (checker rendering T4 / move input T7 are separate, still
open tickets).

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

`@main`. Hosts `BoardView()` padded inside a `#ece6dc` page background (the
reference page color). Replaced the Phase-2 T1 placeholder. T10 (mode picker +
screen assembly) will swap this for `GameView`.
