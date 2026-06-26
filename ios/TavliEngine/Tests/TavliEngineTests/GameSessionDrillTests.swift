import XCTest
@testable import TavliEngine

/// Attempt mode + the drill seeder (#63): the engine support behind the post-game
/// drill. Headless (no Core ML) — attempt *scoring* is covered by the `Agent` /
/// `GameReview` fixture tests.
@MainActor
final class GameSessionDrillTests: XCTestCase {

    // MARK: - Attempt mode

    /// With `onMoveAttempt` set, completing a move reports it and rolls the board
    /// back to the pre-move position, leaving the turn and record untouched so the
    /// same position can be re-attempted.
    func testAttemptModeReportsAndRollsBack() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        let before = s.game.board.points.map(\.pieces)

        var reported: [Move] = []
        s.onMoveAttempt = { reported.append($0) }

        // Drive a full two-die move (single checker from point 1 via 3 then 5).
        s.commitHalfMove(from: 1, to: 4)
        s.commitHalfMove(from: 4, to: 9)

        XCTAssertEqual(reported.count, 1, "one completed attempt → one report")
        XCTAssertEqual(reported.first.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } },
                       [[1, 4], [4, 9]])

        // Board restored exactly; still White's turn in picking; nothing recorded.
        XCTAssertEqual(s.game.board.points.map(\.pieces), before)
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.currentPlayer, .white)
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertFalse(s.selectableSources.isEmpty, "position re-armed for another attempt")
    }

    /// With `holdAttempts`, a completed attempt stays on the board (input locked) and
    /// only `retryAttempt()` rolls it back to the pre-move position (#114).
    func testHoldAttemptKeepsPositionUntilRetry() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        let before = s.game.board.points.map(\.pieces)
        var reported = 0
        s.onMoveAttempt = { _ in reported += 1 }
        s.holdAttempts = true

        s.commitHalfMove(from: 1, to: 4)
        s.commitHalfMove(from: 4, to: 9)

        XCTAssertEqual(reported, 1)
        XCTAssertNotNil(s.heldAttempt, "the attempt is held on the board")
        XCTAssertNotEqual(s.game.board.points.map(\.pieces), before, "board shows the move's result")
        XCTAssertTrue(s.selectableSources.isEmpty, "input is locked while an attempt is held")

        s.retryAttempt()
        XCTAssertNil(s.heldAttempt)
        XCTAssertEqual(s.game.board.points.map(\.pieces), before, "rolled back to the pre-move position")
        XCTAssertEqual(s.phase, .picking)
        XCTAssertFalse(s.selectableSources.isEmpty, "re-armed for another attempt")
    }

    /// Two attempts in a row both fire and both leave the position pristine.
    func testAttemptModeAllowsRepeatedTries() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        let before = s.game.board.points.map(\.pieces)
        var reported = 0
        s.onMoveAttempt = { _ in reported += 1 }

        s.commitHalfMove(from: 1, to: 4)
        s.commitHalfMove(from: 4, to: 9)
        s.commitHalfMove(from: 1, to: 6)   // a different attempt from the same position
        s.commitHalfMove(from: 6, to: 9)

        XCTAssertEqual(reported, 2)
        XCTAssertEqual(s.game.board.points.map(\.pieces), before)
    }

    /// With the hook nil (normal play), a completed move still records + advances.
    func testNormalPlayUnaffected() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        s.commitHalfMove(from: 1, to: 4)
        s.commitHalfMove(from: 4, to: 9)

        XCTAssertEqual(s.history.count, 1, "move recorded")
        XCTAssertEqual(s.currentPlayer, .black, "turn advanced")
    }

    // MARK: - Drill seeder

    /// `drill(...)` seeds the given stacks, dice, and mover, landing in `.picking`
    /// with legal moves to choose from.
    func testDrillSeedsPositionInPicking() {
        // Two independent White checkers on an otherwise empty board.
        var stacks = Array(repeating: [Color](), count: 26)
        stacks[1] = [.white]
        stacks[13] = [.white]
        stacks[24] = [.black]

        let s = GameSession.drill(boardStacks: stacks, die1: 3, die2: 5, mover: .white)

        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.currentPlayer, .white)
        XCTAssertNil(s.aiColor, "drill is human-vs-human")
        XCTAssertEqual(s.game.board.points.map(\.pieces), stacks)
        XCTAssertFalse(s.legalMoves.isEmpty)
        XCTAssertEqual(s.selectableSources, [1, 13])
    }

    /// The seeded session honors attempt mode end-to-end.
    func testDrillSeededSessionAttempt() {
        var stacks = Array(repeating: [Color](), count: 26)
        stacks[1] = [.white]
        stacks[13] = [.white]
        let s = GameSession.drill(boardStacks: stacks, die1: 3, die2: 5, mover: .white)

        var reported: [Move] = []
        s.onMoveAttempt = { reported.append($0) }
        s.commitHalfMove(from: 1, to: 4)
        s.commitHalfMove(from: 13, to: 18)

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(s.game.board.points.map(\.pieces), stacks, "position pristine after attempt")
    }
}
