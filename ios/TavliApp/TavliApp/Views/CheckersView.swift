import SwiftUI
import BoardGeometry
import TavliEngine

/// Renders checker stacks on the Caramel board (T4): ivory + red pieces drawn as
/// stacks per board point, including the Plakoto start position and pinned points.
/// A pure function of board state — no highlights, interaction, or animation
/// (later tickets). Designed to overlay `BoardView` in a `ZStack`; both share an
/// identical `BoardGeometry` (same centered-square fit) so checkers line up with
/// the triangles.
///
/// Ports the `Checker`/`Stack` components from the design reference
/// `docs/design/tavli/project/Tavli Board.html`. Stack geometry comes from
/// `BoardGeometry.checkerCenter(point:slot:)`; all design literals scale by
/// `geo.scale`.
struct CheckersView: View {
    /// Engine board, indexed 0…25 (bottom→top stacks). Empty points are skipped.
    let points: [TavliEngine.Point]

    init(points: [TavliEngine.Point]) { self.points = points }

    var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size))
            draw(in: &context, geo: geo)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func draw(in context: inout GraphicsContext, geo: BoardGeometry) {
        // Bear-off trays (0/25) are intentionally not drawn — the Caramel design
        // never renders bear-off; out of scope for T4.
        for n in 1...24 {
            let pieces = points[n].pieces
            guard !pieces.isEmpty else { continue }
            drawStack(in: &context, geo: geo, point: n, pieces: pieces)
        }
    }

    /// One point's stack: ≤5 visible checkers growing away from the baseline; a
    /// count label on the base checker (slot 0) when the stack exceeds 5.
    private func drawStack(
        in context: inout GraphicsContext,
        geo: BoardGeometry,
        point n: Int,
        pieces: [TavliEngine.Color]
    ) {
        let count = pieces.count
        let visible = min(count, 5)
        let r = geo.checkerRadius
        let s = geo.scale
        for slot in 0..<visible {
            let center = geo.checkerCenter(point: n, slot: slot)
            drawChecker(in: &context, center: center, r: r, s: s, color: pieces[slot])
        }
        if count > 5 {
            let base = geo.checkerCenter(point: n, slot: 0)
            let style = CheckerStyle.of(pieces[0])
            let label = Text(String(count))
                .font(.custom("Cormorant Garamond", size: r * 0.95))
                .fontWeight(.semibold)
                .foregroundStyle(style.text)
            context.draw(label, at: CGPoint(x: base.x, y: base.y + r * 0.30), anchor: .center)
        }
    }

    /// One checker, porting the reference `Checker` component: radial-gradient
    /// disc, two concentric detail rings, a soft specular arc, and a drop shadow.
    private func drawChecker(
        in context: inout GraphicsContext,
        center: CGPoint,
        r: CGFloat,
        s: CGFloat,
        color: TavliEngine.Color
    ) {
        let style = CheckerStyle.of(color)
        let cx = center.x, cy = center.y
        let disc = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)

        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 3 * s, x: 0, y: 2 * s))

            // Main disc: radial gradient (SVG cx=0.38, cy=0.32, r=0.78 of the box).
            layer.fill(
                Path(ellipseIn: disc),
                with: .radialGradient(
                    Gradient(colors: [style.hi, style.fill]),
                    center: CGPoint(x: cx - 0.24 * r, y: cy - 0.36 * r),
                    startRadius: 0,
                    endRadius: 1.56 * r
                )
            )
            layer.stroke(Path(ellipseIn: disc), with: .color(style.edge), lineWidth: 0.7 * s)

            // Concentric detail rings.
            let ring1 = CGRect(x: cx - r * 0.66, y: cy - r * 0.66, width: r * 1.32, height: r * 1.32)
            layer.stroke(Path(ellipseIn: ring1), with: .color(style.ring.opacity(0.85)), lineWidth: 1.1 * s)
            let ring2 = CGRect(x: cx - r * 0.52, y: cy - r * 0.52, width: r * 1.04, height: r * 1.04)
            layer.stroke(Path(ellipseIn: ring2), with: .color(style.ring.opacity(0.55)), lineWidth: 0.5 * s)

            // Specular arc (approximates the SVG elliptical arc with a quad curve).
            var arc = Path()
            arc.move(to: CGPoint(x: cx - 0.55 * r, y: cy - 0.35 * r))
            arc.addQuadCurve(
                to: CGPoint(x: cx + 0.55 * r, y: cy - 0.35 * r),
                control: CGPoint(x: cx, y: cy - 0.85 * r)
            )
            layer.stroke(
                arc,
                with: .color(.white.opacity(color == .white ? 0.55 : 0.28)),
                lineWidth: 0.7 * s
            )
        }
    }
}

/// Maps an engine `Color` to its Caramel checker palette. Engine `.black` → red.
private struct CheckerStyle {
    let fill: SwiftUI.Color
    let hi: SwiftUI.Color
    let ring: SwiftUI.Color
    let edge: SwiftUI.Color
    let text: SwiftUI.Color

    static func of(_ color: TavliEngine.Color) -> CheckerStyle {
        let p = CaramelPalette.self
        return color == .white
            ? CheckerStyle(fill: p.whiteFill, hi: p.whiteHi, ring: p.whiteRing, edge: p.whiteEdge, text: p.whiteText)
            : CheckerStyle(fill: p.redFill, hi: p.redHi, ring: p.redRing, edge: p.redEdge, text: p.redText)
    }
}

#Preview("Start position") {
    let board = GameBoard()
    board.initializeBoard()
    return ZStack {
        BoardView()
        CheckersView(points: board.points)
    }
    .padding(24)
    .background(Color(hex: 0xece6dc))
}

#Preview("Pinned + tall stacks") {
    let board = GameBoard()
    // Point 13: black checker pinned at the base under two white (owner) checkers.
    board.setPoint(13, pieces: [.black, .white, .white])
    // A tall white stack (>5) to exercise the count label.
    board.setPoint(1, pieces: Array(repeating: .white, count: 8))
    // A tall red stack on the opposite row.
    board.setPoint(24, pieces: Array(repeating: .black, count: 6))
    return ZStack {
        BoardView()
        CheckersView(points: board.points)
    }
    .padding(24)
    .background(Color(hex: 0xece6dc))
}
