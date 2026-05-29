import XCTest
import CoreGraphics
@testable import TavliEngine
import BoardGeometry

/// Reproduces the `PlayableBoardView` tap path headlessly: derive a tap location
/// from `BoardGeometry`, resolve it with `hitTest`, and route it through the same
/// `GameSession` intents the view calls. Guards the index↔screen↔intent round trip
/// independently of SwiftUI's gesture plumbing.
@MainActor
final class BoardInteractionTests: XCTestCase {

    private let geo = BoardGeometry(rect: CGRect(x: 0, y: 0, width: 786, height: 786))

    /// Tapping a checker then a highlighted target must commit a half-move — the
    /// exact interaction reported as broken.
    func testTapSourceThenTargetCommitsHalfMove() {
        let s = GameSession(startingPlayer: .black)  // Black: 15 on point 24
        s.setManualDice(3, 5)
        XCTAssertEqual(s.phase, .picking)

        // Tap the top checker of Black's stack on point 24.
        let srcLoc = geo.checkerCenter(point: 24, slot: 0)
        XCTAssertEqual(geo.hitTest(srcLoc, candidates: Array(0...25)), 24,
                       "tapping point 24's checker should hit-test to 24")
        s.selectPoint(24)
        XCTAssertEqual(s.selectedPoint, 24)
        XCTAssertFalse(s.validTargets.isEmpty, "a rolled source must highlight targets")

        // Tap a highlighted target lane.
        let target = s.validTargets.sorted().first!
        let tgtLoc = geo.checkerCenter(point: target, slot: 0)
        XCTAssertEqual(geo.hitTest(tgtLoc, candidates: Array(0...25)), target,
                       "tapping a highlighted target lane should hit-test back to it")

        let before = s.game.board.points[target].count
        s.commitHalfMove(from: 24, to: target)
        XCTAssertEqual(s.game.board.points[target].count, before + 1,
                       "committing 24→\(target) must move a checker onto \(target)")
        // A merged (two-die) target unmerges into single-die hops, so assert the
        // committed chain leaves 24 and lands on the tapped target.
        XCTAssertEqual(s.moveBuilder.built.first?.from.position, 24)
        XCTAssertEqual(s.moveBuilder.built.last?.to.position, target)
    }

    /// Every highlighted target a source offers must hit-test back to itself, so a
    /// tap on any gold lane lands on the point the engine expects.
    func testEveryHighlightedTargetHitTestsToItself() {
        let s = GameSession(startingPlayer: .black)
        s.setManualDice(3, 5)
        for source in s.selectableSources {
            s.selectPoint(source)
            for target in s.validTargets where target != 0 && target != 25 {
                let loc = geo.checkerCenter(point: target, slot: 0)
                XCTAssertEqual(geo.hitTest(loc, candidates: Array(0...25)), target,
                               "target \(target) (from \(source)) must hit-test to itself")
            }
        }
    }
}
