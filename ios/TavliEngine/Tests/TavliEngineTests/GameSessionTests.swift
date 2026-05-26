import XCTest
@testable import TavliEngine

// Deterministic generator so scripted games replay identically.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

private func hm(_ from: Int, _ to: Int, _ color: Color = .white) -> HalfMove {
    HalfMove(from: Point(position: from), to: Point(position: to), color: color)
}

private func move(_ pairs: [(Int, Int)], _ color: Color = .white) -> Move {
    Move(pairs.map { hm($0.0, $0.1, color) })
}

// ── MoveBuilder ────────────────────────────────────────────────────────────────

final class MoveBuilderTests: XCTestCase {
    func testSelectableSourcesAndDestinations() {
        let legal = [
            move([(1, 3), (3, 6)]),
            move([(1, 4), (4, 8)]),
            move([(5, 8)]),
        ]
        let b = MoveBuilder(legalMoves: legal)
        XCTAssertEqual(b.selectableSourcePoints, [1, 5])
        XCTAssertEqual(b.validDestinations(for: 1), [3, 4])
        XCTAssertEqual(b.validDestinations(for: 5), [8])
        XCTAssertEqual(b.validDestinations(for: 9), [])
    }

    func testCommitNarrowsAndCompletes() {
        let legal = [
            move([(1, 3), (3, 6)]),
            move([(1, 4), (4, 8)]),
            move([(5, 8)]),
        ]
        let b = MoveBuilder(legalMoves: legal)

        XCTAssertFalse(b.commit(halfMove: hm(1, 3)))  // not yet complete
        XCTAssertEqual(b.activeMoves.count, 1)        // only the (1,3),(3,6) survives
        XCTAssertEqual(b.selectableSourcePoints, [3])
        XCTAssertFalse(b.canFinishNow)

        XCTAssertTrue(b.commit(halfMove: hm(3, 6)))   // now complete
        XCTAssertEqual(b.completedMove, move([(1, 3), (3, 6)]))
    }

    func testCanFinishNowWhenShorterMoveIsPrefix() {
        let legal = [
            move([(1, 3)]),
            move([(1, 3), (3, 6)]),
        ]
        let b = MoveBuilder(legalMoves: legal)

        // Committing the shared first half-move: a 1-half move is already legal,
        // but a 2-half continuation also survives, so it is finishable, not forced.
        XCTAssertFalse(b.commit(halfMove: hm(1, 3)))
        XCTAssertTrue(b.canFinishNow)
        XCTAssertEqual(b.completedMove, move([(1, 3)]))
        XCTAssertEqual(b.selectableSourcePoints, [3])  // can also play on
    }

    func testUndoRebuildsFromScratch() {
        let legal = [
            move([(1, 3), (3, 6)]),
            move([(1, 4), (4, 8)]),
        ]
        let b = MoveBuilder(legalMoves: legal)
        b.commit(halfMove: hm(1, 3))
        b.commit(halfMove: hm(3, 6))
        XCTAssertEqual(b.built.count, 2)

        b.undo(allLegal: legal)
        XCTAssertEqual(b.built, [hm(1, 3)])
        XCTAssertEqual(b.activeMoves.count, 1)
        XCTAssertEqual(b.selectableSourcePoints, [3])

        b.undo(allLegal: legal)
        XCTAssertTrue(b.built.isEmpty)
        XCTAssertEqual(b.selectableSourcePoints, [1])  // back to start
    }
}

// ── GameSession ──────────────────────────────────────────────────────────────

@MainActor
final class GameSessionTests: XCTestCase {
    func testRollMovesIntoPickingWithSources() {
        let s = GameSession(startingPlayer: .white)
        XCTAssertEqual(s.phase, .awaitingRoll)
        s.setManualDice(3, 5)
        XCTAssertEqual(s.phase, .picking)
        XCTAssertFalse(s.selectableSources.isEmpty)
        XCTAssertFalse(s.legalMoves.isEmpty)
    }

