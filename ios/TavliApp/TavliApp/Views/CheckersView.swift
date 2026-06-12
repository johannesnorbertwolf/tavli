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
    /// Per-slot stacks, indexed 0…25 (bottom→top). **Value type on purpose:** the
    /// engine `Board` holds `Point` *reference* objects mutated in place, so a
    /// `[Point]` input is reference-identical across moves and SwiftUI skips
    /// repainting the Canvas (the board freezes while the model advances). Passing
    /// a `[[Color]]` snapshot makes the input change by value, so every committed
    /// move reliably repaints.
    let stacks: [[TavliEngine.Color]]
    var flipped: Bool = false

    init(stacks: [[TavliEngine.Color]], flipped: Bool = false) {
        self.stacks = stacks
        self.flipped = flipped
    }

    var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
            draw(in: &context, geo: geo)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func draw(in context: inout GraphicsContext, geo: BoardGeometry) {
        // Slots 0/25 are the bear-off trays: borne-off checkers stack there
        // (White at 25, Black at 0) via the same stacking path as playable points.
        for n in 0...25 {
            let pieces = stacks[n]
            guard !pieces.isEmpty else { continue }
            drawStack(in: &context, geo: geo, point: n, pieces: pieces)
        }
    }

    /// One point's stack: ≤5 visible checkers growing away from the baseline; a
    /// count label when the stack exceeds 5. The label sits on the *owning team's*
    /// checker, centered and bold — not on a pinned opponent checker parked at the
    /// base (slot 0). A pinned point has `pieces[0] != pieces[1]`, so the owner's
    /// first checker is slot 1; otherwise it's slot 0.
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
            let labelSlot = (pieces[0] != pieces[1]) ? 1 : 0
            let center = geo.checkerCenter(point: n, slot: labelSlot)
            let style = CheckerStyle.of(pieces[labelSlot])
            let ownerColor = pieces[labelSlot]
            let ownerCount = pieces.filter { $0 == ownerColor }.count
            let label = Text(String(ownerCount))
                .font(.custom("Cormorant Garamond", size: r * 1.2))
                .fontWeight(.bold)
                .foregroundStyle(style.text)
            context.draw(label, at: center, anchor: .center)
        }
    }

    private func drawChecker(
        in context: inout GraphicsContext,
        center: CGPoint,
        r: CGFloat,
        s: CGFloat,
        color: TavliEngine.Color
    ) {
        drawCheckerDisc(in: &context, center: center, r: r, s: s, color: color, lifted: false)
    }
}

