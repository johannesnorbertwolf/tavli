import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Tier-1 handicaps (#148): setup + persistence, the head-start position (pinned to the
/// Python `pip_headstart`), weighted dice / reroll maths, the session hooks, the
/// estimator, and — first — the off path: no handicap changes nothing.
@MainActor
final class HandicapTests: XCTestCase {

    // MARK: - Helpers

    private func loadAgent() throws -> Agent {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else { throw XCTSkip("PlakotoValue.mlpackage not found") }
        let compiled = try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        return Agent(model: try MLModel(contentsOf: compiled, configuration: cfg),
                     encoder: BoardEncoder(config: .standard))
    }

    /// A deterministic uniform stream.
    private func uniforms(_ values: [Double]) -> () -> Double {
        var i = 0
        return { defer { i += 1 }; return values[i % values.count] }
    }

    /// Non-empty points as "W15"-style strings, the Python fixture's shape.
    private func occupied(_ board: GameBoard) -> [Int: String] {
        var out: [Int: String] = [:]
        for (i, p) in board.points.enumerated() where !p.pieces.isEmpty {
            out[i] = (p.pieces.last == .white ? "W" : "B") + "\(p.pieces.count)"
        }
        return out
    }

    private func encodeJSON(_ save: GameSave) throws -> [String: Any] {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let data = try e.encode(save)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Off path: nothing changes

    func testNoHandicapLeavesSessionSaveAndPositionUnchanged() throws {
        let plain = GameSession(startingPlayer: .black, animationTimings: .off)
        let withNil = GameSession(startingPlayer: .black, animationTimings: .off, handicap: nil)
        let inactive = GameSession(startingPlayer: .black, animationTimings: .off,
                                   handicap: HandicapSetup())
        for s in [plain, withNil, inactive] {
            XCTAssertNil(s.handicap)
            XCTAssertNil(s.handicapAgent)
            XCTAssertNil(s.record.handicap)
            XCTAssertEqual(s.startingPlayer, .black)
            XCTAssertEqual(s.game.board.points[1].pieces.count, 15)
            XCTAssertEqual(s.game.board.points[24].pieces.count, 15)
            XCTAssertFalse(s.canReroll)
            XCTAssertFalse(s.canHint)
            let json = try encodeJSON(s.snapshot(name: "x", savedAt: Date(timeIntervalSince1970: 0)))
            XCTAssertNil(json["handicap"], "a normal save must not gain a handicap key")
            XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        }
        // Byte-identical to the pre-#148 shape: same keys as a plain record save.
        let a = try encodeJSON(plain.snapshot(name: "x", savedAt: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(Set(a.keys), ["schemaVersion", "gameId", "name", "savedAt", "startingPlayer",
                                     "history", "variant"])
        // Rolls and play are the normal synchronous path.
        plain.setDice(3, 5)
        XCTAssertEqual(plain.phase, .picking)
        XCTAssertFalse(plain.preparingDice)
    }

    func testOldSaveWithoutHandicapLoadsUnhandicapped() throws {
        let json = """
        {"schemaVersion":1,"name":"old","savedAt":"2026-01-01T00:00:00Z","startingPlayer":"W",
         "aiColor":"B","history":[],"variant":"plakoto"}
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let save = try d.decode(GameSave.self, from: Data(json.utf8))
        XCTAssertNil(save.handicap)
        let s = GameSession.resume(from: save, animationTimings: .off)
        XCTAssertNil(s.handicap)
        XCTAssertEqual(s.game.board.points[1].pieces.count, 15)
    }

    func testMalformedHandicapDecodesAsNil() throws {
        let json = """
        {"schemaVersion":1,"name":"x","savedAt":"2026-01-01T00:00:00Z","startingPlayer":"W",
         "history":[],"variant":"plakoto","handicap":{"setup":"garbage"}}
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        XCTAssertNil(try d.decode(GameSave.self, from: Data(json.utf8)).handicap)
    }

    func testOtherVariantIgnoresHandicap() {
        let setup = HandicapSetup(white: HandicapItems(headStart: 2, movesFirst: true))
        let s = GameSession(startingPlayer: .black,
                            config: GameConfig(variant: GameVariants.portes),
                            animationTimings: .off, handicap: setup)
        XCTAssertNil(s.handicap)
        XCTAssertNil(s.record.handicap)
        XCTAssertEqual(s.startingPlayer, .black)
    }

    // MARK: - Head start (parity with domain/handicap.py pip_headstart)

    /// Generated from the Python: `make_handicapped_rules([HandicapSpec("pip_headstart",
    /// m, -fav)]).initial_board(config)` for m = 0…8 (house Plakoto, 24 points, 15
    /// checkers); White's advanced checkers sit on point 7, Black's on 18.
    func testHeadStartMatchesPythonInitialBoard() {
        for m in 0...HandicapSetup.maxHeadStart {
            let w = GameBoard(config: .standard)
            HandicapSetup(white: HandicapItems(headStart: m)).setUpInitialPosition(on: w)
            var expectW: [Int: String] = [1: "W\(15 - m)", 24: "B15"]
            if m > 0 { expectW[7] = "W\(m)" }
            XCTAssertEqual(occupied(w), expectW, "White head start \(m)")

            let b = GameBoard(config: .standard)
            HandicapSetup(black: HandicapItems(headStart: m)).setUpInitialPosition(on: b)
            var expectB: [Int: String] = [1: "W15", 24: "B\(15 - m)"]
            if m > 0 { expectB[18] = "B\(m)" }
            XCTAssertEqual(occupied(b), expectB, "Black head start \(m)")
        }
    }

    func testHeadStartGameReplaysThroughReviewAndNotation() {
        let setup = HandicapSetup(white: HandicapItems(headStart: 3))
        let s = GameSession(startingPlayer: .white, animationTimings: .off, handicap: setup)
        XCTAssertEqual(s.game.board.points[7].pieces.count, 3)
        s.setDice(6, 1)
        guard let m = s.legalMoves.first(where: { $0.halfMoves.contains { $0.from.position == 7 } })
                ?? s.legalMoves.first else { return XCTFail("no move") }
        s.game.variant.apply(m, on: s.game.board)
        let after = s.game.board.captureStacks()
        s.game.variant.undo(m, on: s.game.board)
        // Replay through the record (the review/notation path) reaches the same board.
        var record = s.record
        record.plies = [PlyRecord(die1: 6, die2: 1, halfMoves: m.halfMoves.map { [$0.from.position, $0.to.position] })]
        let board = GameBoard(config: .standard)
        record.setUpInitialPosition(on: board)
        for p in record.plies[0].halfMoves {
            board.applyHalfMove(HalfMove(from: board.points[p[0]], to: board.points[p[1]], color: .white))
        }
        XCTAssertEqual(board.captureStacks(), after)
        XCTAssertEqual(MoveNotation.game(record.plies, startingPlayer: .white, config: .standard,
                                         handicap: setup).count, 1)
    }

    // MARK: - Setup / persistence

    func testSetupNormalisesAndRoundTrips() throws {
        let raw = HandicapSetup(white: HandicapItems(headStart: 12, movesFirst: true, diceTilt: -1,
                                                     rerolls: 9, hints: 9),
                                black: HandicapItems(movesFirst: true))
        let n = raw.normalized
        XCTAssertEqual(n.white.headStart, HandicapSetup.maxHeadStart)
        XCTAssertEqual(n.white.rerolls, 4)
        XCTAssertEqual(n.white.hints, 5)
        XCTAssertEqual(n.white.diceTilt, 0)
        XCTAssertFalse(n.white.movesFirst)   // both sides cancel out
        XCTAssertNil(n.forcedStarter)

        let s = HandicapSetup(black: HandicapItems(headStart: 2, movesFirst: true, diceTilt: 2,
                                                   rerolls: 3, hints: 1))
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(HandicapSetup.self, from: data), s)
        XCTAssertEqual(s.forcedStarter, .black)
        // Missing keys decode as "off".
        let partial = try JSONDecoder().decode(HandicapSetup.self,
                                               from: Data(#"{"white":{"rerolls":2}}"#.utf8))
        XCTAssertEqual(partial.white, HandicapItems(rerolls: 2))
        XCTAssertEqual(partial.black, .none)
    }

    func testSaveRoundTripRestoresSetupTokensAndStart() throws {
        let setup = HandicapSetup(black: HandicapItems(headStart: 2, movesFirst: true, rerolls: 3, hints: 2))
        let s = GameSession(startingPlayer: .white, aiColor: .white, animationTimings: .off,
                            handicap: setup)
        XCTAssertEqual(s.startingPlayer, .black, "moves first overrides the starter")
        s.handicapUniform = uniforms([0.1, 0.2, 0.7, 0.4])
        s.setDice(6, 5)
        XCTAssertTrue(s.canReroll)
        s.reroll()
        XCTAssertEqual(s.rerollsLeft(.black), 2)

        let save = s.snapshot(name: "h")
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(GameSave.self, from: e.encode(save))
        XCTAssertEqual(back.handicap?.setup, setup.normalized)
        XCTAssertEqual(back.handicap?.rerollsLeft, SideCounts(white: 0, black: 2))
        XCTAssertEqual(back.handicap?.hintsLeft, SideCounts(white: 0, black: 2))
        XCTAssertEqual(back.record.handicap, setup.normalized)

        let r = GameSession.resume(from: back, animationTimings: .off)
        XCTAssertEqual(r.handicap?.rerollsLeft[.black], 2)
        XCTAssertEqual(r.handicap?.hintsLeft[.black], 2)
        XCTAssertEqual(r.game.board.points[18].pieces.count, 2)
        XCTAssertEqual(r.game.board.points[24].pieces.count, 13)
        XCTAssertNotNil(r.pendingRoll, "the rerolled roll is the pending roll")
    }

    func testNewGameKeepsHandicapAndRefreshesTokens() {
        let setup = HandicapSetup(white: HandicapItems(headStart: 1, rerolls: 1))
        let s = GameSession(startingPlayer: .white, animationTimings: .off, handicap: setup)
        s.handicapUniform = uniforms([0.5, 0.5])
        s.setDice(2, 1)
        s.reroll()
        XCTAssertEqual(s.rerollsLeft(.white), 0)
        XCTAssertFalse(s.canReroll)
        s.newGame(startingPlayer: .white)
        XCTAssertEqual(s.rerollsLeft(.white), 1)
        XCTAssertEqual(s.game.board.points[7].pieces.count, 1)
        XCTAssertEqual(s.record.handicap, setup.normalized)
    }

    // MARK: - Weighted dice / reroll maths

    func testTiltBetaZeroIsExactlyFair() {
        let values: [Float] = (0..<21).map { Float($0) / 20 }
        let fair = HandicapDice.outcomes.map(\.p)
        XCTAssertEqual(HandicapDice.tilt(values: values, beta: 0), fair)
        XCTAssertEqual(fair.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertEqual(fair.filter { abs($0 - 1.0 / 36) < 1e-12 }.count, 6)
    }

    func testTiltFavoursHighValueRollsAndNormalises() {
        var values = [Float](repeating: 0.4, count: 21)
        values[20] = 0.9   // 6-6
        values[0] = 0.1    // 1-1
        let p = HandicapDice.tilt(values: values, beta: 4)
        XCTAssertEqual(p.reduce(0, +), 1, accuracy: 1e-12)
        XCTAssertGreaterThan(p[20], 1.0 / 36)
        XCTAssertLessThan(p[0], 1.0 / 36)
        // Ratio to fair is exp(β·Δv) relative to an untouched roll.
        XCTAssertEqual((p[20] / (1.0 / 36)) / (p[1] / (2.0 / 36)), exp(4 * 0.5), accuracy: 1e-4)
    }

    /// Parity with `domain/handicap.py` `weighted_faces` (values / uniforms / expected
    /// faces generated from the Python; β = 0 is the fair `(face(u1), face(u2))`).
    func testWeightedFacesMatchPython() {
        var values: [Float] = (0..<21).map { 0.30 + 0.02 * Float($0) }
        values[3] = 0.9
        values[10] = 0.05
        let cases: [(Double, Double, Double, Int, Int)] = [
            (0, 0.0, 0.0, 1, 1), (0, 0.13, 0.77, 1, 5), (0, 0.5, 0.5, 4, 4), (0, 0.71, 0.02, 5, 1),
            (0, 0.999, 0.999, 6, 6), (0, 0.4, 0.95, 3, 6),
            (2, 0.0, 0.0, 1, 1), (2, 0.13, 0.77, 1, 5), (2, 0.5, 0.5, 4, 5), (2, 0.71, 0.02, 5, 2),
            (2, 0.999, 0.999, 6, 6), (2, 0.4, 0.95, 4, 1),
            (16, 0.0, 0.0, 1, 1), (16, 0.13, 0.77, 1, 4), (16, 0.5, 0.5, 4, 1), (16, 0.71, 0.02, 4, 1),
            (16, 0.999, 0.999, 6, 6), (16, 0.4, 0.95, 4, 1),
        ]
        for (beta, u1, u2, d1, d2) in cases {
            let f = HandicapDice.weightedFaces(u1: u1, u2: u2, values: values, beta: beta)
            XCTAssertTrue(f == (d1, d2), "β=\(beta) u=(\(u1),\(u2)): got \(f), want (\(d1),\(d2))")
        }
        // tilted_roll_probs(values, 4), first entries from the Python.
        let p = HandicapDice.tilt(values: values, beta: 4)
        XCTAssertEqual(p[0], 0.009699390972958324, accuracy: 1e-6)
        XCTAssertEqual(p[3], 0.2138361949594452, accuracy: 1e-6)
        XCTAssertEqual(p[10], 0.007136413061670484, accuracy: 1e-6)
    }

    func testRerollRule() {
        var values = [Float](repeating: 0.5, count: 21)
        values[HandicapDice.outcomeIndex(2, 1)!] = 0.40
        values[HandicapDice.outcomeIndex(6, 6)!] = 0.49
        XCTAssertTrue(HandicapDice.shouldReroll(values: values, d1: 1, d2: 2))
        XCTAssertFalse(HandicapDice.shouldReroll(values: values, d1: 6, d2: 6), "within the 0.02 margin")
        XCTAssertFalse(HandicapDice.shouldReroll(values: values, d1: 5, d2: 3))
        // With weighted dice the expectation is over the side's own tilted roll: a high
        // tilt towards 6-6 raises E so 6-6's neighbours become reroll candidates.
        values[HandicapDice.outcomeIndex(6, 6)!] = 0.9
        XCTAssertFalse(HandicapDice.shouldReroll(values: values, d1: 5, d2: 3, beta: 0))
        XCTAssertTrue(HandicapDice.shouldReroll(values: values, d1: 5, d2: 3, beta: 16))
    }

    // MARK: - Session: rerolls and hints

    func testHumanRerollTakesBackBuiltHalfAndDrawsFromUniforms() {
        let s = GameSession(startingPlayer: .white, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(rerolls: 2)))
        s.setDice(3, 5)
        let h = s.moveBuilder.activeMoves.first!.halfMoves.first!
        s.selectPoint(h.from.position)
        s.commitHalfMove(from: h.from.position, to: h.to.position)
        // 6-6 is the last fair slot.
        s.handicapUniform = uniforms([0.99, 0.95])   // face(u) = 6, 6
        s.reroll()
        XCTAssertEqual(s.game.dice.die1.value, 6)
        XCTAssertEqual(s.game.dice.die2.value, 6)
        XCTAssertEqual(s.game.board.points[1].pieces.count, 15, "the built half was taken back")
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.rerollsLeft(.white), 1)
        XCTAssertEqual(s.pendingRoll, PendingRoll(die1: 6, die2: 6))
    }

    func testComputerSideCannotUseHumanButtons() {
        let s = GameSession(startingPlayer: .white, aiColor: .white, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(rerolls: 2, hints: 2)))
        XCTAssertFalse(s.canReroll)
        XCTAssertFalse(s.canHint)
    }

    func testHintShowsBestMoveWithoutPlayingIt() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .white, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(hints: 1)),
                            handicapAgent: agent)
        s.setDice(6, 4)
        let before = s.game.board.captureStacks()
        XCTAssertTrue(s.canHint)
        s.requestHint()
        await s.awaitHintForTesting()
        let hint = try XCTUnwrap(s.hint)
        XCTAssertEqual(s.game.board.captureStacks(), before, "the hint is not played")
        XCTAssertEqual(s.hintsLeft(.white), 0)
        XCTAssertFalse(s.canHint)
        // The hint is a legal move at this position.
        let legal = s.legalMoves.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } }
        XCTAssertTrue(legal.contains(hint))
        // Moving a checker clears it.
        let h = s.moveBuilder.activeMoves.first!.halfMoves.first!
        s.selectPoint(h.from.position)
        s.commitHalfMove(from: h.from.position, to: h.to.position)
        XCTAssertNil(s.hint)
    }

    func testWeightedRollDrawsFromTiltedDistribution() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .white, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(diceTilt: 8)),
                            handicapAgent: agent)
        // Expected roll for u = 0.5 under the same tilt, computed independently.
        let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .white)
        let probs = HandicapDice.tilt(values: values, beta: 8)
        let expected = HandicapDice.weightedFaces(u1: 0.5, u2: 0.1, values: values, beta: 8)
        s.handicapUniform = uniforms([0.5, 0.1])
        s.roll()
        XCTAssertTrue(s.preparingDice)
        await s.awaitDiceForTesting()
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.game.dice.die1.value, expected.0)
        XCTAssertEqual(s.game.dice.die2.value, expected.1)
        // The tilt really moved mass towards the better rolls.
        let fairEV = HandicapDice.expectedValue(values)
        let tiltedEV = zip(probs, values).reduce(0.0) { $0 + $1.0 * Double($1.1) }
        XCTAssertGreaterThan(tiltedEV, Double(fairEV))
    }

    func testComputerRerollsBadRollsWithinItsTokens() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                            handicap: HandicapSetup(black: HandicapItems(rerolls: 4)))
        // An exact-die bear-off where the roll decides a lot: Black has checkers on its
        // 6 and 5 points (13 off), White one checker 6 pips from home (14 off).
        let b = s.game.board
        for i in b.points.indices { b.setPoint(i, pieces: []) }
        b.setPoint(0, pieces: Array(repeating: .black, count: 13))
        b.setPoint(6, pieces: [.black])
        b.setPoint(5, pieces: [.black])
        b.setPoint(25, pieces: Array(repeating: .white, count: 14))
        b.setPoint(19, pieces: [.white])
        let values = try HandicapDice.rollValues(agent: agent, board: s.game.board, color: .black)
        // Find the worst roll; force it first, then the best.
        let worst = values.indices.min { values[$0] < values[$1] }!
        let best = values.indices.max { values[$0] < values[$1] }!
        // Fair uniforms that produce a given roll: u1 picks die 1, u2 die 2.
        func u(_ d: Int) -> Double { (Double(d) - 0.5) / 6 }
        let w = HandicapDice.outcomes[worst], bst = HandicapDice.outcomes[best]
        XCTAssertTrue(HandicapDice.shouldReroll(values: values, d1: HandicapDice.outcomes[worst].d1,
                                                d2: HandicapDice.outcomes[worst].d2))
        s.handicapUniform = uniforms([u(w.d1), u(w.d2), u(bst.d1), u(bst.d2)])
        s.start()
        while s.phase == .aiThinking || s.preparingDice { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(s.rerollsLeft(.black), 3)
        XCTAssertEqual(s.lastComputerReroll, .black)
        let ply = try XCTUnwrap(s.history.first)
        XCTAssertEqual(HandicapDice.outcomeIndex(ply.die1, ply.die2), best)
    }

    // MARK: - Estimator

    func testEstimateIsEvenWithoutHandicapAndMovesWithHeadStart() throws {
        let agent = try loadAgent()
        let even = try HandicapEstimator.positionWhiteWinChance(setup: HandicapSetup(), agent: agent,
                                                                rule: .rollOff)
        XCTAssertEqual(even, 0.5, accuracy: 1e-5)
        let ahead = try HandicapEstimator.positionWhiteWinChance(
            setup: HandicapSetup(white: HandicapItems(headStart: 4)), agent: agent, rule: .rollOff)
        XCTAssertGreaterThan(ahead, 0.5)
        let first = try HandicapEstimator.positionWhiteWinChance(
            setup: HandicapSetup(white: HandicapItems(movesFirst: true)), agent: agent, rule: .rollOff)
        let fixed = try HandicapEstimator.positionWhiteWinChance(
            setup: HandicapSetup(), agent: agent, rule: .fixed(.white))
        XCTAssertEqual(first, fixed, accuracy: 1e-9)
    }

    func testCombineAddsLogOddsAndFlagsUnmeasured() {
        let setup = HandicapSetup(white: HandicapItems(diceTilt: 2, hints: 1),
                                  black: HandicapItems(rerolls: 2))
        let none = HandicapEstimator.combine(positionWhite: 0.6, setup: setup, table: .unmeasured)
        XCTAssertEqual(none.whiteWinChance, 0.6, accuracy: 1e-9)
        XCTAssertEqual(none.unmeasured, ["weighted_dice", "rerolls"])
        XCTAssertTrue(none.approximate)

        let table = HandicapTable(cells: ["weighted_dice:2": .init(logOddsShift: 0.5),
                                          "rerolls:2": .init(logOddsShift: 0.2)])
        let both = HandicapEstimator.combine(positionWhite: 0.5, setup: setup, table: table)
        XCTAssertEqual(both.whiteWinChance, 1 / (1 + exp(-(0.5 - 0.2))), accuracy: 1e-9)
        XCTAssertTrue(both.unmeasured.isEmpty)

        // A measured combo cell on one side wins over the sum of its singles.
        let one = HandicapSetup(white: HandicapItems(diceTilt: 4, rerolls: 1))
        let combo = HandicapTable(cells: ["weighted_dice:4": .init(logOddsShift: 0.3),
                                          "rerolls:1": .init(logOddsShift: 0.1),
                                          "rerolls:1+weighted_dice:4": .init(logOddsShift: 0.35)])
        XCTAssertEqual(HandicapEstimator.combine(positionWhite: 0.5, setup: one, table: combo).whiteWinChance,
                       1 / (1 + exp(-0.35)), accuracy: 1e-9)
    }

    /// Every step the app offers has a measured, positive and monotone shift (E1).
    func testBundledTableCoversEveryAppStep() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TavliApp/TavliApp/Resources/HandicapTable.json")
        let table = try XCTUnwrap(HandicapTable.decode(try Data(contentsOf: url)))
        var last = 0.0
        for beta in HandicapSetup.diceTiltSteps where beta > 0 {
            let cell = try XCTUnwrap(table.cells[HandicapTable.label("weighted_dice", beta)])
            let shift = try XCTUnwrap(cell.logOddsShift)
            XCTAssertGreaterThan(shift, last, "weighted dice β \(beta)")
            last = shift
        }
        last = 0
        for n in 1...HandicapSetup.maxRerolls {
            let cell = try XCTUnwrap(table.cells[HandicapTable.label("rerolls", Double(n))])
            let shift = try XCTUnwrap(cell.logOddsShift)
            XCTAssertGreaterThan(shift, last, "rerolls \(n)")
            last = shift
        }
    }

    /// A head start amplifies the same side's dice levers (E1 head start × dice combos).
    func testHeadStartAmplifiesDiceShift() {
        let table = HandicapTable(cells: ["rerolls:2": .init(logOddsShift: 0.3)])
        let plain = HandicapEstimator.combine(positionWhite: 0.5,
                                              setup: HandicapSetup(white: HandicapItems(rerolls: 2)),
                                              table: table)
        let withHS = HandicapEstimator.combine(positionWhite: 0.5,
                                               setup: HandicapSetup(white: HandicapItems(headStart: 4, rerolls: 2)),
                                               table: table)
        XCTAssertEqual(plain.whiteWinChance, 1 / (1 + exp(-0.3)), accuracy: 1e-9)
        XCTAssertEqual(withHS.whiteWinChance, 1 / (1 + exp(-0.3 * 1.4)), accuracy: 1e-9)
    }
}

