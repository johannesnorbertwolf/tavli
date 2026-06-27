import XCTest
@testable import TavliEngine

/// `GameSession.applyRemoteMove` (#134): applying a networked opponent's ply into a
/// human-vs-human session. Covers acceptance + turn hand-off, rejection of an
/// illegal ply, the forced-pass case, and exact equivalence with replay (the
/// reconnection/catch-up path) across a sequence that includes a Pasch.
@MainActor
final class GameSessionRemoteTests: XCTestCase {

    /// A by-value snapshot of every point's stack.
    private func signature(_ board: GameBoard) -> [[Color]] { board.points.map(\.pieces) }

    /// A legal ply for the session's current player under the given dice, taken as
    /// the move generator's first candidate (a forced pass when there is none).
    private func legalPly(_ session: GameSession, _ d1: Int, _ d2: Int) -> PlyRecord {
        let dice = Dice(numberOfSides: 6)
        dice.set(d1, d2)
        let legal = PossibleMoves(board: session.game.board,
                                  color: session.currentPlayer, dice: dice).findMoves()
        let pairs = legal.first.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } } ?? []
        return PlyRecord(die1: d1, die2: d2, halfMoves: pairs)
    }

    private func newHvHSession(starting: Color = .white) -> GameSession {
        let s = GameSession(startingPlayer: starting, aiColor: nil, animationTimings: .off)
        s.start()
        return s
    }

    func testAcceptsLegalMoveAndHandsOffTurn() {
        let s = newHvHSession(starting: .white)
        let ply = legalPly(s, 3, 5)
        XCTAssertFalse(ply.halfMoves.isEmpty)

        XCTAssertTrue(s.applyRemoteMove(ply))
        XCTAssertEqual(s.currentPlayer, .black)          // turn handed to the opponent
        XCTAssertEqual(s.history.count, 1)
        XCTAssertEqual(s.history.first, ply)             // recorded exactly as received
        XCTAssertEqual(s.phase, .awaitingRoll)
    }

    func testRejectsIllegalMoveWithoutMutating() {
        let s = newHvHSession(starting: .white)
        let before = signature(s.game.board)

        // Distance-3 half-move under dice (1,1): impossible — must be rejected.
        let bogus = PlyRecord(die1: 1, die2: 1, halfMoves: [[1, 4]])
        XCTAssertFalse(s.applyRemoteMove(bogus))
        XCTAssertEqual(s.currentPlayer, .white)          // still our move
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertEqual(signature(s.game.board), before)  // board untouched
    }

    func testRejectsOutOfRangeIndices() {
        let s = newHvHSession(starting: .white)
        let bogus = PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 999]])
        XCTAssertFalse(s.applyRemoteMove(bogus))
        XCTAssertTrue(s.history.isEmpty)
    }

    func testForcedPassAcceptedOnlyWhenNoMoveExists() {
        // White's lone checker at 1 is walled in: 1+3, 1+5, 1+3+5 all closed by
        // black doubles, so dice (3,5) yield no legal move.
        let s = newHvHSession(starting: .white)
        for i in s.game.board.points.indices { s.game.board.setPoint(i, pieces: []) }
        s.game.board.setPoint(1, pieces: [.white])
        s.game.board.setPoint(4, pieces: [.black, .black])
        s.game.board.setPoint(6, pieces: [.black, .black])
        s.game.board.setPoint(9, pieces: [.black, .black])

        // A real move here is illegal (nothing is playable).
        XCTAssertFalse(s.applyRemoteMove(PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4]])))
        XCTAssertTrue(s.history.isEmpty)

        // The pass is accepted and hands the turn over.
        XCTAssertTrue(s.applyRemoteMove(PlyRecord(die1: 3, die2: 5, halfMoves: [])))
        XCTAssertEqual(s.currentPlayer, .black)
        XCTAssertEqual(s.history.count, 1)
        XCTAssertTrue(s.history.first?.halfMoves.isEmpty == true)
    }

    func testPassRejectedWhenAMoveIsAvailable() {
        let s = newHvHSession(starting: .white)
        // From the opening position white plainly has moves, so a pass is a desync.
        XCTAssertFalse(s.applyRemoteMove(PlyRecord(die1: 3, die2: 5, halfMoves: [])))
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertEqual(s.currentPlayer, .white)
    }

    /// Driving a session purely through `applyRemoteMove` must land on exactly the
    /// board (and ply log) that rebuilding from the same plies via `replay` produces —
    /// this is what makes reconnection "decode + replay". The schedule includes a
    /// Pasch (2,2) to exercise multi-hop application.
    func testRemoteSequenceEquivalentToReplay() {
        let live = newHvHSession(starting: .white)
        let schedule = [(3, 5), (4, 2), (2, 2), (6, 1), (5, 3), (1, 4)]

        var plies: [PlyRecord] = []
        for (d1, d2) in schedule {
            guard !live.isTerminal else { break }
            let ply = legalPly(live, d1, d2)
            XCTAssertTrue(live.applyRemoteMove(ply), "ply \(ply) should be legal")
            plies.append(ply)
        }
        XCTAssertEqual(live.history, plies)

        // Rebuild from the authoritative log (the reconnection path) and compare.
        let payload = OnlineMatchPayload(startingPlayer: .white,
                                         colorByPlayerID: [:],
                                         plies: plies)
        let rebuilt = GameSession.resume(from: payload.gameSave(), animationTimings: .off)

        XCTAssertEqual(signature(rebuilt.game.board), signature(live.game.board))
        XCTAssertEqual(rebuilt.history, live.history)
        XCTAssertEqual(rebuilt.currentPlayer, live.currentPlayer)
    }
}
