import XCTest
@testable import TavliEngine

/// Stresses the domain invariant the bug report points at: nothing except an
/// actual committed game move may ever leave the board mutated. Two angles:
///  1. Every legal move must round-trip: `apply` then `undo` restores the board
///     exactly (per-point stacks), for many reachable positions.
///  2. Playing half-moves in arbitrary (non-canonical) order through the session
///     intents — the freedom the UI gives the player — must conserve checkers.
@MainActor
final class BoardConservationTests: XCTestCase {

    /// Deterministic generator so a failure is reproducible.
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func snapshot(_ board: GameBoard) -> [[Color]] { board.points.map(\.pieces) }

    private func totalCheckers(_ board: GameBoard) -> Int {
        board.points.reduce(0) { $0 + $1.count }
    }

    /// `restoreStacks` must reverse arbitrary mutations exactly — the safety net
    /// analysis relies on to never corrupt the live board.
    func testCaptureRestoreStacksIsExact() {
        let board = GameBoard(config: .standard)
        board.initializeBoard()
        let saved = board.captureStacks()

        // Scramble: pins, partial stacks, borne-off.
        board.setPoint(1, pieces: [.black, .white])
        board.setPoint(24, pieces: [.white, .black, .black])
        board.setPoint(0, pieces: [.black, .black])
        board.setPoint(13, pieces: [.white])
        XCTAssertNotEqual(snapshot(board), saved)

        board.restoreStacks(saved)
        XCTAssertEqual(snapshot(board), saved, "restoreStacks must reproduce the captured board exactly")
    }

    /// `apply` then `undo` must restore the board byte-for-byte, for every legal
    /// move in many positions reached by random self-play. This is the direct test
    /// of "every non-game move is undone": move scoring (AI + overlay) relies on it.
    func testApplyUndoRoundTripsForEveryLegalMove() {
        var rng = LCG(0xD1CE) // any fixed seed
        let expected = 2 * GameConfig.standard.piecesPerPlayer

        for game in 0..<40 {
            let g = Game(config: .standard, startingPlayer: game.isMultiple(of: 2) ? .white : .black)
            for _ in 0..<200 {
                if g.isOver() { break }
                g.dice.set(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
                let moves = PossibleMoves(board: g.board, color: g.currentPlayer, dice: g.dice).findMoves()

                // Every legal move must restore the board after apply+undo.
                let before = snapshot(g.board)
                for move in moves {
                    g.board.apply(move)
                    g.board.undo(move)
                    XCTAssertEqual(snapshot(g.board), before,
                                   "apply/undo of \(move) corrupted the board")
                }

                XCTAssertEqual(totalCheckers(g.board), expected, "checker leak after probing moves")

                // Advance with one random legal move (or pass).
                if let move = moves.randomElement(using: &rng) {
                    g.board.apply(move)
                    XCTAssertEqual(totalCheckers(g.board), expected, "checker leak after a real move")
                }
                if g.isOver() { break }
                g.switchTurn()
            }
        }
    }

    /// Drive full games through the same intents the board view calls
    /// (`selectPoint`/`commitHalfMove`/`confirm`), choosing a RANDOM legal
    /// source/target at each step rather than the canonical order. The UI permits
    /// any legal ordering; checkers must be conserved no matter which the player picks.
    func testRandomOrderSessionPlayConservesCheckers() {
        var rng = LCG(0xC0FFEE)
        let expected = 2 * GameConfig.standard.piecesPerPlayer

        for _ in 0..<60 {
            let s = GameSession(startingPlayer: .white)  // human-vs-human: isolate the domain
            var guardCounter = 0
            loop: while true {
                guardCounter += 1
                XCTAssertLessThan(guardCounter, 100_000, "game failed to terminate")
                switch s.phase {
                case .gameOver:
                    break loop
                case .awaitingRoll:
                    XCTAssertEqual(totalCheckers(s.game.board), expected, "leak at turn start")
                    s.setManualDice(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
                case .picking, .moving:
                    // Occasionally stop early when the partial sequence is already legal.
                    if s.moveBuilder.canFinishNow, Bool.random(using: &rng) {
                        s.confirm()
                        continue
                    }
                    let sources = Array(s.selectableSources)
                    guard let src = sources.randomElement(using: &rng) else {
                        // No source but not finishable — shouldn't happen; bail safely.
                        if s.moveBuilder.canFinishNow { s.confirm() }
                        break loop
                    }
                    s.selectPoint(src)
                    guard let dst = Array(s.validTargets).randomElement(using: &rng) else {
                        s.selectPoint(src) // clear; pick again next iteration
                        continue
                    }
                    s.commitHalfMove(from: src, to: dst)
                    XCTAssertEqual(totalCheckers(s.game.board), expected, "leak after a committed half-move")
                case .aiThinking, .animating:
                    break loop // no AI in this session
                }
            }
            XCTAssertEqual(totalCheckers(s.game.board), expected, "leak at game end")
        }
    }
}
