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
`CARAMEL` table in the reference. It carries the empty-board colors plus the T4
checker colors (`whiteFill/Hi/Ring/Edge/Text`, `redFill/Hi/Ring/Edge/Text`).
`Color(hex: UInt32)` unpacks `0xRRGGBB`. Add later-ticket colors (highlight gold,
dice) here as those views land.

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

## App.swift

`@main`. Overlays `CheckersView(points:)` on `BoardView()` in a `ZStack`, padded
inside a `#ece6dc` page background, showing the Plakoto start position (a
`GameBoard` with `initializeBoard()`: 15 white@1, 15 red@24).
