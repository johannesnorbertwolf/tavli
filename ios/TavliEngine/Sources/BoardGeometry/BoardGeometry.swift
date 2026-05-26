import CoreGraphics

/// The four triangle quadrants of the Caramel board, matching the design's
/// `pointGeom`: points 1–6 bottom-right, 7–12 bottom-left, 13–18 top-left,
/// 19–24 top-right.
public enum BoardQuadrant {
    case bottomRight
    case bottomLeft
    case topLeft
    case topRight
}

/// Screen geometry for a single board slot (0…25). All points are in the same
/// coordinate space as the `CGRect` passed to `BoardGeometry`.
public struct PointGeometry {
    public let index: Int
    /// Baseline sits on the top frame (triangle points downward) when true.
    public let isTop: Bool
    /// `nil` for the bear-off slots (0, 25).
    public let quadrant: BoardQuadrant?
    /// Baseline midpoint for playable points; slot center for bear-off.
    public let center: CGPoint
    /// Triangle apex; equals `center` for bear-off slots.
    public let tip: CGPoint
    public let baselineLeft: CGPoint
    public let baselineRight: CGPoint
    /// Tappable region: the point's lane (one point wide, point-height deep from
    /// the baseline) for playable points; the tray rectangle for bear-off.
    public let hitRect: CGRect
}

/// Pure index↔screen math for the square Caramel board — no drawing, gestures,
/// or SwiftUI.
///
/// Ported from the design reference `pointGeom` and module constants in
/// `docs/design/tavli/project/Tavli Board.html`, which renders in a fixed
/// 900×900 viewBox. `BoardGeometry(rect:)` fits a centered square inside an
/// arbitrary rect and scales every constant by `side / 900`, so values match
/// the reference exactly when `rect == (0, 0, 900, 900)`.
public struct BoardGeometry {
    // ── Design space (900-unit reference) ──────────────────────────────────
    private static let designSide: CGFloat = 900
    private static let frame: CGFloat = 40
    private static let bar: CGFloat = 90
    private static let inner: CGFloat = designSide - frame * 2   // 820
    private static let halfW: CGFloat = (inner - bar) / 2        // 365
    private static let pointW: CGFloat = halfW / 6               // 60.833…
    private static let pointH: CGFloat = inner * 0.40            // 328
    private static let checkerR: CGFloat = pointW * 0.42

    // ── Derived screen geometry ────────────────────────────────────────────
    /// The fitted, centered square actually used inside the input rect.
    public let boardRect: CGRect
    public let scale: CGFloat
    public let frameInset: CGFloat
    public let pointWidth: CGFloat
    public let pointHeight: CGFloat
    public let checkerRadius: CGFloat
    public let barTop: CGPoint
    public let barBottom: CGPoint
    public let leftDiamondCenter: CGPoint
    public let rightDiamondCenter: CGPoint
    public let diamondSize: CGSize

