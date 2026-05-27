import SwiftUI
import BoardGeometry

/// Static rendering of the empty Caramel board (T3): beechwood frame,
/// mahogany play surface, 24 ivory triangles with tip pips, the slim center bar
/// line, two diamond ornaments, and the TAVLI wordmark. No checkers, dice,
/// highlights, or interactivity.
///
/// Drawn with a single SwiftUI `Canvas` on top of `BoardGeometry`, which fits a
/// centered square inside the available rect — so the board stays square at any
/// iPad size. All design constants come from the 900-unit reference in
/// `docs/design/tavli/project/Tavli Board.html` and are scaled by `geo.scale`.
public struct BoardView: View {
    public init() {}

    public var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size))
            draw(in: &context, geo: geo)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func draw(in context: inout GraphicsContext, geo: BoardGeometry) {
        let p = CaramelPalette.self
        let s = geo.scale
        let board = geo.boardRect

        // ── Frame (beechwood) ───────────────────────────────────────────────
        let frame = Path(roundedRect: board, cornerRadius: 10 * s)
        context.fill(
            frame,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: p.frameTop, location: 0),
                    .init(color: p.frameMid, location: 0.55),
                    .init(color: p.frameBot, location: 1),
                ]),
                startPoint: CGPoint(x: board.midX, y: board.minY),
                endPoint: CGPoint(x: board.midX, y: board.maxY)
            )
        )
        let frameHi = Path(
            roundedRect: board.insetBy(dx: 0.5 * s, dy: 0.5 * s),
            cornerRadius: 9.5 * s
        )
        context.stroke(frameHi, with: .color(p.frameHi.opacity(0.5)), lineWidth: 1 * s)

        // ── Play surface (mahogany) ─────────────────────────────────────────
        let inner = board.insetBy(dx: geo.frameInset, dy: geo.frameInset)
        let surface = Path(inner)
        context.fill(
            surface,
            with: .linearGradient(
                Gradient(colors: [p.playTop, p.playBot]),
                startPoint: CGPoint(x: inner.midX, y: inner.minY),
                endPoint: CGPoint(x: inner.midX, y: inner.maxY)
            )
        )
        // Approximate the SVG inset shadow with a soft dark inner edge.
        context.stroke(surface, with: .color(.black.opacity(0.35)), lineWidth: 2 * s)

        // ── Triangles + tip pips ────────────────────────────────────────────
        for n in 1...24 {
            let pt = geo.point(n)
            var tri = Path()
            tri.move(to: pt.baselineLeft)
            tri.addLine(to: pt.baselineRight)
            tri.addLine(to: pt.tip)
            tri.closeSubpath()
            context.fill(tri, with: .color(p.triangleFill))
            context.stroke(
                tri,
                with: .color(p.triangleStroke),
                style: StrokeStyle(lineWidth: 2.6 * s, lineJoin: .round)
            )
        }
        for n in 1...24 {
            let tip = geo.point(n).tip
            let pip = Path(ellipseIn: CGRect(
                x: tip.x - 4.5 * s, y: tip.y - 4.5 * s,
                width: 9 * s, height: 9 * s
            ))
            context.fill(pip, with: .color(p.tipPip))
            context.stroke(pip, with: .color(p.triangleStroke), lineWidth: 0.8 * s)
        }

        // ── Center bar line ─────────────────────────────────────────────────
        var bar = Path()
        bar.move(to: geo.barTop)
        bar.addLine(to: geo.barBottom)
        context.stroke(bar, with: .color(p.barLine.opacity(0.55)), lineWidth: 1.2 * s)

        // ── Diamonds ────────────────────────────────────────────────────────
        drawDiamond(in: &context, center: geo.leftDiamondCenter, size: geo.diamondSize, s: s)
        drawDiamond(in: &context, center: geo.rightDiamondCenter, size: geo.diamondSize, s: s)

        // ── TAVLI wordmark ──────────────────────────────────────────────────
        let mark = Text("TAVLI")
            .font(.custom("Cormorant Garamond", size: 13 * s))
            .italic()
            .tracking(7 * s)
            .foregroundStyle(p.frameText.opacity(0.55))
        context.draw(
            mark,
            at: CGPoint(x: board.midX, y: board.maxY - 14 * s),
            anchor: .center
        )
    }

    /// One diamond ornament: dark backing, a tessellated dark/light tile border
    /// (8 tiles per side), an ivory inner diamond, and a central dot.
    private func drawDiamond(
        in context: inout GraphicsContext,
        center: CGPoint,
        size: CGSize,
        s: CGFloat
    ) {
        let p = CaramelPalette.self
        let w = size.width, h = size.height
        let corners = [
            CGPoint(x: center.x, y: center.y - h / 2),
            CGPoint(x: center.x + w / 2, y: center.y),
            CGPoint(x: center.x, y: center.y + h / 2),
            CGPoint(x: center.x - w / 2, y: center.y),
        ]

        var outer = Path()
        outer.move(to: corners[0])
        for c in corners.dropFirst() { outer.addLine(to: c) }
        outer.closeSubpath()
        context.fill(outer, with: .color(p.diamondBorder))

        let tilesPerSide = 8
        let tileRect = CGRect(x: -3.4 * s, y: -3.4 * s, width: 6.8 * s, height: 6.8 * s)
        for side in 0..<4 {
            let a = corners[side]
            let b = corners[(side + 1) % 4]
            let ang = atan2(b.y - a.y, b.x - a.x)
            for i in 0..<tilesPerSide {
                let t = (CGFloat(i) + 0.5) / CGFloat(tilesPerSide)
                let x = a.x + (b.x - a.x) * t
                let y = a.y + (b.y - a.y) * t
                var tc = context
                tc.translateBy(x: x, y: y)
                tc.rotate(by: .radians(ang) + .degrees(45))
                let path = Path(tileRect)
                let fill = (side + i) % 2 == 0 ? p.diamondTileDark : p.diamondTileLight
                tc.fill(path, with: .color(fill))
                tc.stroke(path, with: .color(p.diamondTileEdge), lineWidth: 0.35 * s)
            }
        }

        let inset = 9 * s
        let iw = w - inset * 2
        let ih = h - inset * 1.6
        var innerDiamond = Path()
        innerDiamond.move(to: CGPoint(x: center.x, y: center.y - ih / 2))
        innerDiamond.addLine(to: CGPoint(x: center.x + iw / 2, y: center.y))
        innerDiamond.addLine(to: CGPoint(x: center.x, y: center.y + ih / 2))
        innerDiamond.addLine(to: CGPoint(x: center.x - iw / 2, y: center.y))
        innerDiamond.closeSubpath()
        context.fill(innerDiamond, with: .color(p.diamondFill))
        context.stroke(innerDiamond, with: .color(p.diamondTileEdge), lineWidth: 0.6 * s)

        let dot = Path(ellipseIn: CGRect(
            x: center.x - 5.5 * s, y: center.y - 5.5 * s,
            width: 11 * s, height: 11 * s
        ))
        context.fill(dot, with: .color(p.diamondDot))
    }
}

