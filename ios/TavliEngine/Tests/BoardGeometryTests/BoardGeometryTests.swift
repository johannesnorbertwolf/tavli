import CoreGraphics
import XCTest
@testable import BoardGeometry

final class BoardGeometryTests: XCTestCase {
    /// Reference geometry: scale 1, origin 0 — values match the design `pointGeom`.
    private let geom = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 900, height: 900))
    private let eps: CGFloat = 1e-6

    // 1 ── Quadrant mapping ────────────────────────────────────────────────
    func testQuadrantMapping() {
        for n in 1...6 { XCTAssertEqual(geom.point(n).quadrant, .bottomRight, "point \(n)") }
        for n in 7...12 { XCTAssertEqual(geom.point(n).quadrant, .bottomLeft, "point \(n)") }
        for n in 13...18 { XCTAssertEqual(geom.point(n).quadrant, .topLeft, "point \(n)") }
        for n in 19...24 { XCTAssertEqual(geom.point(n).quadrant, .topRight, "point \(n)") }
        XCTAssertNil(geom.point(0).quadrant)
        XCTAssertNil(geom.point(25).quadrant)
    }

    // 2 ── Row mapping ─────────────────────────────────────────────────────
    func testRowMapping() {
        for n in 1...12 { XCTAssertFalse(geom.point(n).isTop, "point \(n) should be bottom") }
        for n in 13...24 { XCTAssertTrue(geom.point(n).isTop, "point \(n) should be top") }
    }

    // 3 ── Position within row (exact + ordering) ──────────────────────────
    func testExactBaselineCenters() {
        let pointW: CGFloat = 365.0 / 6.0
        // Bottom-right, point 1 is rightmost; baseline on bottom frame.
        XCTAssertEqual(geom.point(1).center.x, 40 + 820 - pointW * 0.5, accuracy: eps)
        XCTAssertEqual(geom.point(1).center.y, 860, accuracy: eps)
        // Top-left, point 13 is leftmost; baseline on top frame.
        XCTAssertEqual(geom.point(13).center.x, 40 + pointW * 0.5, accuracy: eps)
        XCTAssertEqual(geom.point(13).center.y, 40, accuracy: eps)
        // Top-right, point 19 starts just past the bar.
        XCTAssertEqual(geom.point(19).center.x, 40 + 365 + 90 + pointW * 0.5, accuracy: eps)
        XCTAssertEqual(geom.point(19).center.y, 40, accuracy: eps)
    }

    func testWithinRowOrdering() {
        // BR and BL run right→left as the index increases.
        for (lo, hi) in [(1, 6), (7, 12)] {
            for n in lo..<hi {
                XCTAssertGreaterThan(geom.point(n).center.x, geom.point(n + 1).center.x,
                                     "point \(n) should be right of \(n + 1)")
            }
        }
        // TL and TR run left→right.
        for (lo, hi) in [(13, 18), (19, 24)] {
            for n in lo..<hi {
                XCTAssertLessThan(geom.point(n).center.x, geom.point(n + 1).center.x,
                                  "point \(n) should be left of \(n + 1)")
            }
        }
    }

    // 4 ── Tip direction + baseline width ──────────────────────────────────
    func testTipDirection() {
        for n in 1...12 { // bottom points tip upward
            XCTAssertLessThan(geom.point(n).tip.y, geom.point(n).center.y, "point \(n)")
        }
        for n in 13...24 { // top points tip downward
            XCTAssertGreaterThan(geom.point(n).tip.y, geom.point(n).center.y, "point \(n)")
        }
    }

    func testBaselineWidth() {
        let pointW: CGFloat = 365.0 / 6.0
        let p = geom.point(1)
        XCTAssertEqual(p.baselineRight.x - p.baselineLeft.x, pointW - 3.0, accuracy: eps)
    }

    // 5 ── Bear-off slots ──────────────────────────────────────────────────
    func testBearOffSlots() {
        let white = geom.point(25)
        let black = geom.point(0)
        XCTAssertNil(white.quadrant)
        XCTAssertNil(black.quadrant)
        // Both on the right of board center.
        XCTAssertGreaterThan(white.center.x, 450)
        XCTAssertGreaterThan(black.center.x, 450)
        // White (25) in the top half, Black (0) in the bottom half.
        XCTAssertLessThan(white.center.y, 450)
        XCTAssertGreaterThan(black.center.y, 450)
        // Defined, non-empty hit rects.
        XCTAssertGreaterThan(white.hitRect.width, 0)
        XCTAssertGreaterThan(white.hitRect.height, 0)
        XCTAssertGreaterThan(black.hitRect.width, 0)
        XCTAssertGreaterThan(black.hitRect.height, 0)
    }

    // 5b ── Bear-off checker stacking ──────────────────────────────────────
    func testBearOffCheckerStacking() {
        let r = geom.checkerRadius
        // White (25) stacks downward from the top; Black (0) upward from the
        // bottom. Both keep a constant strip x across slots.
        let w0 = geom.checkerCenter(point: 25, slot: 0)
        let w1 = geom.checkerCenter(point: 25, slot: 1)
        XCTAssertEqual(w0.x, w1.x, accuracy: eps)
        XCTAssertGreaterThan(w1.y, w0.y, "white tray stacks downward")
        let b0 = geom.checkerCenter(point: 0, slot: 0)
        let b1 = geom.checkerCenter(point: 0, slot: 1)
        XCTAssertEqual(b0.x, b1.x, accuracy: eps)
        XCTAssertLessThan(b1.y, b0.y, "black tray stacks upward")
        // A full-size checker is wider than the strip but must not clip the
        // board's right edge (it floats over the strip + play-surface edge).
        for slot in 0..<5 {
            XCTAssertLessThanOrEqual(
                geom.checkerCenter(point: 25, slot: slot).x + r, geom.boardRect.maxX,
                "white tray checker slot \(slot) clips the board edge"
            )
            XCTAssertLessThanOrEqual(
                geom.checkerCenter(point: 0, slot: slot).x + r, geom.boardRect.maxX,
                "black tray checker slot \(slot) clips the board edge"
            )
        }
    }

    // 5c ── Dice layout (center bar) ───────────────────────────────────────
    func testDiceLayout() {
        // Board center coincides with the bar center; die size is the design 56.
        XCTAssertEqual(geom.boardCenter.x, 450, accuracy: eps)
        XCTAssertEqual(geom.boardCenter.y, 450, accuracy: eps)
        XCTAssertEqual(geom.diceSize, 56, accuracy: eps)
        // Two dice sit horizontally next to each other, centered on the bar,
        // one die + gap (56+12=68) apart → design (416,450)/(484,450).
        let two = geom.diceCenters(count: 2)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two[0], CGPoint(x: 416, y: 450))
        XCTAssertEqual(two[1], CGPoint(x: 484, y: 450))
        // A pasch is all four dice in a single horizontal row (same y, left→right).
        let four = geom.diceCenters(count: 4)
        XCTAssertEqual(four, [
            CGPoint(x: 348, y: 450), CGPoint(x: 416, y: 450),
            CGPoint(x: 484, y: 450), CGPoint(x: 552, y: 450),
        ])
        // Layout scales with the board.
        let half = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 450, height: 450))
        XCTAssertEqual(half.diceSize, 28, accuracy: eps)
        XCTAssertEqual(half.diceCenters(count: 2)[0], CGPoint(x: 208, y: 225))
    }

    // 6 ── Scaling / fit ───────────────────────────────────────────────────
    func testHalfScale() {
        let half = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 450, height: 450))
        XCTAssertEqual(half.scale, 0.5, accuracy: eps)
        for n in [1, 7, 13, 19, 0, 25] {
            XCTAssertEqual(half.point(n).center.x, geom.point(n).center.x * 0.5, accuracy: eps)
            XCTAssertEqual(half.point(n).center.y, geom.point(n).center.y * 0.5, accuracy: eps)
        }
    }

    func testNonSquareFitsCenteredSquare() {
        let g = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(g.boardRect, CGRect(x: 200, y: 0, width: 600, height: 600))
        XCTAssertEqual(g.scale, 600.0 / 900.0, accuracy: eps)
        // A tall rect centers vertically instead.
        let tall = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 600, height: 1000))
        XCTAssertEqual(tall.boardRect, CGRect(x: 0, y: 200, width: 600, height: 600))
    }

    // ── Flip ──────────────────────────────────────────────────────────────

    func testFlipIndex() {
        // Bear-off trays swap.
        XCTAssertEqual(BoardGeometry.flipIndex(0), 25)
        XCTAssertEqual(BoardGeometry.flipIndex(25), 0)
        // Points 1–12 shift +12, points 13–24 shift −12.
        XCTAssertEqual(BoardGeometry.flipIndex(1), 13)
        XCTAssertEqual(BoardGeometry.flipIndex(12), 24)
        XCTAssertEqual(BoardGeometry.flipIndex(13), 1)
        XCTAssertEqual(BoardGeometry.flipIndex(24), 12)
        // Verify it is its own inverse.
        for n in 0...25 {
            XCTAssertEqual(BoardGeometry.flipIndex(BoardGeometry.flipIndex(n)), n, "n=\(n)")
        }
    }

    func testFlippedPointMatchesRotatedUnflipped() {
        let flipped = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 900, height: 900),
                                    flipped: true)
        // Logical point 1 (normally BR) should appear at the visual position
        // of point 13 (TL) in the unflipped geometry.
        XCTAssertEqual(flipped.point(1).center.x, geom.point(13).center.x, accuracy: eps)
        XCTAssertEqual(flipped.point(1).center.y, geom.point(13).center.y, accuracy: eps)
        // Logical point 24 (normally TR) should appear at point 12 (BL).
        XCTAssertEqual(flipped.point(24).center.x, geom.point(12).center.x, accuracy: eps)
        XCTAssertEqual(flipped.point(24).center.y, geom.point(12).center.y, accuracy: eps)
        // Bear-off trays move to the LEFT strip when flipped.
        // y coordinates still match the swapped unflipped positions (top↔bottom swap);
        // x is now the left-strip midpoint (frame/2 = 20), not the right (880).
        XCTAssertEqual(flipped.point(0).center.y, geom.point(25).center.y, accuracy: eps)
        XCTAssertLessThan(flipped.point(0).center.x, 450, "flipped Black tray must be on left")
        XCTAssertEqual(flipped.point(25).center.y, geom.point(0).center.y, accuracy: eps)
        XCTAssertLessThan(flipped.point(25).center.x, 450, "flipped White tray must be on left")
    }

    func testFlippedCheckerCenterSwapsBearOff() {
        let flipped = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 900, height: 900),
                                    flipped: true)
        // Flipped bear-off moves to the LEFT strip. Black's tray (logical 0) stacks
        // from the top (same vertical direction as unflipped White/25), but at the
        // left-strip x rather than the right-strip x.
        let fBlack0 = flipped.checkerCenter(point: 0, slot: 0)
        let fBlack1 = flipped.checkerCenter(point: 0, slot: 1)
        // y grows downward from the top, same as unflipped slot 25.
        XCTAssertEqual(fBlack0.y, geom.checkerCenter(point: 25, slot: 0).y, accuracy: eps)
        XCTAssertGreaterThan(fBlack1.y, fBlack0.y, "flipped Black tray stacks downward")
        // x is on the left side of the board.
        XCTAssertLessThan(fBlack0.x, 450, "flipped Black tray checker must be on left")
        // x is constant across slots.
        XCTAssertEqual(fBlack0.x, fBlack1.x, accuracy: eps)
    }

    func testFlippedHitTestReturnsLogicalIndex() {
        let flipped = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 900, height: 900),
                                    flipped: true)
        // Tapping at the visual center of unflipped-point 13 (= flipped logical 1)
        // should return logical index 1.
        let r13 = geom.point(13).hitRect
        let loc = CGPoint(x: r13.midX, y: r13.midY)
        XCTAssertEqual(flipped.hitTest(loc, candidates: Array(1...24)), 1)
    }

    // 7 ── hitTest ─────────────────────────────────────────────────────────
    func testHitTestPlayablePoint() {
        let inside = geom.point(1).hitRect
        let loc = CGPoint(x: inside.midX, y: inside.midY)
        XCTAssertEqual(geom.hitTest(loc, candidates: [1, 2, 3]), 1)
        XCTAssertNil(geom.hitTest(loc, candidates: [2, 3]), "not a candidate → nil")
    }

    func testHitTestBarGapMisses() {
        let all = Array(0...25)
        // Center of the board sits in the bar gap, no point lane.
        XCTAssertNil(geom.hitTest(CGPoint(x: 450, y: 450), candidates: all))
    }

    func testHitTestBearOff() {
        let all = Array(0...25)
        XCTAssertEqual(geom.hitTest(geom.point(25).center, candidates: all), 25)
        XCTAssertEqual(geom.hitTest(geom.point(0).center, candidates: all), 0)
    }
}
