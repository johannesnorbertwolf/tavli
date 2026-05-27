# BoardGeometry

Pure index↔screen math for the square **Caramel** Tavli board, plus hit-testing.
No drawing, gestures, or SwiftUI — only `CoreGraphics` (`CGRect`/`CGPoint`/
`CGSize`/`CGFloat`). Lives in its own SwiftPM target so the parity-verified
`TavliEngine` target stays untouched; it has no dependency on the engine (a slot
is just an `Int` index).

This is a faithful port of the design reference
`docs/design/tavli/project/Tavli Board.html` — the `pointGeom(n)` function and
the module constants near the top of its `<script>`. That reference renders in a
fixed **900×900** viewBox; `BoardGeometry(rect:)` generalizes it to any rect.

## Coordinate model

The reference's 900×900 viewBox is the **design space**. `init(rect:)`:

1. Fits a centered square of side `min(rect.width, rect.height)` inside the
   input rect (`boardRect`); the leftover margin is split evenly so a
   non-square rect centers the board on its long axis.
2. Sets `scale = boardRect.width / 900`.
3. Computes every quantity in design space, then maps to screen via
   `screen = boardRect.origin + designPoint * scale`.

Consequence: at `rect = (0, 0, 900, 900)` every output equals the reference math
exactly (scale 1, origin 0) — which is what the tests pin.

## Design constants (900-unit space)

```
designSide = 900
frame      = 40
bar        = 90
inner      = 820            // designSide - 2*frame
halfW      = 365            // (inner - bar)/2
pointW     = 60.833…        // halfW/6
pointH     = 328            // inner * 0.40
checkerR   = pointW * 0.42
barCenterX = 450            // frame + halfW + bar/2
leftDiamondCX  = 222.5      // frame + halfW/2
rightDiamondCX = 677.5      // frame + halfW + bar + halfW/2
diamond size   = 78 × 138, centered at y = 450
```

Exposed (scaled) on the struct: `boardRect`, `scale`, `frameInset`,
`pointWidth`, `pointHeight`, `checkerRadius`, `barTop`/`barBottom` (bar line
endpoints), `leftDiamondCenter`/`rightDiamondCenter`, `diamondSize`.

## Point layout — `point(_ index: Int) -> PointGeometry`

Slots are 0…25. 1–24 are playable triangles; 0 and 25 are bear-off trays.

`rawPoint(n)` (design space) reproduces `pointGeom`, returning `(cx, baseY, top)`:

| Points | Quadrant | `i`      | `cx`                                  | `baseY`        | `top` |
|--------|----------|----------|---------------------------------------|----------------|-------|
| 1–6    | BR       | `n-1`    | `frame + inner - pointW*(i+0.5)`      | `designSide-frame` | false |
| 7–12   | BL       | `n-7`    | `frame + halfW - pointW*(i+0.5)`      | `designSide-frame` | false |
| 13–18  | TL       | `n-13`   | `frame + pointW*(i+0.5)`              | `frame`        | true  |
| 19–24  | TR       | `n-19`   | `frame + halfW + bar + pointW*(i+0.5)`| `frame`        | true  |

- **Quadrant mapping** is exactly what issue #5 calls out: 1–6 bottom-right,
  7–12 bottom-left, 13–18 top-left, 19–24 top-right.
- **Row:** points 1–12 sit on the bottom frame (`isTop == false`, triangles
  point up); 13–24 on the top frame (`isTop == true`, triangles point down).
- **Within a row:** BR and BL run right→left as the index increases (point 1 is
  the rightmost point on the board); TL and TR run left→right.

`PointGeometry` fields:
- `center` — baseline midpoint `(cx, baseY)`.
- `tip` — apex at `baseY ± pointH` (`+` for top points, `−` for bottom).
- `baselineLeft`/`baselineRight` — baseline endpoints at `cx ± (pointW/2 - 1.5)`
  (the `-1.5` is the reference's stroke inset).
- `hitRect` — the tappable **lane**: `pointW` wide, `pointH` deep, anchored at
  the baseline and extending toward the tip.
- `quadrant` — `nil` for bear-off slots.

## Bear-off trays (slots 0 and 25)

The Caramel reference never draws bear-off, so this is a project convention,
placed by bearing direction (refined now that #31 renders borne-off checkers):

- The right frame strip, `x ∈ [frame+inner, designSide]` (i.e. `[860, 900]`),
  width = `frame`.
- **Slot 25** (White; home 19–24/TR) occupies the **top half**, `y ∈ [40, 450]`.
- **Slot 0** (Black; home 1–6/BR) occupies the **bottom half**, `y ∈ [450, 860]`.
- `center` is the tray's midpoint, `tip == center`, `quadrant == nil`,
  `isTop == (index == 25)`.

## Checker stacking — `checkerCenter(point:slot:)`

Mirrors `Stack()` in the reference. `slot 0` is the base checker (closest to the
baseline); each subsequent checker steps inward by `2*checkerR + 0.5`:

```
cy = top ? baseY + r + 1 + slot*(2r+0.5)
         : baseY - r - 1 - slot*(2r+0.5)
```

Bear-off trays stack down from the top (slot 25) / up from the bottom (slot 0).
A full-size checker is wider than the 40u strip, so the stack center is pulled
in from the strip center (`880`) only as far as needed to keep the disc within
the board square: `stripX = min(880, designSide - r - 1)` (≈ 873.5). The checker
floats over the strip and the play-surface edge rather than being clipped at the
board edge.

## Hit-testing — `hitTest(_ location:candidates:)`

Iterates `candidates` (slot indices the caller deems selectable) and returns the
first whose `hitRect` contains `location`, else `nil`. Taps in the bar gap, on
diamonds, or on non-candidate slots fall through to `nil`. Candidate order is
respected, so callers control precedence when regions could overlap.

## Tests

`Tests/BoardGeometryTests/BoardGeometryTests.swift` (run via `swift test`,
headless on macOS — no simulator). Covers quadrant mapping, row mapping, exact
baseline centers + within-row ordering, tip direction & baseline width, bear-off
slot placement, scaling/centered-square fit, and hit-testing (playable point,
bar-gap miss, bear-off).
