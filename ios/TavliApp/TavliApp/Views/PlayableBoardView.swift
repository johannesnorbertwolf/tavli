import SwiftUI
import BoardGeometry
import TavliEngine

/// How a legal target triangle is marked (T7). The design offers two readings;
/// `frame` is the default (preserves the wood/ivory aesthetic), `fill` is the
/// higher-visibility variant. Flip `PlayableBoardView.highlightStyle` to switch.
enum HighlightStyle {
    case frame
    case fill
}

/// The interactive Caramel board (T7): stacks the static board, highlight
/// overlays, and checkers, and translates tap / drag gestures into `GameSession`
/// intents via `BoardGeometry.hitTest`.
///
/// Layer order (bottom → top) so highlights read correctly:
///   1. `BoardView`           — static frame, surface, triangles
///   2. `TargetHighlightView` — gold frame/fill on legal target triangles
///   3. `CheckersView`        — the checker stacks
///   4. `SourceRingView`      — gold ring on every checker of the selected source
///
/// All layers build an identical `BoardGeometry` from the same square, centered
/// fit, so they register exactly; the gesture geometry is computed from the same
/// `GeometryReader` size. No game logic lives here — the view only reads
/// `session`'s published state and calls its intents.
struct PlayableBoardView: View {
    @ObservedObject var session: GameSession

    /// Target marking style. A constant per the design's two-readings spec.
    var highlightStyle: HighlightStyle = .frame

    /// Translation (points) past which a press is treated as a drag, not a tap.
    private let dragThreshold: CGFloat = 10

    @State private var didDrag = false

    var body: some View {
        GeometryReader { proxy in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: proxy.size))
            ZStack {
                BoardView()
                TargetHighlightView(targets: session.validTargets, style: highlightStyle)
                CheckersView(points: session.game.board.points)
                SourceRingView(
                    selectedPoint: session.selectedPoint,
                    points: session.game.board.points
                )
            }
            .contentShape(Rectangle())
            .gesture(boardGesture(geo: geo))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // ── Gesture ─────────────────────────────────────────────────────────────

    /// One `DragGesture(minimumDistance: 0)` serves both interactions: a small
    /// press is a tap (select source → tap target), a larger press is a drag
    /// (lift source → drop on target). Both resolve through `BoardGeometry`.
    private func boardGesture(geo: BoardGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard hypot(value.translation.width, value.translation.height) > dragThreshold,
                      !didDrag else { return }
                didDrag = true
                // Lift: select the source under the start location, if any.
                if let src = geo.hitTest(value.startLocation,
                                         candidates: Array(session.selectableSources)) {
                    session.selectPoint(src)
                }
            }
            .onEnded { value in
                defer { didDrag = false }
                if didDrag {
                    handleDrop(value.location, geo: geo)
                } else {
                    handleTap(value.location, geo: geo)
                }
            }
    }

    /// Drop ends a drag: commit if released over a legal target; otherwise leave
    /// the source selected so the user can still tap a target.
    private func handleDrop(_ location: CGPoint, geo: BoardGeometry) {
        guard let sel = session.selectedPoint,
              let dest = geo.hitTest(location, candidates: Array(session.validTargets))
        else { return }
        session.commitHalfMove(from: sel, to: dest)
    }

    /// Tap: commit when a target is tapped with a source already selected;
    /// otherwise (re)select the tapped point. Tapping empty space or a
    /// non-selectable point clears the selection (`selectPoint` ignores it).
    private func handleTap(_ location: CGPoint, geo: BoardGeometry) {
        let tapped = geo.hitTest(location, candidates: Array(1...25)) ?? -1
        if let sel = session.selectedPoint, session.validTargets.contains(tapped) {
            session.commitHalfMove(from: sel, to: tapped)
        } else {
            session.selectPoint(tapped)
        }
    }
}

/// Gold marking on every legal target (T7). A pure function of the target set +
/// style; overlays `BoardView` below the checkers. Playable points (1…24) are
/// marked on their triangle; bear-off slots (0/25) are marked as a gold tray box
/// on the corresponding half of the right frame strip (top = White/25,
/// bottom = Black/0) — the Caramel design has no bear-off art, so this is the
/// only bear-off visual. Both honor the same `HighlightStyle`.
struct TargetHighlightView: View {
    let targets: Set<Int>
    let style: HighlightStyle

