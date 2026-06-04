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

/// An all-empty standard board seeded with `occupancy` (point index -> stack).
private func makeBoard(_ occupancy: [Int: [Color]]) -> GameBoard {
    let b = GameBoard(config: .standard)   // GameBoard starts empty
    for (pos, pieces) in occupancy { b.setPoint(pos, pieces: pieces) }
    return b
}

/// A by-value snapshot of every point's stack — exact-restore signature for undo tests.
private func signature(_ board: GameBoard) -> [[Color]] {
    board.points.map(\.pieces)
}

/// Commit a half-move through the builder while mutating the board in step, exactly
/// as `GameSession` does — the builder reads occupancy, so the board must advance
/// with each commit.
@discardableResult
private func play(_ b: MoveBuilder, on board: GameBoard,
                  _ from: Int, _ to: Int, _ color: Color = .white) -> Bool {
    let h = HalfMove(from: board.points[from], to: board.points[to], color: color)
    board.applyHalfMove(h)
    return b.commit(halfMove: h)
}

/// Undo the last half-move through the builder while reverting the board, mirroring
/// `GameSession.undo`.
private func unplay(_ b: MoveBuilder, on board: GameBoard,
                    _ from: Int, _ to: Int, _ color: Color = .white) {
    board.undoHalfMove(HalfMove(from: board.points[from], to: board.points[to], color: color))
    b.undo()
}

// ── MoveBuilder ────────────────────────────────────────────────────────────────

final class MoveBuilderTests: XCTestCase {
    func testSelectableSourcesAndImmediateDestinations() {
        // Two independent white checkers; curated single-hop options.
        let bd = makeBoard([1: [.white], 5: [.white]])
        let legal = [
            move([(1, 3), (5, 8)]),
            move([(1, 4), (5, 8)]),
        ]
        let b = MoveBuilder(legalMoves: legal, board: bd)
        XCTAssertEqual(b.selectableSourcePoints, [1, 5])
        XCTAssertEqual(b.validDestinations(for: 1), [3, 4])
        XCTAssertEqual(b.validDestinations(for: 5), [8])
        XCTAssertEqual(b.validDestinations(for: 9), [])
    }

    func testMultiHopChainDestinationsAndPaths() {
        // A single checker on a Pasch chains along the die ray (die = 2).
        let bd = makeBoard([1: [.white]])
        let legal = [move([(1, 3), (3, 5), (5, 7), (7, 9)])]
        let b = MoveBuilder(legalMoves: legal, board: bd)

        XCTAssertEqual(b.selectableSourcePoints, [1])           // only the real checker
        XCTAssertEqual(b.validDestinations(for: 1), [3, 5, 7, 9])  // full ray
        XCTAssertEqual(b.validDestinations(for: 3), [])         // empty until 1→3
        XCTAssertEqual(b.path(from: 1, to: 5), [hm(1, 3), hm(3, 5)])
        XCTAssertEqual(b.path(from: 1, to: 9), [hm(1, 3), hm(3, 5), hm(5, 7), hm(7, 9)])
        XCTAssertEqual(b.path(from: 1, to: 6), [])              // unreachable
    }

    func testCommitNarrowsAndCompletes() {
        let bd = makeBoard([1: [.white], 5: [.white]])
        let legal = [
            move([(1, 3), (5, 8)]),
            move([(1, 4), (5, 8)]),
        ]
        let b = MoveBuilder(legalMoves: legal, board: bd)

        XCTAssertFalse(play(b, on: bd, 1, 3))         // not yet complete
        XCTAssertEqual(b.activeMoves.count, 1)        // only (1,3),(5,8) survives
        XCTAssertEqual(b.selectableSourcePoints, [5])
        XCTAssertFalse(b.canFinishNow)

        XCTAssertTrue(play(b, on: bd, 5, 8))          // now complete
        XCTAssertEqual(b.completedMove, move([(1, 3), (5, 8)]))
    }