/// Caramel palette, ported verbatim from the `CARAMEL` table in the design
/// reference. Only the colors used by the empty board (T3) are included.
enum CaramelPalette {
    static let frameTop = Color(hex: 0xe8c089)
    static let frameMid = Color(hex: 0xd4a466)
    static let frameBot = Color(hex: 0xa87a3e)
    static let frameHi = Color(hex: 0xf4d6a3)
    static let frameText = Color(hex: 0x3a2510)
    static let playTop = Color(hex: 0x8a4a22)
    static let playBot = Color(hex: 0x6a361a)
    static let triangleFill = Color(hex: 0xfbeed1)
    static let triangleStroke = Color(hex: 0x2a1408)
    static let tipPip = Color(hex: 0xfff5d8)
    static let barLine = Color(hex: 0x2a1408)
    static let diamondBorder = Color(hex: 0x2a1408)
    static let diamondFill = Color(hex: 0xfbeed1)
    static let diamondTileDark = Color(hex: 0x8a4a22)
    static let diamondTileLight = Color(hex: 0xf0dab0)
    static let diamondTileEdge = Color(hex: 0x2a1408)
    static let diamondDot = Color(hex: 0x1a0a04)

    // Checkers (T4) — ported from the CARAMEL table. Engine `.black` → red.
    static let whiteFill = Color(hex: 0xf1e6c8)
    static let whiteHi = Color(hex: 0xfbf3d8)
    static let whiteRing = Color(hex: 0xa8915f)
    static let whiteEdge = Color(hex: 0x5a4828)
    static let whiteText = Color(hex: 0x2a1408)
    static let redFill = Color(hex: 0xc0392b)
    static let redHi = Color(hex: 0xdc5040)
    static let redRing = Color(hex: 0x5e160b)
    static let redEdge = Color(hex: 0x2a0a04)
    static let redText = Color(hex: 0xfff3d6)

    // Move highlight (T7) — ported from the `hl*` keys in the design reference.
    static let hl = Color(hex: 0xf4b400)      // saturated amber: source ring + target frame
    static let hlEdge = Color(hex: 0x7a5400)
    static let hlFill = Color(hex: 0xf6c623)  // slightly lighter for the fill-mode target
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

#Preview {
    BoardView()
        .padding()
        .background(Color(hex: 0xece6dc))
}
