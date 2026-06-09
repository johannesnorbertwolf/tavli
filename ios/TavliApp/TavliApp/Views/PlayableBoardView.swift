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
/// `BoardDiceView` is layered above as a *sibling* of the gesture-bearing stack
/// (not inside it), so its tap-to-roll and the board's tap/drag never contend:
/// the dice claim taps only while awaiting a roll, and pass through otherwise.
///
/// All layers build an identical `BoardGeometry` from the same square, centered
/// fit, so they register exactly; the gesture geometry is computed from the same
/// `GeometryReader` size. No game logic lives here — the view only reads
/// `session`'s published state and calls its intents.

/// State tracked by `@GestureState` during an active drag: which point the checker
/// came from and the current finger position in board-local coordinates.
private struct LiveDrag {
    var sourcePoint: Int
    var location: CGPoint
}

/// Snap-back animation state after a failed drop: the checker animates from its
/// drop position back to its origin on the board.
private struct SnapBack {
    var position: CGPoint        // current (animated) position
    let origin: CGPoint          // destination of the spring animation
    let color: TavliEngine.Color
}

struct PlayableBoardView: View {
    @ObservedObject var session: GameSession

    /// Target marking style. A constant per the design's two-readings spec.
    var highlightStyle: HighlightStyle = .frame

    /// When true the board renders from Black's perspective (180° flip).
    /// Logical point indices are unchanged; only the visual layout rotates.
    var flipped: Bool = false

    /// Translation (points) past which a press is treated as a drag, not a tap.
    private let dragThreshold: CGFloat = 10

    /// Live drag state — set by `.updating` during an active drag, auto-reset
    /// to `nil` when the gesture ends. Never mutates session (safe in `onChanged`).
    @GestureState private var liveDrag: LiveDrag? = nil