    func testCanFinishNowWhenShorterMoveIsPrefix() {
        let bd = makeBoard([1: [.white]])
        let legal = [
            move([(1, 3)]),
            move([(1, 3), (3, 5)]),
        ]
        let b = MoveBuilder(legalMoves: legal, board: bd)

        // Committing the shared first half-move: a 1-half move is already legal,
        // but a 2-half continuation also survives, so it is finishable, not forced.
        XCTAssertFalse(play(b, on: bd, 1, 3))
        XCTAssertTrue(b.canFinishNow)
        XCTAssertEqual(b.completedMove, move([(1, 3)]))
        XCTAssertEqual(b.selectableSourcePoints, [3])  // can also play on
    }

    func testUndoRebuildsFromScratch() {
        let bd = makeBoard([1: [.white], 5: [.white]])
        let legal = [
            move([(1, 3), (5, 8)]),
            move([(1, 4), (5, 8)]),
        ]
        let b = MoveBuilder(legalMoves: legal, board: bd)
        play(b, on: bd, 1, 3)
        play(b, on: bd, 5, 8)
        XCTAssertEqual(b.built.count, 2)

        unplay(b, on: bd, 5, 8)
        XCTAssertEqual(b.built, [hm(1, 3)])
        XCTAssertEqual(b.activeMoves.count, 1)
        XCTAssertEqual(b.selectableSourcePoints, [5])

        unplay(b, on: bd, 1, 3)
        XCTAssertTrue(b.built.isEmpty)
        XCTAssertEqual(b.selectableSourcePoints, [1, 5])  // back to start
    }

    func testIndependentHalfMovesAreReorderable() {
        // Two checkers on point 1: the engine stores the two-checker move
        // ([1→4, 1→6]) plus the merged single-checker [1→9]. Either independent
        // half-move may be played first, so all three destinations are offered.
        let bd = makeBoard([1: [.white, .white]])
        let legal = [
            move([(1, 4), (1, 6)]),
            move([(1, 9)]),
        ]
        let b = MoveBuilder(legalMoves: legal, board: bd)
        XCTAssertEqual(b.selectableSourcePoints, [1])
        XCTAssertEqual(b.validDestinations(for: 1), [4, 6, 9])

        // Play the die-5 half (1→6) first — impossible under stored-order logic.
        XCTAssertFalse(play(b, on: bd, 1, 6))
        XCTAssertEqual(b.activeMoves, [move([(1, 4), (1, 6)])])
        XCTAssertEqual(b.validDestinations(for: 1), [4])
        XCTAssertTrue(play(b, on: bd, 1, 4))
        XCTAssertEqual(b.completedMove, move([(1, 4), (1, 6)]))
    }

    func testChainedHalfMovesAreNotReorderable() {
        // A single-checker chain 1→3→5: the second half can't be played until the
        // first delivers a checker to point 3.
        let bd = makeBoard([1: [.white]])
        let legal = [move([(1, 3), (3, 5)])]
        let b = MoveBuilder(legalMoves: legal, board: bd)
        XCTAssertEqual(b.selectableSourcePoints, [1])     // not 3
        XCTAssertEqual(b.validDestinations(for: 1), [3, 5])  // reachable as a chain
        XCTAssertEqual(b.validDestinations(for: 3), [])    // can't start at 3

        XCTAssertFalse(play(b, on: bd, 1, 3))              // 3→5 still to play
        XCTAssertEqual(b.validDestinations(for: 3), [5])
        XCTAssertTrue(play(b, on: bd, 3, 5))               // now complete
        XCTAssertEqual(b.completedMove, move([(1, 3), (3, 5)]))
    }

    func testFalseChainInterleaveAllowsEitherOrder() {
        // Two INDEPENDENT black checkers whose ray positions coincide (8 and 6),
        // die = 2. The bag is chain-shaped ([8→6, 6→4]) but the board proves the
        // checkers are independent: the old board-blind logic wrongly locked 6 out.
        let bd = makeBoard([8: [.black], 6: [.black]])
        let legal = [move([(8, 6), (6, 4)], .black)]
        let b = MoveBuilder(legalMoves: legal, board: bd)

        // Bug #1: both sources offered up front (board-blind logic hid 6).
        XCTAssertEqual(b.selectableSourcePoints, [8, 6])

        // Bug #2: play 6→4 first, then 8 is still playable.
        XCTAssertFalse(play(b, on: bd, 6, 4, .black))
        XCTAssertEqual(b.selectableSourcePoints, [8])
        XCTAssertTrue(play(b, on: bd, 8, 6, .black))
        XCTAssertEqual(b.completedMove, move([(8, 6), (6, 4)], .black))
    }

