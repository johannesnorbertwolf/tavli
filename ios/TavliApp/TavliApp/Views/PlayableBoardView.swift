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

    /// When true (manual-dice mode, #77), the on-board dice don't roll on tap;
    /// the human enters the dice via the chrome's `ManualDiceControl` instead.
    var manualDiceEntry: Bool = false

    /// When false, all board input — tap-to-roll, tap/drag to move — is blocked,
    /// while rendering and incoming-move animation continue. Online play (#134) sets
    /// this to lock the board on the opponent's turn.
    var interactive: Bool = true

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

            // During a drag or an AI flight (#93): show one fewer checker at
            // the source (it's in the air, drawn by the overlay views below).
            let boardStacks = session.game.board.points.map(\.pieces)
            let displayStacks: [[TavliEngine.Color]] = {
                var s = boardStacks
                if let drag = liveDrag, drag.sourcePoint >= 1, drag.sourcePoint <= 24,
                   !s[drag.sourcePoint].isEmpty {
                    s[drag.sourcePoint] = Array(s[drag.sourcePoint].dropLast())
                }
                if let hop = session.aiHopInFlight, !s[hop.from].isEmpty {
                    s[hop.from] = Array(s[hop.from].dropLast())
                }
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

                BoardDiceView(session: session, manualEntry: manualDiceEntry)

                // Floating checker follows the finger above all board layers.
                if let drag = liveDrag, let topColor = boardStacks[drag.sourcePoint].last {
                    DraggedCheckerView(geo: geo, location: drag.location, color: topColor)
                }

                // Snap-back ghost animates to the checker's origin after a failed drop.
                if let sb = snapBack {
                    DraggedCheckerView(geo: geo, location: sb.position, color: sb.color)
                }

                // The AI's checker arcs above all layers while a hop is in
                // flight (#93). `.id` forces a fresh view per hop so the flight
                // restarts even when consecutive hops share endpoints (a Pasch
                // moving two checkers along the same route).
                if let hop = session.aiHopInFlight {
                    AIFlightCheckerView(hop: hop, geo: geo, stacks: boardStacks)
                        .id(hop.id)
                }
            }
            .accessibilityElement()
            .accessibilityIdentifier("board")
            .accessibilityValue(boardSignature)
        }
        .aspectRatio(1, contentMode: .fit)
        // Online (#134): lock the board on the opponent's turn — blocks tap-to-roll
        // and tap/drag while letting the incoming move animate.
        .disabled(!interactive)
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

/// Review/drill move highlighter (#133). Renders a *whole move* with the Caramel
/// highlight language — amber ring on each source point's moved checkers, amber
/// frame on each landing triangle — extended three ways the live `SourceRingView`
/// / `TargetHighlightView` pair did not:
///
///  1. **Every source is highlighted**, not just the first half-move's. A compound
///     move (two half-moves, or up to four under a Pasch double) rings all of them.
///  2. **Pass-through hops are cancelled by count.** Where a checker merely hops
///     over a point it gets no highlight (e.g. a single checker 13→9→5→1 marks only
///     source 13 and target 1). This is counted, not set-based: at a point where `k`
///     checkers arrive and `j` leave, `min(k, j)` are pass-throughs, any surplus
///     arrivals are genuine landings, and any surplus departures genuine sources — so
///     a point that is *both* a landing and a hop-over (one checker stays while
///     another passes through, e.g. a Pasch 1→4, 4→7, 1→4) still reads as a landing.
///  3. **Only the moved checkers are ringed** — the count of half-moves leaving a
///     point (usually one, up to four with doubles), taken from the top of the
///     stack — not every checker sitting there.
///
/// Pass a non-nil `bestMove` to compare: the played move draws amber, the best move
/// blue, and any element belonging to **both** draws green (you played the best
/// there). With `bestMove == nil` only the played move is shown, all amber.
struct MoveHighlightView: View {
    /// The move to show in amber ("your move"). May be empty (e.g. a drill solution
    /// that only wants the blue best move).
    let playedMove: [[Int]]
    /// The best move to compare against, in blue; `nil` hides it (show yours only).
    let bestMove: [[Int]]?
    /// Pre-move per-slot stacks, so rings track the real checker positions.
    let stacks: [[TavliEngine.Color]]
    var flipped: Bool = false

    /// The genuine source points and landing points of a move, after cancelling
    /// hop-overs *by count* (#133). `sources` lists each genuine source point
    /// once per checker lifted there (so the rings can be coloured per *piece*: two
    /// checkers leaving one point can ring different colours); `targets` is the set
    /// of genuine landing points.
    private struct Marks { var sources: [Int]; var targets: Set<Int> }

