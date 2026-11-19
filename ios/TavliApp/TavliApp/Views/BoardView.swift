import SwiftUI
import UIKit
import BoardGeometry

/// Static rendering of the empty Caramel board (T3): beechwood frame,
/// mahogany play surface, 24 ivory triangles with tip pips, the slim center bar
/// line, and two diamond ornaments. No checkers, dice, highlights, or interactivity.
///
/// Drawn with a single SwiftUI `Canvas` on top of `BoardGeometry`, which fits a
/// centered square inside the available rect — so the board stays square at any
/// iPad size. All design constants come from the 900-unit reference in
/// `docs/design/tavli/project/Tavli Board.html` and are scaled by `geo.scale`.
public struct BoardView: View {
    var flipped: Bool = false

    public init(flipped: Bool = false) { self.flipped = flipped }

    public var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
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

        // ── Bear-off trays ──────────────────────────────────────────────────
        // Subtle always-present recesses on the right frame strip (White 25 top,
        // Black 0 bottom) so borne-off checkers and the T7 gold target box have a
        // tray to sit in. The Caramel reference has no bear-off art — this is the
        // project's tray chrome.
        for slot in [0, 25] {
            let tray = geo.point(slot).hitRect.insetBy(dx: 4 * s, dy: 8 * s)
            let box = Path(roundedRect: tray, cornerRadius: 8 * s)
            context.fill(box, with: .color(p.trayRecess))
            context.stroke(box, with: .color(p.trayEdge.opacity(0.45)), lineWidth: 1 * s)
        }

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
///
/// #191 dark mode: tokens declared `Color(light:dark:)` resolve per colour scheme — the
/// light value is the original hex (light mode is unchanged), the dark value is the
/// "C3 · Espresso + warm text" walnut board from `design/dark-mode/themes.js`: a dark
/// walnut frame with a caramel edge, a near-black play surface, cream-gold points,
/// slightly brighter checkers, a brighter review blue/green. Tokens with a single
/// `Color(hex:)` are the same in both schemes (amber highlights, ring/text colours).
enum CaramelPalette {
    static let frameTop = Color(light: 0xe8c089, dark: 0x6e4526)
    static let frameMid = Color(light: 0xd4a466, dark: 0x553219)
    static let frameBot = Color(light: 0xa87a3e, dark: 0x341c0c)
    static let frameHi = Color(light: 0xf4d6a3, dark: 0xc8904e)
    static let frameText = Color(light: 0x3a2510, dark: 0xf4d7a4)
    static let playTop = Color(light: 0x8a4a22, dark: 0x1f110a)
    static let playBot = Color(light: 0x6a361a, dark: 0x140a05)
    static let triangleFill = Color(light: 0xfbeed1, dark: 0xead09a)
    static let triangleStroke = Color(light: 0x2a1408, dark: 0x0a0503)
    static let tipPip = Color(light: 0xfff5d8, dark: 0xfff0c8)
    static let barLine = Color(light: 0x2a1408, dark: 0xa8743e)
    static let diamondBorder = Color(light: 0x2a1408, dark: 0x0a0503)
    static let diamondFill = Color(light: 0xfbeed1, dark: 0xead09a)
    static let diamondTileDark = Color(light: 0x8a4a22, dark: 0x6e4526)
    static let diamondTileLight = Color(light: 0xf0dab0, dark: 0xd9b77c)
    static let diamondTileEdge = Color(light: 0x2a1408, dark: 0x0a0503)
    static let diamondDot = Color(light: 0x1a0a04, dark: 0x0a0503)

    // Bear-off tray chrome (#31) — a recessed dark tint on the frame strip;
    // applied at low opacity so it reads as a subtle tray, not a solid block.
    static let trayFill = Color(hex: 0x2a1408)
    /// The tray recess as drawn: `trayFill` at 22 % in light; walnut (#191) uses black at 45 %.
    static let trayRecess = Color(light: 0x2a1408, lightOpacity: 0.22, dark: 0x000000, darkOpacity: 0.45)
    static let trayEdge = Color(light: 0x1a0a04, dark: 0x000000)

    // Checkers (T4) — ported from the CARAMEL table. Engine `.black` → red.
    static let whiteFill = Color(light: 0xf1e6c8, dark: 0xf4e9cd)
    static let whiteHi = Color(light: 0xfbf3d8, dark: 0xfffaea)
    static let whiteRing = Color(hex: 0xa8915f)
    static let whiteEdge = Color(light: 0x5a4828, dark: 0x3a2d18)
    static let whiteText = Color(hex: 0x2a1408)
    static let redFill = Color(light: 0xc0392b, dark: 0xd7412f)
    static let redHi = Color(light: 0xdc5040, dark: 0xf0604c)
    static let redRing = Color(light: 0x5e160b, dark: 0x6a1a0d)
    static let redEdge = Color(light: 0x2a0a04, dark: 0x1a0603)
    static let redText = Color(hex: 0xfff3d6)

    // Move highlight (T7) — ported from the `hl*` keys in the design reference.
    static let hl = Color(hex: 0xf4b400)      // saturated amber: source ring + target frame
    static let hlEdge = Color(hex: 0x7a5400)
    static let hlFill = Color(hex: 0xf6c623)  // slightly lighter for the fill-mode target

    // Review/drill move-comparison colors (#133): your move = amber (`hl`), the AI's
    // best move = blue, and an element played *and* best = green. Chosen to read on
    // both the ivory triangles and the mahogany frame.
    static let hlBest = Color(light: 0x2f7fd1, dark: 0x4a9bf0)   // blue: the best move
    static let hlBoth = Color(light: 0x3fa64a, dark: 0x4cc25a)   // green: you played the best here

    // Route choice (#169): the candidate intermediate points of an ambiguous Portes
    // two-dice move. Live play never shows the review colours, so it reuses the review
    // blue — already chosen to read on both the ivory triangles and the mahogany frame —
    // which stands apart from the amber destination frame.
    static let hlRoute = hlBest

    // Tier-2 handicap board cues (#148): a side's points that don't count as home under a
    // smaller home are dimmed, and its counting home gets a line on the frame.
    static let homeCueShade = Color(light: 0x2a1408, lightOpacity: 0.30, dark: 0x000000, darkOpacity: 0.42)
}

extension Color {
    /// A colour that adapts to the light/dark colour scheme (#191). Resolved by the
    /// environment, so it works in views and in `Canvas` drawing alike. The light side is
    /// exactly `Color(hex: light).opacity(lightOpacity)`.
    init(light: UInt32, lightOpacity: Double = 1, dark: UInt32, darkOpacity: Double = 1) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark, alpha: darkOpacity)
                : UIColor(hex: light, alpha: lightOpacity)
        })
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

#Preview {
    BoardView()
        .padding()
        .background(ChromeKit.pageColor)
}