    func testNonPaschMergedMoveUnmergesIntoContinuableHops() {
        // Lone white checker, dice 3·5 — the engine stores the single-checker move
        // merged (1→9). The builder unmerges it so both intermediate stops and the
        // far endpoint highlight, and the same checker can continue from a stop.
        let bd = makeBoard([1: [.white]])
        let legal = [move([(1, 9)])]
        let b = MoveBuilder(legalMoves: legal, board: bd, die1: 3, die2: 5)

        XCTAssertEqual(b.selectableSourcePoints, [1])
        XCTAssertEqual(b.validDestinations(for: 1), [4, 6, 9])  // both stops + endpoint
        XCTAssertEqual(b.path(from: 1, to: 9).count, 2)         // two single-die hops

        // Stop on the die-3 intermediate, then continue the same checker with die 5.
        XCTAssertFalse(play(b, on: bd, 1, 4))
        XCTAssertEqual(b.selectableSourcePoints, [4])           // same checker continues
        XCTAssertEqual(b.validDestinations(for: 4), [9])
        XCTAssertTrue(play(b, on: bd, 4, 9))
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

    /// Pasch: selecting a checker highlights the full reachable ray and a tap on the
    /// far endpoint commits every intervening hop, consuming all four dice.
    func testPaschMultiHopHighlightsRayAndCommitsChain() {
        let s = GameSession(startingPlayer: .white)
        let b = s.game.board
        for i in 0...(b.boardSize + 1) { b.setPoint(i, pieces: []) }
        b.setPoint(1, pieces: [.white])
        b.setPoint(24, pieces: [.black])    // keep both colors on the board

        s.setManualDice(2, 2)
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.selectableSources, [1])
        s.selectPoint(1)
        XCTAssertEqual(s.validTargets, [3, 5, 7, 9])   // whole ray highlighted

        s.commitHalfMove(from: 1, to: 9)               // tap the far endpoint
        XCTAssertEqual(s.moveBuilder.built.count, 4)   // four dice consumed
        XCTAssertEqual(b.points[1].count, 0)
        XCTAssertEqual(b.points[9].count, 1)
        XCTAssertEqual(s.currentPlayer, .black)        // turn finished
    }

    /// Pasch: two independent checkers may be played in any interleaving — A, B,
    /// back to A, B — reproducing issue #44's forced-ordering and lock-out bugs.
    func testPaschInterleavesSourcesAcrossPoints() {
        let s = GameSession(startingPlayer: .white)
        let b = s.game.board
        for i in 0...(b.boardSize + 1) { b.setPoint(i, pieces: []) }
        b.setPoint(1, pieces: [.white])
        b.setPoint(10, pieces: [.white])
        b.setPoint(24, pieces: [.black])

        s.setManualDice(2, 2)
        XCTAssertEqual(s.selectableSources, [1, 10])

        // A then B: the other point must stay selectable (bug #1).
        s.selectPoint(1)
        s.commitHalfMove(from: 1, to: 3)
        XCTAssertTrue(s.selectableSources.contains(10), "other point locked out (#1)")
        XCTAssertTrue(s.selectableSources.contains(3), "moved checker should continue")

        s.selectPoint(10)
        s.commitHalfMove(from: 10, to: 12)
        // Back to A's checker (now at 3): must not be locked out (bug #2).
        XCTAssertTrue(s.selectableSources.contains(3), "first point locked out (#2)")
        s.selectPoint(3)
        s.commitHalfMove(from: 3, to: 5)

        s.selectPoint(12)
        s.commitHalfMove(from: 12, to: 14)

        XCTAssertEqual(s.currentPlayer, .black)   // all four dice consumed
        XCTAssertEqual(b.points[5].count, 1)
        XCTAssertEqual(b.points[14].count, 1)
    }