@MainActor
final class HandicapStatsTests: XCTestCase {
    func testHandicapGamesAreKeptOutOfTheRecord() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hstats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HumanStatsStore(store: HumanGameLogStore(fileURL: url))
        store.record(humanWon: true)
        store.record(humanWon: false, handicap: HandicapSetup(white: HandicapItems(headStart: 2)))
        store.record(humanWon: true, handicap: HandicapSetup(black: HandicapItems(rerolls: 1)))
        XCTAssertEqual(store.stats.total, 1)
        XCTAssertEqual(store.stats.wins, 1)
        XCTAssertEqual(store.handicapStats.total, 2)
        XCTAssertEqual(store.handicapStats.wins, 1)
        // A plain record is written without a handicap key (unchanged file shape).
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\"handicap\"").count - 1, 2)
        // Reloads.
        let again = HumanStatsStore(store: HumanGameLogStore(fileURL: url))
        XCTAssertEqual(again.handicapStats.total, 2)
        XCTAssertEqual(again.stats.total, 1)
    }

    func testNoHandicapGamesMeansEmptyBlock() {
        XCTAssertEqual(HumanGameStats(records: [HumanGameRecord(date: Date(), humanWon: true)]).total, 1)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hstats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HumanStatsStore(store: HumanGameLogStore(fileURL: url))
        store.record(humanWon: true)
        XCTAssertEqual(store.handicapStats.total, 0)
    }
}

