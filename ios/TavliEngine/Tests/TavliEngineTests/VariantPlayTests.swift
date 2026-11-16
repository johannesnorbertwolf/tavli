import Foundation
import XCTest
@testable import TavliEngine

/// Shared-engine behaviour under the non-Plakoto variants (#137-#139): MoveBuilder
/// composes every legal move (incl. Fevga's wrapping path, Portes bar entry/hits and
/// the merged-half split), GameSession plays whole games and ends them through the
/// variant (2-point wins, draws), saves replay to the identical position, and the
/// board's undo bookkeeping stays balanced. No fixtures or model needed.
final class VariantPlayTests: XCTestCase {
    private let newVariants: [any GameVariant] = [GameVariants.plakotoStandard, GameVariants.fevga, GameVariants.portes]

    private func checkerCount(_ board: GameBoard, _ c: Color) -> Int {
        board.points.reduce(0) { $0 + $1.countForColor(c) }
    }

    func testRegistryAndInitialPositions() {
        XCTAssertEqual(GameVariants.all.map(\.id), ["plakoto", "plakoto_standard", "fevga", "portes"])
        for v in newVariants {
            XCTAssertEqual(GameConfig(variantID: v.id).variant.id, v.id)
            let board = GameBoard(config: GameConfig(variant: v))
            board.setPoint(7, pieces: [.white, .white])          // garbage must be cleared
            v.setUpInitialPosition(on: board)
            XCTAssertEqual(checkerCount(board, .white), 15, v.id)
            XCTAssertEqual(checkerCount(board, .black), 15, v.id)
            XCTAssertFalse(v.isOver(on: board))
            XCTAssertEqual(v.maxPoints, 2)
            XCTAssertTrue(v.randomStartingPlayer)
        }
        XCTAssertEqual(GameVariants.plakoto.maxPoints, 1)
        XCTAssertFalse(GameVariants.plakoto.randomStartingPlayer)
        XCTAssertFalse(GameVariants.plakotoStandard.endsOnlyByMoverWin)
        XCTAssertTrue(GameVariants.portes.endsOnlyByMoverWin)
    }

    /// Random games where every turn is composed through `MoveBuilder` one half at a
    /// time, checking each half is offered as a source/destination and the finished
    /// position equals some legal move's result.
    func testMoveBuilderComposesEveryTurn() {
        for v in newVariants {
            var rng = SplitMix64(seed: 0xBEEF)
            for _ in 0..<4 {
                let game = Game(config: GameConfig(variant: v), startingPlayer: .white)
                var plies = 0
                while !game.isOver() && plies < 2000 {
                    plies += 1
                    let d1 = Int.random(in: 1...6, using: &rng), d2 = Int.random(in: 1...6, using: &rng)
                    game.dice.set(d1, d2)
                    let color = game.currentPlayer
                    let legal = v.legalMoves(on: game.board, color: color, dice: game.dice)
                    if !legal.isEmpty {
                        var targets = Set<String>()
                        for m in legal { v.apply(m, on: game.board); targets.insert(variantKey(game.board)); v.undo(m, on: game.board) }
                        let builder = MoveBuilder(legalMoves: legal, board: game.board, die1: d1, die2: d2)
                        let chosen = builder.activeMoves[Int.random(in: 0..<builder.activeMoves.count, using: &rng)]
                        // Every legal move can be composed in some legal play order.
                        for _ in chosen.halfMoves {
                            guard let h = nextOfferedHalf(builder, of: chosen) else {
                                XCTFail("\(v.id): no legal play order offered for \(chosen)"); break
                            }
                            let hm = HalfMove(from: game.board.points[h.from.position],
                                              to: game.board.points[h.to.position], color: color)
                            v.applyHalfMove(hm, on: game.board)
                            builder.commit(halfMove: hm)
                        }
                        XCTAssertNotNil(builder.completedMove, v.id)
                        XCTAssertTrue(targets.contains(variantKey(game.board)), "\(v.id): composed an illegal result")
                    }
                    XCTAssertEqual(checkerCount(game.board, .white), 15, v.id)
                    XCTAssertEqual(checkerCount(game.board, .black), 15, v.id)
                    game.switchTurn()
                }
                XCTAssertTrue(game.isOver(), "\(v.id): game did not finish")
            }
        }
    }

