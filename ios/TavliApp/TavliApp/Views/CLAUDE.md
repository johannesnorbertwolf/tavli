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

## App.swift

`@main`. Hosts `BoardView()` padded inside a `#ece6dc` page background (the
reference page color). Replaced the Phase-2 T1 placeholder.
