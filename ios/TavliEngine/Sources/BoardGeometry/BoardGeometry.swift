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
///
/// When `flipped == true` the board is rendered from Black's perspective (180°
/// rotation): logical point `n` is drawn at the screen position that would
/// normally show point `flipIndex(n)`. All public API (point, checkerCenter,
/// hitTest) continues to accept and return **logical** indices, so callers need
/// no awareness of the orientation.
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
    private static let diceFace: CGFloat = 56                    // design die size
    private static let diceGap: CGFloat = 12                     // gap between adjacent dice

    // ── Derived screen geometry ────────────────────────────────────────────
    /// When true, logical indices are mapped to their 180°-rotated visual
    /// positions before computing screen coordinates.
    public let flipped: Bool
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
    /// Center of the board square (and of the center bar), where the dice sit.
    public let boardCenter: CGPoint
    /// Side length of one die face, scaled from the design reference.
    public let diceSize: CGFloat

    public init(rect: CGRect, flipped: Bool = false) {
        self.flipped = flipped
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
        boardCenter = screen(barCenterX, Self.designSide / 2)
        diceSize = Self.diceFace * s
    }

    // ── Public API ─────────────────────────────────────────────────────────

    /// Maps a logical slot index to its 180°-rotated visual position.
    /// - Slots 0 ↔ 25 swap (bear-off trays exchange halves of the right strip).
    /// - Points 1–12 shift to 13–24 and vice versa.
    public static func flipIndex(_ n: Int) -> Int {
        switch n {
        case 0:      return 25
        case 25:     return 0
        case 1...12: return n + 12
        default:     return n - 12  // 13...24
        }
    }

    /// Visual quadrant of a logical index, accounting for `flipped`.
    public func quadrant(of index: Int) -> BoardQuadrant? {
        let p = flipped ? Self.flipIndex(index) : index
        switch p {
        case 1...6:   return .bottomRight
        case 7...12:  return .bottomLeft
        case 13...18: return .topLeft
        case 19...24: return .topRight
        default:      return nil
        }
    }

    /// Geometry for a slot 0…25. Slots 0 and 25 are the bear-off trays.
    /// When `flipped`, logical index `n` is drawn at the visual position of
    /// `flipIndex(n)`; `PointGeometry.index` is always the logical `index`.
    public func point(_ index: Int) -> PointGeometry {
        let physical = flipped ? Self.flipIndex(index) : index
        if physical == 0 || physical == 25 {
            let g = bearOff(physical)
            return PointGeometry(index: index, isTop: g.isTop, quadrant: nil,
                                 center: g.center, tip: g.tip,
                                 baselineLeft: g.baselineLeft,
                                 baselineRight: g.baselineRight,
                                 hitRect: g.hitRect)
        }
        let raw = Self.rawPoint(physical)
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
    /// When `flipped`, uses the visual position of `flipIndex(index)`.
    public func checkerCenter(point index: Int, slot: Int) -> CGPoint {
        let physical = flipped ? Self.flipIndex(index) : index
        let r = Self.checkerR
        let step = 2 * r + 0.5
        if physical == 0 || physical == 25 {
            // A full-size checker is wider than the 40u strip; centering on the
            // strip (880) would clip it at the board edge. Pull the stack center
            // in only as far as needed so the full disc floats within the board.
            let stripCenter = Self.frame + Self.inner + Self.frame / 2  // 880
            let stripX = min(stripCenter, Self.designSide - r - 1)      // ≈ 873.5
            let top = physical == 25
            let cy = top
                ? Self.frame + r + 1 + CGFloat(slot) * step
                : (Self.designSide - Self.frame) - r - 1 - CGFloat(slot) * step
            return toScreen(stripX, cy)
        }
        let raw = Self.rawPoint(physical)
        let cy = raw.top
            ? raw.baseY + r + 1 + CGFloat(slot) * step
            : raw.baseY - r - 1 - CGFloat(slot) * step
        return toScreen(raw.cx, cy)
    }

    /// Centers for the dice rendered on the center bar, laid out **horizontally**
    /// in a single row centered on `boardCenter` (`diceFace + diceGap` apart): two
    /// dice for a normal roll, four side-by-side for a pasch. Returned in render
    /// order, so `diceCenters(count:)[i]` pairs with the i-th displayed die.
    public func diceCenters(count: Int) -> [CGPoint] {
        let step = (Self.diceFace + Self.diceGap) * scale
        let c = boardCenter
        let n = count >= 4 ? 4 : 2
        // Center the row: offsets are symmetric about 0 (e.g. ±0.5·step for two,
        // ±0.5·step and ±1.5·step for four).
        let mid = CGFloat(n - 1) / 2
        return (0..<n).map { CGPoint(x: c.x + (CGFloat($0) - mid) * step, y: c.y) }
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