    func testSelectAndUndoSelectionState() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        let src = s.selectableSources.sorted().first!
        s.selectPoint(src)
        XCTAssertEqual(s.phase, .moving)
        XCTAssertEqual(s.selectedPoint, src)
        XCTAssertFalse(s.validTargets.isEmpty)

        // Selecting a non-source clears the selection.
        s.selectPoint(99)
        XCTAssertEqual(s.phase, .picking)
        XCTAssertNil(s.selectedPoint)
        XCTAssertTrue(s.validTargets.isEmpty)
    }

    func testCommitThenUndoRestoresBoardAndState() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        let src = s.selectableSources.sorted().first!
        let dst = s.moveBuilder.validDestinations(for: src).sorted().first!
        let beforeFrom = s.game.board.points[src].count
        let beforeTo = s.game.board.points[dst].count

        s.commitHalfMove(from: src, to: dst)
        XCTAssertEqual(s.moveBuilder.built.count, 1)
        XCTAssertEqual(s.game.board.points[src].count, beforeFrom - 1)
        XCTAssertEqual(s.game.board.points[dst].count, beforeTo + 1)

        s.undo()
        XCTAssertTrue(s.moveBuilder.built.isEmpty)
        XCTAssertEqual(s.game.board.points[src].count, beforeFrom)
        XCTAssertEqual(s.game.board.points[dst].count, beforeTo)
        XCTAssertEqual(s.phase, .picking)
    }

    func testForcedPassAdvancesTurn() {
        let s = GameSession(startingPlayer: .white)
        let b = s.game.board
        for i in 0...(b.boardSize + 1) { b.setPoint(i, pieces: []) }
        b.setPoint(5, pieces: [.white])             // lone white checker
        b.setPoint(6, pieces: [.black, .black])     // blocks die=1
        b.setPoint(7, pieces: [.black, .black])     // blocks die=2

        s.setManualDice(1, 2)
        XCTAssertEqual(s.legalMoves.count, 0)
        XCTAssertEqual(s.currentPlayer, .black)     // turn advanced
        XCTAssertEqual(s.phase, .awaitingRoll)
    }

    func testNewGameResets() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        s.selectPoint(s.selectableSources.sorted().first!)
        s.newGame(startingPlayer: .black)
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertEqual(s.currentPlayer, .black)
        XCTAssertTrue(s.legalMoves.isEmpty)
        XCTAssertNil(s.selectedPoint)
    }

    /// Drives a complete game to a win using only session intents.
    func testScriptedFullGameReachesWin() {
        let s = GameSession(startingPlayer: .black)
        var rng = SeededRNG(seed: 0xCAFEBABE)

        var turns = 0
        loop: while true {
            switch s.phase {
            case .gameOver:
                break loop
            case .awaitingRoll:
                turns += 1
                XCTAssertLessThan(turns, 100_000, "game failed to terminate")
                s.setManualDice(Int.random(in: 1...6, using: &rng),
                                Int.random(in: 1...6, using: &rng))
            case .picking, .moving:
                guard let chosen = s.moveBuilder.activeMoves.first else {
                    XCTFail("no active move while picking")
                    break loop
                }
                // Replay the chosen move's half-moves through the intents.
                while s.phase == .picking || s.phase == .moving {
                    let idx = s.moveBuilder.built.count
                    guard idx < chosen.halfMoves.count else { break }
                    let h = chosen.halfMoves[idx]
                    s.selectPoint(h.from.position)
                    s.commitHalfMove(from: h.from.position, to: h.to.position)
                }
            case .aiThinking, .animating:
                XCTFail("session entered an out-of-scope phase")
                break loop
            }
        }

        guard case .gameOver(let winner) = s.phase else {
            return XCTFail("game did not reach gameOver")
        }
        XCTAssertTrue(s.game.isOver())
        XCTAssertEqual(s.game.getWinner(), winner)
    }
}