    var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size))
            let s = geo.scale
            for n in targets {
                if n >= 1 && n <= 24 {
                    markTriangle(&context, geo: geo, point: n, s: s)
                } else if n == 0 || n == 25 {
                    markBearOff(&context, geo: geo, slot: n, s: s)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }

    private func markTriangle(_ context: inout GraphicsContext,
                              geo: BoardGeometry, point n: Int, s: CGFloat) {
        let pt = geo.point(n)
        var tri = Path()
        tri.move(to: pt.baselineLeft)
        tri.addLine(to: pt.baselineRight)
        tri.addLine(to: pt.tip)
        tri.closeSubpath()
        switch style {
        case .frame:
            context.stroke(tri, with: .color(CaramelPalette.hl),
                           style: StrokeStyle(lineWidth: 5 * s, lineJoin: .round))
        case .fill:
            context.fill(tri, with: .color(CaramelPalette.hlFill))
            context.stroke(tri, with: .color(CaramelPalette.triangleStroke),
                           style: StrokeStyle(lineWidth: 2.6 * s, lineJoin: .round))
        }
    }

    /// Gold tray box on the bear-off half-strip. The box is the slot's `hitRect`
    /// inset for breathing room, with rounded corners; `.frame` strokes it gold,
    /// `.fill` fills it gold with a dark edge (mirroring the triangle styles).
    private func markBearOff(_ context: inout GraphicsContext,
                             geo: BoardGeometry, slot n: Int, s: CGFloat) {
        let tray = geo.point(n).hitRect.insetBy(dx: 5 * s, dy: 10 * s)
        let box = Path(roundedRect: tray, cornerRadius: 8 * s)
        switch style {
        case .frame:
            context.stroke(box, with: .color(CaramelPalette.hl), lineWidth: 5 * s)
        case .fill:
            context.fill(box, with: .color(CaramelPalette.hlFill))
            context.stroke(box, with: .color(CaramelPalette.hlEdge), lineWidth: 2 * s)
        }
    }
}

/// Gold ring around every visible checker of the selected source point (T7).
/// Drawn above the checkers; the ring sits just outside the disc (radius
/// `checkerRadius + 3.2`), matching the design's `selected` ring.
struct SourceRingView: View {
    let selectedPoint: Int?
    let points: [TavliEngine.Point]

    var body: some View {
        Canvas { context, size in
            guard let sel = selectedPoint, sel >= 1, sel <= 24 else { return }
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size))
            let r = geo.checkerRadius
            let s = geo.scale
            let visible = min(points[sel].count, 5)
            for slot in 0..<visible {
                let c = geo.checkerCenter(point: sel, slot: slot)
                let ringR = r + 3.2 * s
                let ring = Path(ellipseIn: CGRect(
                    x: c.x - ringR, y: c.y - ringR, width: 2 * ringR, height: 2 * ringR
                ))
                context.stroke(ring, with: .color(CaramelPalette.hl), lineWidth: 3.4 * s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }
}

// ── Previews ─────────────────────────────────────────────────────────────────

@MainActor
private func startScenarioSession() -> GameSession {
    // White on point 1, dice 3·5 → reachable targets 4, 6, 9 (matches the
    // design's reference highlight scenario), with point 1 selected.
    let session = GameSession(startingPlayer: .white)
    session.setManualDice(3, 5)
    session.selectPoint(1)
    return session
}

#Preview("Frame highlight (default)") {
    PlayableBoardView(session: startScenarioSession(), highlightStyle: .frame)
        .padding(24)
        .background(Color(hex: 0xece6dc))
}

#Preview("Fill highlight") {
    PlayableBoardView(session: startScenarioSession(), highlightStyle: .fill)
        .padding(24)
        .background(Color(hex: 0xece6dc))
}

// A near-end position with borne-off checkers in both trays — White (25, top)
// tall enough to show the count badge, Black (0, bottom) a short stack — so the
// persistent tray chrome + stacked borne-off checkers read against the board.
@MainActor
private func bearOffScenarioSession() -> GameSession {
    let session = GameSession(startingPlayer: .white)
    session.game.board.setPoint(25, pieces: Array(repeating: .white, count: 8))
    session.game.board.setPoint(0, pieces: Array(repeating: .black, count: 3))
    return session
}

#Preview("Borne-off checkers in trays") {
    PlayableBoardView(session: bearOffScenarioSession())
        .padding(24)
        .background(Color(hex: 0xece6dc))
}

// Bear-off target boxes on the right strip (top = White/25, bottom = Black/0).
// Driven directly (not via a session) to show the design without setting up a
// near-end-of-game board.
#Preview("Bear-off targets (frame)") {
    ZStack {
        BoardView()
        TargetHighlightView(targets: [0, 25], style: .frame)
    }
    .padding(24)
    .background(Color(hex: 0xece6dc))
}

#Preview("Bear-off targets (fill)") {
    ZStack {
        BoardView()
        TargetHighlightView(targets: [0, 25], style: .fill)
    }
    .padding(24)
    .background(Color(hex: 0xece6dc))
}