    private static func marks(of move: [[Int]]) -> Marks {
        let pairs = move.filter { $0.count == 2 }
        // Per point: how many checkers arrive vs leave. The min cancels as a hop-over;
        // any surplus arrival is a real landing, any surplus departure a real source.
        var arrivals: [Int: Int] = [:], departures: [Int: Int] = [:]
        for p in pairs {
            departures[p[0], default: 0] += 1
            arrivals[p[1], default: 0] += 1
        }
        var sources: [Int] = []
        for (pt, dep) in departures {
            let net = dep - (arrivals[pt] ?? 0)
            if net > 0 { sources += Array(repeating: pt, count: net) }
        }
        let targets = Set(arrivals.compactMap { pt, arr in
            arr - (departures[pt] ?? 0) > 0 ? pt : nil
        })
        return Marks(sources: sources, targets: targets)
    }

    /// Amber when only the played move owns an element, blue when only the best move,
    /// green when both. Used for the landing triangles, which stay point-level: if any
    /// move lands there in both played and best it's green — including the case where
    /// you reached the square with the wrong die (#133).
    private static func color(played: Bool, best: Bool) -> SwiftUI.Color {
        if played && best { return CaramelPalette.hlBoth }
        return best ? CaramelPalette.hlBest : CaramelPalette.hl
    }

    var body: some View {
        Canvas { context, size in
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
            let s = geo.scale
            let played = Self.marks(of: playedMove)
            let best = bestMove.map { Self.marks(of: $0) }

            // Targets first (under the source rings, so a shared point's ring reads).
            for t in played.targets.union(best?.targets ?? []) {
                let c = Self.color(played: played.targets.contains(t),
                                   best: best?.targets.contains(t) ?? false)
                drawTarget(&context, geo: geo, point: t, color: c, s: s)
            }
            // Source rings, coloured **per point by count** (#133): of the pieces
            // lifted from a point, the number both moves agree on is green (regardless
            // of where each went — a right point / wrong move still counts), any extra
            // the best move lifts from there are blue, and any extra you lifted that the
            // best wouldn't are amber. So played-1 / best-2 from one point reads as one
            // green + one blue, not two green.
            let playedSources = played.sources
            let bestSources = best?.sources ?? []
            for src in Set(playedSources).union(bestSources) {
                let played = playedSources.filter { $0 == src }.count
                let best = bestSources.filter { $0 == src }.count
                let green = min(played, best)
                let colors = Array(repeating: CaramelPalette.hlBoth, count: green)
                    + Array(repeating: CaramelPalette.hlBest, count: best - green)   // best wants more off here
                    + Array(repeating: CaramelPalette.hl, count: played - green)     // you lifted more than best
                drawSourceRings(&context, geo: geo, point: src, colors: colors, s: s)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
    }

    /// Frame the landing triangle (1…24) or the bear-off tray box (0/25).
    private func drawTarget(_ context: inout GraphicsContext, geo: BoardGeometry,
                            point n: Int, color: SwiftUI.Color, s: CGFloat) {
        if n >= 1 && n <= 24 {
            let pt = geo.point(n)
            var tri = Path()
            tri.move(to: pt.baselineLeft)
            tri.addLine(to: pt.baselineRight)
            tri.addLine(to: pt.tip)
            tri.closeSubpath()
            context.stroke(tri, with: .color(color),
                           style: StrokeStyle(lineWidth: 5 * s, lineJoin: .round))
        } else if n == 0 || n == 25 {
            let tray = geo.point(n).hitRect.insetBy(dx: 5 * s, dy: 10 * s)
            context.stroke(Path(roundedRect: tray, cornerRadius: 8 * s),
                           with: .color(color), lineWidth: 5 * s)
        }
    }

    /// Ring the top checkers of the source point (the ones lifted off), one ring per
    /// entry in `colors`, applied top-down.
    private func drawSourceRings(_ context: inout GraphicsContext, geo: BoardGeometry,
                                 point n: Int, colors: [SwiftUI.Color], s: CGFloat) {
        guard n >= 1 && n <= 24, !colors.isEmpty else { return }
        let r = geo.checkerRadius
        let visible = min(stacks[n].count, 5)
        let count = min(colors.count, visible)
        let ringR = r + 3.2 * s
        for i in 0..<count {
            let slot = visible - 1 - i
            let c = geo.checkerCenter(point: n, slot: slot)
            let ring = Path(ellipseIn: CGRect(x: c.x - ringR, y: c.y - ringR,
                                              width: 2 * ringR, height: 2 * ringR))
            context.stroke(ring, with: .color(colors[i]), lineWidth: 3.4 * s)
        }
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