    /// Non-Pasch: a single checker playing both distinct dice may be played in two
    /// deliberate steps and continued (issue #44 follow-up). The engine merges the
    /// move, so without unmerging the same checker would be locked out after the
    /// first half.
    func testNonPaschSingleCheckerContinuesThroughSession() {
        let s = GameSession(startingPlayer: .white)
        let b = s.game.board
        for i in 0...(b.boardSize + 1) { b.setPoint(i, pieces: []) }
        b.setPoint(1, pieces: [.white])
        b.setPoint(24, pieces: [.black])

        s.setManualDice(3, 5)
        XCTAssertEqual(s.selectableSources, [1])
        s.selectPoint(1)
        XCTAssertEqual(s.validTargets, [4, 6, 9])   // stops + merged endpoint

        // Play one die, then continue the SAME checker with the other die.
        s.commitHalfMove(from: 1, to: 4)
        XCTAssertEqual(s.moveBuilder.built.count, 1)
        XCTAssertTrue(s.selectableSources.contains(4), "same checker locked out after first half")
        s.selectPoint(4)
        XCTAssertEqual(s.validTargets, [9])
        s.commitHalfMove(from: 4, to: 9)

        XCTAssertEqual(s.currentPlayer, .black)   // both dice consumed
        XCTAssertEqual(b.points[1].count, 0)
        XCTAssertEqual(b.points[9].count, 1)
    }

    /// A committed move appends one ply with the dice and played half-moves.
    /// `PlyRecord` is the persistence format (no `index`/`mover`); those are
    /// derived by the view layer from array position and `session.startingPlayer`.
    func testHistoryRecordsCommittedMove() {
        let s = GameSession(startingPlayer: .white)
        let b = s.game.board
        for i in 0...(b.boardSize + 1) { b.setPoint(i, pieces: []) }
        b.setPoint(1, pieces: [.white])
        b.setPoint(24, pieces: [.black])

        // White plays the merged single checker 1→9 (dice 3·5) as two hops.
        s.setManualDice(3, 5)
        s.commitHalfMove(from: 1, to: 4)
        s.commitHalfMove(from: 4, to: 9)

        XCTAssertEqual(s.history.count, 1)
        let ply = s.history[0]
        XCTAssertEqual(ply.die1, 3)
        XCTAssertEqual(ply.die2, 5)
        XCTAssertEqual(ply.halfMoves, [[1, 4], [4, 9]])
        // Mover and index are derived from startingPlayer + array position in the view.
        XCTAssertEqual(s.startingPlayer, .white)   // ply 0 (index 1) → startingPlayer = White
    }