    public init(rect: CGRect) {
        let side = min(rect.width, rect.height)
        let originX = rect.minX + (rect.width - side) / 2
        let originY = rect.minY + (rect.height - side) / 2
        let s = side / Self.designSide

        boardRect = CGRect(x: originX, y: originY, width: side, height: side)
        scale = s
        frameInset = Self.frame * s
        pointWidth = Self.pointW * s
        pointHeight = Self.pointH * s
        checkerRadius = Self.checkerR * s

        func screen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * s, y: originY + y * s)
        }
        let barCenterX = Self.frame + Self.halfW + Self.bar / 2  // 450
        barTop = screen(barCenterX, Self.frame)
        barBottom = screen(barCenterX, Self.designSide - Self.frame)
        leftDiamondCenter = screen(Self.frame + Self.halfW / 2, Self.designSide / 2)
        rightDiamondCenter = screen(Self.frame + Self.halfW + Self.bar + Self.halfW / 2,
                                    Self.designSide / 2)
        diamondSize = CGSize(width: 78 * s, height: 138 * s)
    }

    // ── Public API ─────────────────────────────────────────────────────────

    public func quadrant(of index: Int) -> BoardQuadrant? {
        switch index {
        case 1...6:   return .bottomRight
        case 7...12:  return .bottomLeft
        case 13...18: return .topLeft
        case 19...24: return .topRight
        default:      return nil
        }
    }

    /// Geometry for a slot 0…25. Slots 0 and 25 are the bear-off trays.
    public func point(_ index: Int) -> PointGeometry {
        if index == 0 || index == 25 {
            return bearOff(index)
        }
        let raw = Self.rawPoint(index)
        let tipYDesign = raw.top ? raw.baseY + Self.pointH : raw.baseY - Self.pointH
        let half = Self.pointW / 2 - 1.5
        let laneY = raw.top ? raw.baseY : raw.baseY - Self.pointH
        let laneDesign = CGRect(x: raw.cx - Self.pointW / 2, y: laneY,
                                width: Self.pointW, height: Self.pointH)
        return PointGeometry(
            index: index,
            isTop: raw.top,
            quadrant: quadrant(of: index),
            center: toScreen(raw.cx, raw.baseY),
            tip: toScreen(raw.cx, tipYDesign),
            baselineLeft: toScreen(raw.cx - half, raw.baseY),
            baselineRight: toScreen(raw.cx + half, raw.baseY),
            hitRect: toScreen(laneDesign)
        )
    }

    /// Center of the checker at `slot` in a point's stack (slot 0 = base,
    /// closest to the baseline). Mirrors `Stack()` in the design reference.
    public func checkerCenter(point index: Int, slot: Int) -> CGPoint {
        let r = Self.checkerR
        let step = 2 * r + 0.5
        if index == 0 || index == 25 {
            let stripX = Self.frame + Self.inner + Self.frame / 2  // 880
            let top = index == 25
            let cy = top
                ? Self.frame + r + 1 + CGFloat(slot) * step
                : (Self.designSide - Self.frame) - r - 1 - CGFloat(slot) * step
            return toScreen(stripX, cy)
        }
        let raw = Self.rawPoint(index)
        let cy = raw.top
            ? raw.baseY + r + 1 + CGFloat(slot) * step
            : raw.baseY - r - 1 - CGFloat(slot) * step
        return toScreen(raw.cx, cy)
    }

    /// Returns the first candidate slot whose `hitRect` contains `location`, or
    /// `nil` (e.g. a tap in the bar gap or on a non-candidate slot).
    public func hitTest(_ location: CGPoint, candidates: [Int]) -> Int? {
        for index in candidates where point(index).hitRect.contains(location) {
            return index
        }
        return nil
    }

    // ── Internals ──────────────────────────────────────────────────────────

    private func toScreen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: boardRect.minX + x * scale, y: boardRect.minY + y * scale)
    }

    private func toScreen(_ rect: CGRect) -> CGRect {
        CGRect(x: boardRect.minX + rect.minX * scale,
               y: boardRect.minY + rect.minY * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }

    /// Design-space baseline center and orientation for a playable point 1…24.
    private static func rawPoint(_ n: Int) -> (cx: CGFloat, baseY: CGFloat, top: Bool) {
        switch n {
        case 1...6:
            let i = CGFloat(n - 1)
            return (frame + inner - pointW * (i + 0.5), designSide - frame, false)
        case 7...12:
            let i = CGFloat(n - 7)
            return (frame + halfW - pointW * (i + 0.5), designSide - frame, false)
        case 13...18:
            let i = CGFloat(n - 13)
            return (frame + pointW * (i + 0.5), frame, true)
        default: // 19...24
            let i = CGFloat(n - 19)
            return (frame + halfW + bar + pointW * (i + 0.5), frame, true)
        }
    }

    /// Bear-off tray geometry: the right frame strip, White (25) in the top
    /// half, Black (0) in the bottom half — matching each color's bearing
    /// direction.
    private func bearOff(_ index: Int) -> PointGeometry {
        let top = index == 25
        let stripX = Self.frame + Self.inner          // 860
        let stripW = Self.frame                       // 40
        let yMin = top ? Self.frame : Self.designSide / 2
        let yMax = top ? Self.designSide / 2 : Self.designSide - Self.frame
        let trayDesign = CGRect(x: stripX, y: yMin, width: stripW, height: yMax - yMin)
        let center = toScreen(trayDesign.midX, trayDesign.midY)
        return PointGeometry(
            index: index,
            isTop: top,
            quadrant: nil,
            center: center,
            tip: center,
            baselineLeft: center,
            baselineRight: center,
            hitRect: toScreen(trayDesign)
        )
    }
}