    /// Snap-back checker shown after a failed drop while it animates to origin.
    @State private var snapBack: SnapBack? = nil
    /// Task that clears `snapBack` after the animation completes. Cancelled and
    /// replaced on each new failed drop so overlapping drags don't clobber.
    @State private var snapBackTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { proxy in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: proxy.size),
                                    flipped: flipped)

            // During drag: show one fewer checker at the source (it's in the air).
            let boardStacks = session.game.board.points.map(\.pieces)
            let displayStacks: [[TavliEngine.Color]] = {
                guard let drag = liveDrag, drag.sourcePoint >= 1, drag.sourcePoint <= 24,
                      !boardStacks[drag.sourcePoint].isEmpty else { return boardStacks }
                var s = boardStacks
                s[drag.sourcePoint] = Array(s[drag.sourcePoint].dropLast())
                return s
            }()

            // Highlight targets: drag targets (read-only, no session mutation) while
            // dragging; fall back to the session's selection-driven targets otherwise.
            let highlightTargets: Set<Int> = {
                guard let drag = liveDrag,
                      session.selectableSources.contains(drag.sourcePoint) else {
                    return session.validTargets
                }
                return session.moveBuilder.validDestinations(for: drag.sourcePoint)
            }()

            // Source ring: drag source while dragging, session selection otherwise.
            let ringPoint: Int? = liveDrag?.sourcePoint ?? session.selectedPoint

            ZStack {
                ZStack {
                    BoardView(flipped: flipped)
                    TargetHighlightView(targets: highlightTargets, style: highlightStyle,
                                        flipped: flipped)
                    CheckersView(stacks: displayStacks, flipped: flipped)
                    SourceRingView(selectedPoint: ringPoint, stacks: displayStacks,
                                   flipped: flipped)
                }
                .contentShape(Rectangle())
                .gesture(boardGesture(geo: geo))

                BoardDiceView(session: session)

                // Floating checker follows the finger above all board layers.
                if let drag = liveDrag, let topColor = boardStacks[drag.sourcePoint].last {
                    DraggedCheckerView(geo: geo, location: drag.location, color: topColor)
                }

                // Snap-back ghost animates to the checker's origin after a failed drop.
                if let sb = snapBack {
                    DraggedCheckerView(geo: geo, location: sb.position, color: sb.color)
                }
            }
            .accessibilityElement()
            .accessibilityIdentifier("board")
            .accessibilityValue(boardSignature)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Compact per-point checker counts, exposed for UI tests to assert board
    /// mutations without pixel inspection (the board is Canvas-drawn).
    private var boardSignature: String {
        (0...25).map { String(session.game.board.points[$0].count) }.joined(separator: ",")
    }

    // ── Gesture ─────────────────────────────────────────────────────────────

    /// One `DragGesture(minimumDistance: 0)` serves both interactions.
    ///
    /// **During drag** (`.updating`): the `@GestureState liveDrag` is updated with the
    /// source point and current finger location. This only reads from session (no mutation,
    /// no publish), so the gesture is never cancelled mid-flight. The floating checker and
    /// target highlights update reactively from `liveDrag`.
    ///
    /// **On release** (`onEnded`): a drag that started on a selectable source selects it
    /// and commits if the drop landed on a valid target. A failed drop shows a spring
    /// snap-back animation. Everything else routes through `handleTap`.
    ///
    /// Mutating session state from `onChanged` republishes and rebuilds the enclosing
    /// `GeometryReader`, cancelling the gesture on real devices — so all session intent
    /// dispatch stays in `onEnded`.
    private func boardGesture(geo: BoardGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($liveDrag) { value, state, _ in
                let moved = hypot(value.translation.width, value.translation.height) > dragThreshold
                guard moved,
                      let src = geo.hitTest(value.startLocation,
                                            candidates: Array(session.selectableSources))
                else { return }
                state = LiveDrag(sourcePoint: src, location: value.location)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > dragThreshold
                if moved,
                   let src = geo.hitTest(value.startLocation,
                                         candidates: Array(session.selectableSources)) {
                    session.selectPoint(src)
                    if let dest = geo.hitTest(value.location,
                                              candidates: Array(session.validTargets)) {
                        session.commitHalfMove(from: src, to: dest)
                    } else {
                        // Failed drop: spring the checker back to its stack position.
                        let pieces = session.game.board.points[src].pieces
                        let topSlot = max(0, min(pieces.count, 5) - 1)
                        let origin = geo.checkerCenter(point: src, slot: topSlot)
                        snapBack = SnapBack(position: value.location,
                                           origin: origin,
                                           color: pieces.last ?? .white)
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                            snapBack?.position = origin
                        }
                        snapBackTask?.cancel()
                        snapBackTask = Task { @MainActor in
                            do {
                                try await Task.sleep(nanoseconds: 450_000_000)
                                snapBack = nil
                            } catch {}
                        }
                        // Clear the selection that selectPoint(src) just set.
                        session.selectPoint(-1)
                    }
                } else {
                    handleTap(value.location, geo: geo)
                }
            }
    }

    /// Tap: commit when a target is tapped with a source already selected;
    /// otherwise (re)select the tapped point. Tapping empty space or a
    /// non-selectable point clears the selection (`selectPoint` ignores it).
    private func handleTap(_ location: CGPoint, geo: BoardGeometry) {
        let tapped = geo.hitTest(location, candidates: Array(0...25)) ?? -1
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
    var flipped: Bool = false

    var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
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
    /// Per-slot stacks (value type) so the ring tracks the selected stack reliably;
    /// see `CheckersView` for why `[Point]` references can't drive a Canvas redraw.
    let stacks: [[TavliEngine.Color]]
    var flipped: Bool = false

    var body: some View {
        Canvas { context, size in
            guard let sel = selectedPoint, sel >= 1, sel <= 24 else { return }
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
            let r = geo.checkerRadius
            let s = geo.scale
            let visible = min(stacks[sel].count, 5)
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