    /// A forced pass records an empty `halfMoves` array; `newGame` clears the log.
    func testHistoryRecordsForcedPassAndNewGameResets() {
        let s = GameSession(startingPlayer: .white)
        let b = s.game.board
        for i in 0...(b.boardSize + 1) { b.setPoint(i, pieces: []) }
        b.setPoint(5, pieces: [.white])
        b.setPoint(6, pieces: [.black, .black])     // blocks die=1
        b.setPoint(7, pieces: [.black, .black])     // blocks die=2

        s.setManualDice(1, 2)
        XCTAssertEqual(s.history.count, 1)
        XCTAssertTrue(s.history[0].halfMoves.isEmpty)   // pass = empty halfMoves
        XCTAssertEqual(s.history[0].die1, 1)
        XCTAssertEqual(s.history[0].die2, 2)

        s.newGame(startingPlayer: .black)
        XCTAssertTrue(s.history.isEmpty)
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

// ── Decision-point undo (#59) ──────────────────────────────────────────────────

@MainActor
final class GameSessionUndoTests: XCTestCase {
    /// Replay the first surviving legal move through the intents, finishing the
    /// human's turn (and triggering the AI's auto-reply when a side is the AI).
    private func playFirstMove(_ s: GameSession) {
        guard let chosen = s.moveBuilder.activeMoves.first else { return }
        while s.phase == .picking || s.phase == .moving {
            let idx = s.moveBuilder.built.count
            guard idx < chosen.halfMoves.count else { break }
            let h = chosen.halfMoves[idx]
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
    }

    /// One human decision + the AI's reply rewinds back to the human's pre-move
    /// position with the original dice restored. (No model → the AI plays a random
    /// legal move synchronously; undo reverses whatever it did, so the assertion on
    /// the restored position holds regardless of the AI's choice.)
    func testUndoStepsBackHumanDecisionRestoringBoardAndDice() {
        let s = GameSession(startingPlayer: .black, aiColor: .white)  // human = Black, opens
        s.start()
        XCTAssertEqual(s.currentPlayer, .black)
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertFalse(s.canUndo, "nothing to rewind before the first move")

        let start = signature(s.game.board)
        s.setManualDice(3, 5)
        XCTAssertEqual(s.phase, .picking)
        playFirstMove(s)

        // The AI (Black's opponent) has already replied — it's the human's turn again.
        XCTAssertEqual(s.currentPlayer, .black)
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertFalse(s.canUndo, "no half-moves in progress between turns")
        XCTAssertTrue(s.canUndoLastDecision)

        s.undoLastDecision()
        XCTAssertEqual(signature(s.game.board), start, "board restored to before the human move")
        XCTAssertEqual(s.currentPlayer, .black)
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.game.dice.die1.value, 3, "the ply's dice are restored")
        XCTAssertEqual(s.game.dice.die2.value, 5)
        XCTAssertFalse(s.legalMoves.isEmpty)
    }

    /// When the AI opens and the human hasn't moved, there is no decision to rewind —
    /// undo is disabled and a no-op.
    func testUndoDisabledWhenAIOpenedAndHumanHasNotMoved() {
        let s = GameSession(startingPlayer: .black, aiColor: .black)  // AI = Black, opens
        s.start()
        XCTAssertEqual(s.currentPlayer, .white)                       // human = White, to move
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertFalse(s.canUndo)
        XCTAssertFalse(s.canUndoLastDecision)

        let sig = signature(s.game.board)
        s.undo()                                                      // no-op
        XCTAssertEqual(signature(s.game.board), sig)
        XCTAssertEqual(s.currentPlayer, .white)
        XCTAssertEqual(s.phase, .awaitingRoll)
    }

    /// Two human decisions, then two sequential undos, walk all the way back to the
    /// opening position; once there, undo is disabled again.
    func testMultipleSequentialUndos() {
        let s = GameSession(startingPlayer: .black, aiColor: .white)  // human = Black, opens
        s.start()
        let start = signature(s.game.board)

        s.setManualDice(3, 5)
        playFirstMove(s)
        XCTAssertTrue(s.canUndoLastDecision)
        let afterFirst = signature(s.game.board)                      // decision 1 + AI reply

        s.setManualDice(1, 2)                                         // Black at 24 always has 24→23/24→22
        playFirstMove(s)
        XCTAssertTrue(s.canUndoLastDecision, "second decision should be rewindable")

        s.undoLastDecision()                                          // back to decision 2's start
        XCTAssertEqual(signature(s.game.board), afterFirst)
        XCTAssertEqual(s.currentPlayer, .black)
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.game.dice.die1.value, 1)
        XCTAssertEqual(s.game.dice.die2.value, 2)

        s.undoLastDecision()                                          // back to the opening
        XCTAssertEqual(signature(s.game.board), start)
        XCTAssertEqual(s.game.dice.die1.value, 3)
        XCTAssertEqual(s.game.dice.die2.value, 5)
        XCTAssertFalse(s.canUndoLastDecision, "nothing left to rewind at the opening")
    }

    /// A move still under composition is undone one hop at a time (the unified undo's
    /// within-turn branch); the turn never finishes, so the decision-point branch is
    /// not reached.
    func testUndoUnwindsInProgressBuildBeforeSteppingBack() {
        let s = GameSession(startingPlayer: .white)                   // human-vs-human
        let b = s.game.board
        for i in 0...(b.boardSize + 1) { b.setPoint(i, pieces: []) }
        b.setPoint(1, pieces: [.white])                              // lone checker walks the Pasch ray
        b.setPoint(24, pieces: [.black])                            // keep both colors on the board
        s.setManualDice(2, 2)                                        // 1→3→5→7→9

        let start = signature(b)
        s.selectPoint(1)
        s.commitHalfMove(from: 1, to: 5)                            // two of four hops — turn unfinished
        XCTAssertEqual(s.moveBuilder.built.count, 2)
        XCTAssertEqual(s.phase, .picking)

        while !s.moveBuilder.built.isEmpty { s.undo() }             // peel each hop
        XCTAssertEqual(signature(b), start, "in-progress build fully unwound")
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.currentPlayer, .white, "turn never finished")
    }
}