/// One checker disc: radial-gradient fill, concentric detail rings, specular arc,
/// and a drop shadow. `lifted: true` deepens the shadow to simulate being raised off
/// the board (used for the drag ghost).
func drawCheckerDisc(
    in context: inout GraphicsContext,
    center: CGPoint,
    r: CGFloat,
    s: CGFloat,
    color: TavliEngine.Color,
    lifted: Bool
) {
    let style = CheckerStyle.of(color)
    let cx = center.x, cy = center.y
    let disc = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
    let shadowRadius: CGFloat = lifted ? 8 * s : 3 * s
    let shadowY: CGFloat     = lifted ? 5 * s : 2 * s
    let shadowOpacity: CGFloat = lifted ? 0.40 : 0.28

    context.drawLayer { layer in
        layer.addFilter(.shadow(color: .black.opacity(shadowOpacity),
                                radius: shadowRadius, x: 0, y: shadowY))

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

        // Specular arc (quad-curve approximation of the SVG elliptical arc).
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

/// A single checker floating at `location` in board coordinate space, rendered
/// above all board layers during a drag gesture. Uses the lifted shadow variant
/// to visually separate it from the board surface.
struct DraggedCheckerView: View {
    let geo: BoardGeometry
    let location: CGPoint
    let color: TavliEngine.Color

    var body: some View {
        Canvas { context, size in
            let r = geo.checkerRadius
            let s = geo.scale
            drawCheckerDisc(in: &context, center: location, r: r, s: s, color: color, lifted: true)
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }
}

/// The AI's checker arcing from `hop.from` to `hop.to` (#93). Rendered above
/// all board layers while `GameSession` publishes a hop in flight; the source
/// stack shows one fewer checker meanwhile (see `PlayableBoardView`). The
/// flight follows a quadratic Bézier lifted above both endpoints, eased
/// in-out, with a subtle mid-flight scale-up to sell the lift. Landing is the
/// engine's job — it applies the half-move (and clears the hop) when the
/// flight time elapses, so this view never touches game state.
struct AIFlightCheckerView: View {
    let hop: AIAnimatedHop
    let geo: BoardGeometry
    /// Pre-hop stacks (the flying checker is still counted at `hop.from`),
    /// used to derive the lift-off and landing slots.
    let stacks: [[TavliEngine.Color]]

    @State private var progress: CGFloat = 0

    var body: some View {
        // Lift off from the top visible checker of the source stack; land on
        // the next visible slot of the destination (capped at the 5-stack).
        let start = geo.checkerCenter(point: hop.from,
                                      slot: max(0, min(stacks[hop.from].count, 5) - 1))
        let end = geo.checkerCenter(point: hop.to,
                                    slot: min(stacks[hop.to].count, 4))
        // Control point above both endpoints ("up" in screen space, whatever
        // the board orientation): a slight arc for short hops, capped so a
        // cross-board move doesn't balloon.
        let s = geo.scale
        let span = hypot(end.x - start.x, end.y - start.y)
        let lift = min(24 * s + 0.22 * span, 130 * s)
        let control = CGPoint(x: (start.x + end.x) / 2,
                              y: min(start.y, end.y) - lift)

        FlightDisc(geo: geo, color: hop.color)
            .modifier(ArcFlightEffect(progress: progress,
                                      start: start, control: control, end: end))
            .position(x: 0, y: 0)   // anchor at the board origin; the effect translates
            .allowsHitTesting(false)
            .onAppear {
                guard hop.duration > 0 else { progress = 1; return }
                withAnimation(.easeInOut(duration: hop.duration)) { progress = 1 }
            }
    }
}

/// Moves its content's center along the quadratic Bézier `start → control →
/// end` as `progress` animates 0 → 1, scaling up slightly as the arc crests.
/// A `GeometryEffect` so a plain `withAnimation` interpolates `progress` (the
/// ease comes from the animation curve), rendered without view re-layout.
private struct ArcFlightEffect: GeometryEffect {
    var progress: CGFloat
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = progress
        let u = 1 - t
        let x = u * u * start.x + 2 * u * t * control.x + t * t * end.x
        let y = u * u * start.y + 2 * u * t * control.y + t * t * end.y
        let crest = 1 + 0.10 * sin(.pi * t)
        // Translate the content center to the curve point, scaling about it.
        var m = CGAffineTransform(translationX: x, y: y)
        m = m.translatedBy(x: size.width / 2, y: size.height / 2)
        m = m.scaledBy(x: crest, y: crest)
        m = m.translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(m)
    }
}

/// The flying disc itself: the lifted (deep-shadow) checker in a small canvas
/// padded so the shadow isn't clipped at the frame edge.
private struct FlightDisc: View {
    let geo: BoardGeometry
    let color: TavliEngine.Color

    var body: some View {
        let r = geo.checkerRadius
        let s = geo.scale
        let side = 2 * (r + 16 * s)
        Canvas { context, size in
            drawCheckerDisc(in: &context,
                            center: CGPoint(x: size.width / 2, y: size.height / 2),
                            r: r, s: s, color: color, lifted: true)
        }
        .frame(width: side, height: side)
    }
}

/// Maps an engine `Color` to its Caramel checker palette. Engine `.black` → red.
fileprivate struct CheckerStyle {
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
        CheckersView(stacks: board.points.map(\.pieces))
    }
    .padding(24)
    .background(Color(hex: 0xece6dc))
}

#Preview("Pinned + tall stacks") {
    let board = GameBoard()
    // Point 13: a black checker pinned at the base under a tall white (owner)
    // stack — the count label must land on the white checker, not the black one.
    board.setPoint(13, pieces: [.black] + Array(repeating: .white, count: 6))
    // A tall white stack (>5) to exercise the count label.
    board.setPoint(1, pieces: Array(repeating: .white, count: 8))
    // A tall red stack on the opposite row.
    board.setPoint(24, pieces: Array(repeating: .black, count: 6))
    // Borne-off trays: White (25, top half) tall enough for the count badge,
    // Black (0, bottom half) a short stack.
    board.setPoint(25, pieces: Array(repeating: .white, count: 8))
    board.setPoint(0, pieces: Array(repeating: .black, count: 3))
    return ZStack {
        BoardView()
        CheckersView(stacks: board.points.map(\.pieces))
    }
    .padding(24)
    .background(Color(hex: 0xece6dc))
}