/// Best-of-three handicap matches and the follow-up fixes (#148): moves first each game,
/// fresh tokens per game, stats routing, undo across a reroll, the reroll tumble, and the
/// restored computer roll's reroll decision.
@MainActor
final class HandicapMatchTests: XCTestCase {

    private func uniforms(_ values: [Double]) -> () -> Double {
        var i = 0
        return { defer { i += 1 }; return values[i % values.count] }
    }

    private func loadAgent() throws -> Agent {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else { throw XCTSkip("PlakotoValue.mlpackage not found") }
        let compiled = try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        return Agent(model: try MLModel(contentsOf: compiled, configuration: cfg),
                     encoder: BoardEncoder(config: .standard))
    }

    /// Play the first legal move for the human on move.
    private func playFirstMove(_ s: GameSession) {
        guard let chosen = s.moveBuilder.activeMoves.first else { return }
        while s.phase == .picking || s.phase == .moving {
            guard let h = nextOfferedHalf(s.moveBuilder, of: chosen) else { return }
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
    }

    func testMovesFirstOverridesTheAlternatingStarterEveryGame() {
        let setup = HandicapSetup(black: HandicapItems(movesFirst: true, rerolls: 2, hints: 1))
        var match = MatchState.bestOfThree(baseStartingPlayer: .white)
        var starters: [Color] = []
        for winner in [Color.white, .black, .white] {
            let starter = HandicapSetup.startingPlayer(for: setup, default: match.currentStartingPlayer)
            let s = GameSession(startingPlayer: starter, aiColor: .white, animationTimings: .off,
                                handicap: setup)
            starters.append(s.startingPlayer)
            // Fresh tokens every game of the match.
            XCTAssertEqual(s.rerollsLeft(.black), 2)
            XCTAssertEqual(s.hintsLeft(.black), 1)
            match.recordGame(winner: winner)
        }
        XCTAssertEqual(starters, [.black, .black, .black])
        // Without the handicap the match alternates as before.
        var plain = MatchState.bestOfThree(baseStartingPlayer: .white)
        var alternating: [Color] = []
        for winner in [Color.white, .black] {
            alternating.append(HandicapSetup.startingPlayer(for: nil, default: plain.currentStartingPlayer))
            plain.recordGame(winner: winner)
        }
        XCTAssertEqual(alternating, [.white, .black])
    }

    func testEveryGameOfAHandicapMatchGoesToTheHandicapRecord() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hmatch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HumanStatsStore(store: HumanGameLogStore(fileURL: url))
        let setup = HandicapSetup(white: HandicapItems(headStart: 2))
        for won in [true, false, true] {
            let s = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                                handicap: setup)
            // RootView's game-over hook: record with the game's own setup.
            store.record(humanWon: won, handicap: s.record.handicap)
        }
        XCTAssertEqual(store.stats.total, 0, "a handicap match never touches the vs-Computer record")
        XCTAssertEqual(store.handicapStats.total, 3)
        XCTAssertEqual(store.handicapStats.wins, 2)
    }

    func testUndoAcrossARerollReplaysTheSameDice() {
        // vs a random-fallback computer (no model), animation off: everything synchronous.
        let s = GameSession(startingPlayer: .white, aiColor: .black, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(rerolls: 1)))
        s.handicapUniform = uniforms([0.99, 0.95])     // the reroll → 6-6
        s.setDice(2, 1)
        s.reroll()
        XCTAssertEqual(s.pendingRoll, PendingRoll(die1: 6, die2: 6))
        playFirstMove(s)
        // The computer rolled and played; the human now awaits a roll.
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertEqual(s.history.count, 2)
        let firstWhite = s.history[0], firstBlack = s.history[1]
        XCTAssertEqual([firstWhite.die1, firstWhite.die2], [6, 6])

        s.undoLastDecision()
        // Back at the human's decision with the rerolled dice, no reroll refunded.
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual([s.game.dice.die1.value, s.game.dice.die2.value], [6, 6])
        XCTAssertEqual(s.rerollsLeft(.white), 0)
        playFirstMove(s)
        // The computer's turn replays its recorded roll.
        XCTAssertEqual(s.history.count, 2)
        XCTAssertEqual([s.history[1].die1, s.history[1].die2], [firstBlack.die1, firstBlack.die2])
    }

    func testHumanRerollTumblesWithTheRollAnimation() async throws {
        let s = GameSession(startingPlayer: .white,
                            animationTimings: AnimationTimings(aiDiceRollDuration: 0.05,
                                                               aiMoveAnimationDuration: 0),
                            handicap: HandicapSetup(white: HandicapItems(rerolls: 1)))
        s.handicapUniform = uniforms([0.5, 0.5])
        s.setDice(2, 1)
        s.reroll()
        XCTAssertTrue(s.humanDiceRolling, "the new dice tumble")
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertEqual(s.pendingRoll, PendingRoll(die1: 4, die2: 4))
        while s.phase != .picking { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(s.humanDiceRolling)
        XCTAssertEqual(s.rerollsLeft(.white), 0)
    }

    func testRestoredComputerRollGetsItsRerollDecision() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1), animationTimings: .off,
                            handicap: HandicapSetup(black: HandicapItems(rerolls: 2)))
        // The exact-die bear-off from the live-reroll test, with the worst roll restored.
        let b = s.game.board
        for i in b.points.indices { b.setPoint(i, pieces: []) }
        b.setPoint(0, pieces: Array(repeating: .black, count: 13))
        b.setPoint(6, pieces: [.black])
        b.setPoint(5, pieces: [.black])
        b.setPoint(25, pieces: Array(repeating: .white, count: 14))
        b.setPoint(19, pieces: [.white])
        let values = try HandicapDice.rollValues(agent: agent, board: b, color: .black)
        let worst = HandicapDice.outcomes[values.indices.min { values[$0] < values[$1] }!]
        let best = HandicapDice.outcomes[values.indices.max { values[$0] < values[$1] }!]
        func u(_ d: Int) -> Double { (Double(d) - 0.5) / 6 }
        s.handicapUniform = uniforms([u(best.d1), u(best.d2)])
        s.restorePendingRollForTesting(PendingRoll(die1: worst.d1, die2: worst.d2))
        s.start()
        while s.phase == .aiThinking || s.preparingDice { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(s.rerollsLeft(.black), 1)
        XCTAssertEqual(s.lastComputerReroll, .black)
        let ply = try XCTUnwrap(s.history.first)
        XCTAssertEqual(HandicapDice.outcomeIndex(ply.die1, ply.die2),
                       HandicapDice.outcomeIndex(best.d1, best.d2))
    }

    func testRestoredComputerRollWithoutRerollsPlaysAsBefore() async throws {
        // No tokens → the plain restored path (no rating, dice unchanged).
        let s = GameSession(startingPlayer: .black, aiColor: .black, animationTimings: .off,
                            handicap: HandicapSetup(white: HandicapItems(headStart: 1)))
        s.restorePendingRollForTesting(PendingRoll(die1: 3, die2: 5))
        s.start()
        XCTAssertEqual(s.history.first.map { [$0.die1, $0.die2] }, [3, 5])
        XCTAssertNil(s.lastComputerReroll)
    }
}