    /// The merged half of a Fevga Black checker wraps 24→1: the split must follow the
    /// path, not `src + color*die`.
    func testFevgaBlackMergedHalfSplitsAlongWrappedPath() {
        let v = GameVariants.fevga
        let board = GameBoard(config: GameConfig(variant: v))
        board.clear()
        board.setPoint(1, pieces: Array(repeating: .white, count: 15))
        board.setPoint(13, pieces: Array(repeating: .black, count: 14))
        board.setPoint(22, pieces: [.black])
        let dice = Dice()
        dice.set(5, 3)
        let legal = v.legalMoves(on: board, color: .black, dice: dice)
        XCTAssertEqual(swiftMovePairs(legal).sorted { $0.count < $1.count }, [[[22, 6]], [[22, 3], [13, 16]]])  // spec F5
        let builder = MoveBuilder(legalMoves: legal, board: board, die1: 5, die2: 3)
        XCTAssertEqual(builder.validDestinations(for: 22), [3, 6])   // via slot 3 only (slot 1 is White's)
        XCTAssertEqual(builder.path(from: 22, to: 6).map(\.to.position), [3, 6])
    }

    /// Portes: a bar checker is picked up from its bar index and a hit sends the blot to
    /// the opponent's bar; undo restores both.
    func testPortesBarEntryHitAndUndo() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [24: 14], black: [3: 14, 2: 1], whiteBar: 1, blackOff: 0)
        let dice = Dice()
        dice.set(2, 6)
        let legal = v.legalMoves(on: board, color: .white, dice: dice)
        XCTAssertFalse(legal.isEmpty)
        XCTAssertTrue(legal.allSatisfy { $0.halfMoves[0].from.position == 0 }, "bar entry first")
        XCTAssertEqual(v.movableCount(at: 0, for: .white, on: board), 1)
        let before = board.captureStacks()
        let hit = legal.first { $0.halfMoves[0].to.position == 2 }!
        v.apply(hit, on: board)
        XCTAssertEqual(PortesVariant.barCount(.black, on: board), 1)
        XCTAssertEqual(PortesVariant.barCount(.white, on: board), 0)
        v.undo(hit, on: board)
        XCTAssertEqual(board.captureStacks(), before)
        XCTAssertTrue(board.undoLog.isEmpty)
    }

    @MainActor private func playOut(_ s: GameSession, seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var turns = 0
        loop: while true {
            switch s.phase {
            case .gameOver:
                break loop
            case .awaitingRoll:
                turns += 1
                guard turns < 5000 else { XCTFail("game failed to terminate"); break loop }
                s.setManualDice(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
            case .picking, .moving:
                let moves = s.moveBuilder.activeMoves
                let chosen = moves[Int.random(in: 0..<moves.count, using: &rng)]
                while s.phase == .picking || s.phase == .moving {
                    let idx = s.moveBuilder.built.count
                    guard idx < chosen.halfMoves.count else { break }
                    guard let h = nextOfferedHalf(s.moveBuilder, of: chosen) else { XCTFail("no legal play order for \(chosen)"); break }
                    s.selectPoint(h.from.position)
                    s.commitHalfMove(from: h.from.position, to: h.to.position)
                }
            case .aiThinking, .animating:
                XCTFail("unexpected phase"); break loop
            }
        }
    }

    /// Whole human-vs-human games through `GameSession`: the end comes from the
    /// variant (`outcome` incl. points), the hooks fire once, and the save replays to
    /// the identical position and result.
    @MainActor func testSessionPlaysToVariantOutcomeAndReplays() throws {
        for v in newVariants {
            let s = GameSession(startingPlayer: .white, config: GameConfig(variant: v), animationTimings: .off)
            var finished: [(Color?, Int)] = []
            s.onGameFinished = { finished.append(($0, $1)) }
            playOut(s, seed: 0x5EED)
            guard case .gameOver(let winner) = s.phase else { return XCTFail(v.id) }
            let (w, pts) = s.game.outcome()
            XCTAssertEqual(winner, w, v.id)
            XCTAssertEqual(s.record.outcome, w)
            XCTAssertEqual(s.record.points, pts)
            XCTAssertEqual(finished.count, 1)
            XCTAssertEqual(finished.first?.1, pts)

            let data = try JSONEncoder().encode(s.snapshot(name: "x"))
            let save = try JSONDecoder().decode(GameSave.self, from: data)
            XCTAssertEqual(save.variant, v.id)
            XCTAssertEqual(save.points, pts)
            let resumed = GameSession.resume(from: save, animationTimings: .off)
            XCTAssertEqual(resumed.game.variant.id, v.id)
            XCTAssertEqual(resumed.game.board.captureStacks(), s.game.board.captureStacks(), v.id)
            XCTAssertEqual(resumed.phase, s.phase)
            XCTAssertEqual(resumed.record.points, pts)
        }
    }

    /// Standard Plakoto: pinning the second mother draws the game — `.gameOver(nil)`,
    /// `onGameOver` silent, `onGameFinished(nil, 0)`, saved as a draw.
    @MainActor func testStandardPlakotoDrawEndsSession() throws {
        let v = GameVariants.plakotoStandard
        let s = GameSession(startingPlayer: .black, config: GameConfig(variant: v), animationTimings: .off)
        let b = s.game.board
        b.clear()
        b.setPoint(1, pieces: [.white])                                   // White's mother
        b.setPoint(20, pieces: Array(repeating: .white, count: 13))
        b.setPoint(24, pieces: [.black, .white])                          // Black's mother pinned
        b.setPoint(2, pieces: [.black])
        b.setPoint(5, pieces: Array(repeating: .black, count: 13))
        var wins = 0
        var finished: [(Color?, Int)] = []
        s.onGameOver = { _ in wins += 1 }
        s.onGameFinished = { finished.append(($0, $1)) }
        s.setManualDice(1, 2)                                             // spec E5
        XCTAssertTrue(s.moveBuilder.activeMoves.contains { swiftMovePairs([$0])[0].contains([2, 1]) })
        s.selectPoint(2); s.commitHalfMove(from: 2, to: 1)
        if s.phase != .gameOver(winner: nil) { s.selectPoint(5); s.commitHalfMove(from: 5, to: 3) }
        XCTAssertEqual(s.phase, .gameOver(winner: nil))
        XCTAssertTrue(s.record.isDraw)
        XCTAssertNil(s.record.outcome)
        XCTAssertEqual(s.record.points, 0)
        XCTAssertEqual(wins, 0)
        XCTAssertEqual(finished.count, 1)
        XCTAssertNil(finished[0].0)
        let save = s.snapshot(name: "d")
        XCTAssertEqual(save.outcome, GameSave.drawOutcome)
        XCTAssertTrue(save.record.isDraw)
    }

    /// Agent terminal leaves use `terminalValue`: a gammon-winning bear-off scores 1.0,
    /// a single win 0.75 (max_points 2), with no model call needed.
    func testTerminalValueNormalizesPoints() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [:], black: [3: 15], whiteOff: 15)
        XCTAssertEqual(v.terminalValue(on: board, perspective: .white), 1.0)
        XCTAssertEqual(v.terminalValue(on: board, perspective: .black), 0.0)
        PortesVariant.setPosition(on: board, white: [:], black: [3: 14], whiteOff: 15, blackOff: 1)
        XCTAssertEqual(v.terminalValue(on: board, perspective: .white), 0.75)
        XCTAssertEqual(v.terminalValue(on: board, perspective: .black), 0.25)
        XCTAssertEqual(GameVariants.plakoto.terminalValue(on: { () -> GameBoard in
            let b = GameBoard(); b.setPoint(25, pieces: Array(repeating: .white, count: 15)); return b }(),
            perspective: .white), 1.0)
    }

    /// Legal-move generation time per call over a fixed sample of mid-game positions,
    /// per variant (printed; the performance figures in the PR come from here).
    func testLegalMoveTiming() {
        for v in [GameVariants.plakoto] + newVariants {
            var rng = SplitMix64(seed: 42)
            var positions: [(GameBoard, Color)] = []
            for _ in 0..<6 {
                let game = Game(config: GameConfig(variant: v), startingPlayer: .white)
                var plies = 0
                while !game.isOver() && plies < 400 {
                    plies += 1
                    game.dice.set(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
                    let legal = v.legalMoves(on: game.board, color: game.currentPlayer, dice: game.dice)
                    if plies % 5 == 0 {
                        let copy = GameBoard(config: game.board.config)
                        copy.restoreStacks(game.board.captureStacks())
                        positions.append((copy, game.currentPlayer))
                    }
                    if !legal.isEmpty { v.apply(legal[Int.random(in: 0..<legal.count, using: &rng)], on: game.board) }
                    game.switchTurn()
                }
            }
            let dice = Dice()
            var calls = 0, moves = 0
            let start = DispatchTime.now()
            for (board, color) in positions {
                for d1 in 1...6 { for d2 in d1...6 {
                    dice.set(d1, d2)
                    moves += v.legalMoves(on: board, color: color, dice: dice).count
                    calls += 1
                } }
            }
            let us = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1000 / Double(calls)
            print(String(format: "legalMoves timing %@: %.1f µs/call over %d calls (avg %.1f moves)",
                         v.id, us, calls, Double(moves) / Double(calls)))
        }
    }
}
