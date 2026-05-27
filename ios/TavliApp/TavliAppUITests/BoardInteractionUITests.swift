import XCTest
import UIKit
import BoardGeometry

/// Drives the real SwiftUI gesture stack: launches into a deterministic game and
/// moves a checker by tap and by drag, asserting the board actually changes. This
/// is the end-to-end reproduction of the "tap/move does nothing" report — the
/// headless tests already prove the engine/geometry, so this guards the view.
final class BoardInteractionUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func parse(_ value: String?) -> [Int] {
        (value ?? "").split(separator: ",").map { Int($0) ?? -1 }
    }

    private func launchedBoard() -> (XCUIApplication, XCUIElement) {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestGame"]   // Black opens, all 15 on 24, dice (3,5)
        app.launch()
        let board = app.otherElements["board"]
        XCTAssertTrue(board.waitForExistence(timeout: 5), "board should be on screen")
        let before = parse(board.value as? String)
        XCTAssertEqual(before[24], 15, "Black starts with 15 on point 24")
        XCTAssertEqual(before[19], 0, "point 19 starts empty")
        return (app, board)
    }

    private func offset(_ board: XCUIElement, point n: Int) -> XCUICoordinate {
        let frame = board.frame
        let geo = BoardGeometry(rect: CGRect(origin: .zero, size: frame.size))
        let c = geo.checkerCenter(point: n, slot: 0)
        return board.coordinate(withNormalizedOffset:
            CGVector(dx: c.x / frame.width, dy: c.y / frame.height))
    }

    /// `value` after committing 24 → 19: point 19 holds 1, point 24 holds 14.
    private func assertMoved24to19(_ board: XCUIElement) {
        let committed = NSPredicate(format: "value MATCHES %@", "(\\d+,){19}1,(\\d+,){4}14,\\d+")
        expectation(for: committed, evaluatedWith: board)
        waitForExpectations(timeout: 3)
        let after = parse(board.value as? String)
        XCTAssertEqual(after[24], 14, "a checker should have left point 24")
        XCTAssertEqual(after[19], 1, "a checker should have landed on point 19")
    }

    /// Tap the source checker, then tap the highlighted target.
    func testTapToMoveChangesBoard() {
        let (_, board) = launchedBoard()
        offset(board, point: 24).tap()
        offset(board, point: 19).tap()
        assertMoved24to19(board)
    }

    /// Drag the source checker onto the target — the real-device path that mutated
    /// session state mid-gesture and previously cancelled before committing.
    func testDragToMoveChangesBoard() {
        let (_, board) = launchedBoard()
        offset(board, point: 24).press(forDuration: 0.1, thenDragTo: offset(board, point: 19))
        assertMoved24to19(board)
    }

    /// Completing the human's full turn (both dice) must hand off to the AI, which
    /// then plays — directly guards the "opponent doesn't move" symptom.
    func testFullHumanTurnTriggersAIResponse() {
        let (_, board) = launchedBoard()
        // Black plays both dice from point 24 (die 3 → 21, die 5 → 19).
        offset(board, point: 24).tap(); offset(board, point: 21).tap()
        offset(board, point: 24).tap(); offset(board, point: 19).tap()

        // White (AI) opens from point 1, so its count must drop below 15.
        let aiMoved = NSPredicate(format: "NOT (value MATCHES %@)", "0,15,.*")
        expectation(for: aiMoved, evaluatedWith: board)
        waitForExpectations(timeout: 15)

        let after = parse(board.value as? String)
        XCTAssertLessThan(after[1], 15, "the AI (White) should have moved a checker off point 1")
        XCTAssertEqual(after[21], 1, "Black's die-3 half-move should have landed on 21")
        XCTAssertEqual(after[19], 1, "Black's die-5 half-move should have landed on 19")
    }

    /// The board must *visually* update after a move, not just in the model. Black
    /// renders red, so an occupied point 19 reads low-green; the empty ivory
    /// triangle reads high-green. Guards the reference-type-board stale-Canvas bug.
    func testCheckerVisuallyRendersAfterMove() {
        let (app, board) = launchedBoard()
        let frame = board.frame
        let geo = BoardGeometry(rect: CGRect(origin: .zero, size: frame.size))

        offset(board, point: 24).tap()
        offset(board, point: 19).tap()
        assertMoved24to19(board)   // model committed

        func sampleGreen(point n: Int) -> CGFloat {
            let c = geo.checkerCenter(point: n, slot: 0)
            return greenChannel(app.screenshot().image,
                                atScreenPoint: CGPoint(x: frame.minX + c.x, y: frame.minY + c.y), app: app)
        }

        // Poll for the moved checker (point 19 → red, low green) to appear.
        var g19: CGFloat = 1
        let deadline = Date().addingTimeInterval(3)
        repeat { g19 = sampleGreen(point: 19); if g19 < 0.5 { break } } while Date() < deadline

        // Diagnostics: point 24 holds red checkers since launch; point 1 holds white.
        let g24 = sampleGreen(point: 24), g1 = sampleGreen(point: 1)
        XCTAssertLessThan(g19, 0.5,
            "point19 green=\(g19) (expected red); diag point24=\(g24) point1=\(g1) — high point19 with low point24 means the board renders the initial position but never repaints the move")
    }

    /// Green channel [0,1] of the screenshot pixel under a screen-space point.
    /// Uses `CGImage.cropping` (top-left image coordinates) to isolate the pixel —
    /// drawing the full image into a `CGContext` would flip Y and mis-sample.
    private func greenChannel(_ image: UIImage, atScreenPoint p: CGPoint, app: XCUIApplication) -> CGFloat {
        guard let cg = image.cgImage else { return 1 }
        let ppp = CGFloat(cg.width) / app.windows.firstMatch.frame.width   // pixels per point
        let px = Int(p.x * ppp), py = Int(p.y * ppp)
        guard px >= 0, py >= 0, px < cg.width, py < cg.height,
              let pixel = cg.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return 1 }
        var rgba = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(rgba[1]) / 255
    }
}
