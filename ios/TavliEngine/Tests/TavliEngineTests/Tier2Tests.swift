import Foundation
import XCTest
@testable import TavliEngine

/// Tier-2 handicaps (#148 P3b): the rule port pinned to `domain/handicap_moves.py`
/// (`Tier2Fixtures/tier2_moves.json`, from `ios/scripts/make_tier2_fixtures.py`), the
/// off path, the start position, the win rule, the encoder cap, playability through
/// `MoveBuilder`, the estimator's table mapping, and the session/save/review plumbing.
@MainActor
final class Tier2Tests: XCTestCase {

    // MARK: - Fixture

    private struct Fixture: Decodable {
        struct Side: Decodable { let overshoot: Bool; let safePoint: Int; let checkers: Int; let homeSize: Int }
        struct Rules: Decodable { let white: Side; let black: Side }
        struct Won: Decodable { let white: Bool; let black: Bool }
        struct Case: Decodable {
            let rules: Rules
            let stacks: [String]
            let mover: String
            let dice: [Int]
            let results: [String]
            let won: Won
        }
        let cases: [Case]
    }

    private static let fixture: Fixture? = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Tier2Fixtures/tier2_moves.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Fixture.self, from: data)
    }()

    private func rules(_ r: Fixture.Rules) -> HandicapRules {
        func side(_ s: Fixture.Side) -> SideRules {
            SideRules(overshoot: s.overshoot, safePoint: s.safePoint, checkers: s.checkers, homeSize: s.homeSize)
        }
        return HandicapRules(white: side(r.white), black: side(r.black))
    }

    private func board(_ c: Fixture.Case) -> GameBoard {
        let b = GameBoard(config: GameConfig.standard.withHandicapRules(rules(c.rules)))
        for (i, s) in c.stacks.enumerated() {
            b.setPoint(i, pieces: s.map { $0 == "W" ? Color.white : Color.black })
        }
        return b
    }

    private func stacks(_ b: GameBoard) -> [String] {
        b.points.map { String($0.pieces.map { $0.isWhite ? "W" : "B" }) }
    }

    /// Changed points after a move, in the fixture's `i:stack;…` form.
    private func diffKey(_ before: [String], _ after: [String]) -> String {
        after.indices.filter { after[$0] != before[$0] }.map { "\($0):\(after[$0])" }.joined(separator: ";")
    }

    private func resultSet(_ b: GameBoard, _ moves: [Move]) -> Set<String> {
        let before = stacks(b)
        var out = Set<String>()
        for m in moves {
            let snap = b.captureSnapshot()
            b.variant.apply(m, on: b)
            out.insert(diffKey(before, stacks(b)))
            b.restore(snap)
        }
        return out
    }

    // MARK: - Python parity

    func testLegalMovesMatchPythonTier2Generator() throws {
        let fx = try XCTUnwrap(Self.fixture, "Tier2Fixtures/tier2_moves.json missing")
        XCTAssertGreaterThan(fx.cases.count, 500)
        var overshootBearOffs = 0
        for (k, c) in fx.cases.enumerated() {
            let b = board(c)
            let mover: Color = c.mover == "W" ? .white : .black
            let dice = Dice()
            dice.set(c.dice[0], c.dice[1])
            let before = stacks(b)
            let moves = b.variant.legalMoves(on: b, color: mover, dice: dice)
            XCTAssertEqual(stacks(b), before, "case \(k): generator mutated the board")
            let got = resultSet(b, moves)
            XCTAssertEqual(got, Set(c.results), "case \(k) \(c.mover) \(c.dice) rules \(c.rules)")
            XCTAssertEqual(b.variant.hasWon(.white, on: b), c.won.white, "case \(k) white won")
            XCTAssertEqual(b.variant.hasWon(.black, on: b), c.won.black, "case \(k) black won")
            if rules(c.rules)[mover].overshoot, c.results.contains(where: { $0.contains(mover.isWhite ? "25:" : "0:") }) {
                overshootBearOffs += 1
            }
        }
        XCTAssertGreaterThan(overshootBearOffs, 100, "fixture covers overshoot bear-offs")
    }

    /// Every legal move can be played in the UI: exploring `MoveBuilder` gesture by gesture
    /// (sources, destinations, multi-hop paths, legal play order) reaches exactly the legal
    /// moves' resulting positions.
    func testMoveBuilderReachesExactlyTheLegalPositions() throws {
        let fx = try XCTUnwrap(Self.fixture)
        for (k, c) in fx.cases.enumerated() where k % 4 == 0 {
            let b = board(c)
            let mover: Color = c.mover == "W" ? .white : .black
            let dice = Dice()
            dice.set(c.dice[0], c.dice[1])
            let moves = b.variant.legalMoves(on: b, color: mover, dice: dice)
            guard !moves.isEmpty else { continue }
            let before = stacks(b)
            let builder = MoveBuilder(legalMoves: moves, board: b, die1: c.dice[0], die2: c.dice[1])
            var reached = Set<String>()
            explore(builder, b, before, &reached, depth: 0)
            XCTAssertEqual(reached, resultSet(b, moves), "case \(k) \(c.mover) \(c.dice) rules \(c.rules)")
            XCTAssertEqual(stacks(b), before)
        }
    }

    private func explore(_ builder: MoveBuilder, _ b: GameBoard, _ before: [String],
                         _ reached: inout Set<String>, depth: Int) {
        if builder.canFinishNow { reached.insert(diffKey(before, stacks(b))) }
        guard depth < 4 else { return }
        for src in builder.selectableSourcePoints.sorted() {
            for dst in builder.validDestinations(for: src).sorted() {
                let hops = builder.path(from: src, to: dst)
                guard !hops.isEmpty else { continue }
                for h in hops { b.variant.applyHalfMove(h, on: b) }
                builder.commit(halfMoves: hops)
                explore(builder, b, before, &reached, depth: depth + hops.count)
                builder.undoGesture()
                for h in hops.reversed() { b.variant.undoHalfMove(h, on: b) }
            }
        }
    }

    // MARK: - Off path

    /// With every rule at its normal value the tier-2 generator plays exactly the house
    /// generator, and a setup without tier-2 items leaves the config (and so the normal
    /// generator) untouched.
    func testNormalRulesMatchTheHouseGeneratorAndTier1KeepsTheConfig() throws {
        let fx = try XCTUnwrap(Self.fixture)
        for (k, c) in fx.cases.enumerated() where k % 3 == 0 {
            let plain = GameBoard(config: .standard)
            let normal = GameBoard(config: GameConfig.standard.withHandicapRules(HandicapRules()))
            for (i, s) in c.stacks.enumerated() {
                let pieces = s.map { $0 == "W" ? Color.white : Color.black }
                plain.setPoint(i, pieces: pieces)
                normal.setPoint(i, pieces: pieces)
            }
            let mover: Color = c.mover == "W" ? .white : .black
            let dice = Dice()
            dice.set(c.dice[0], c.dice[1])
            let house = PossibleMoves(board: plain, color: mover, dice: dice).findMoves()
            XCTAssertEqual(resultSet(plain, house),
                           resultSet(normal, normal.variant.legalMoves(on: normal, color: mover, dice: dice)),
                           "case \(k)")
        }
        let tier1 = HandicapSetup(white: HandicapItems(headStart: 2, rerolls: 1))
        XCTAssertNil(tier1.rules)
        XCTAssertFalse(tier1.hasTier2)
        let s = GameSession(startingPlayer: .white, animationTimings: .off, handicap: tier1)
        XCTAssertNil(s.game.board.config.handicapRules)
        XCTAssertEqual(s.game.board.config, .standard)
        XCTAssertNil(GameSession(animationTimings: .off).game.board.config.handicapRules)
        // Older (v1) setups decode with every tier-2 item off.
        let v1 = try JSONDecoder().decode(HandicapSetup.self,
                                          from: Data(#"{"version":1,"white":{"headStart":2}}"#.utf8))
        XCTAssertEqual(v1.white, HandicapItems(headStart: 2))
        XCTAssertNil(v1.rules)
    }

    // MARK: - Setup, start, win, encoder

    func testSetupNormalisesTier2AndBuildsRules() throws {
        let raw = HandicapSetup(white: HandicapItems(overshoot: true, safePoint: 7, checkers: 20, homeSize: 1),
                                black: HandicapItems(safePoint: 6, checkers: 13, homeSize: 4))
        let n = raw.normalized
        XCTAssertEqual(n.white.safePoint, 0, "not a candidate")
        XCTAssertEqual(n.white.checkers, 17)
        XCTAssertEqual(n.white.homeSize, 3)
        let r = try XCTUnwrap(raw.rules)
        XCTAssertEqual(r.white, SideRules(overshoot: true, safePoint: 0, checkers: 17, homeSize: 3))
        XCTAssertEqual(r.black, SideRules(overshoot: false, safePoint: 6, checkers: 13, homeSize: 4))
        XCTAssertEqual(r.safeSlot(.black, boardSize: 24), 19)
        XCTAssertEqual(HandicapSetup.currentVersion, 2)
        let back = try JSONDecoder().decode(HandicapSetup.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back, n)
        XCTAssertEqual(n.tier1Only, HandicapSetup(version: n.version))
    }

    /// `tier2_board` + head start: start stacks hold each side's count minus its head start.
    func testStartPositionUsesEachSidesCheckerCount() {
        let setup = HandicapSetup(white: HandicapItems(headStart: 2, checkers: 17),
                                  black: HandicapItems(checkers: 13))
        let s = GameSession(startingPlayer: .white, animationTimings: .off, handicap: setup)
        let b = s.game.board
        XCTAssertEqual(b.points[1].pieces, Array(repeating: .white, count: 15))
        XCTAssertEqual(b.points[7].pieces, [.white, .white])
        XCTAssertEqual(b.points[24].pieces, Array(repeating: .black, count: 13))
        XCTAssertEqual(b.checkerCount(.white), 17)
        XCTAssertEqual(b.checkerCount(.black), 13)
        XCTAssertNotNil(b.config.handicapRules)
    }

    func testWinNeedsAllOwnCheckersOff() {
        let cfg = GameConfig.standard.withHandicapRules(
            HandicapRules(white: SideRules(checkers: 13), black: SideRules(checkers: 17)))
        let b = GameBoard(config: cfg)
        b.setPoint(25, pieces: Array(repeating: .white, count: 13))
        b.setPoint(0, pieces: Array(repeating: .black, count: 15))
        b.setPoint(3, pieces: [.black, .black])
        XCTAssertTrue(b.variant.hasWon(.white, on: b))
        XCTAssertFalse(b.variant.hasWon(.black, on: b), "15 of 17 off is not a win")
        b.setPoint(3, pieces: [])
        b.setPoint(0, pieces: Array(repeating: .black, count: 17))
        XCTAssertTrue(b.variant.hasWon(.black, on: b))
    }

    /// A 16/17 stack fills the 15 unary units and never spills into the next point.
    func testEncoderCapsUnaryAtFifteen() {
        let enc = BoardEncoder(config: .standard)
        let cfg = GameConfig.standard.withHandicapRules(HandicapRules(white: SideRules(checkers: 17)))
        let big = GameBoard(config: cfg)
        cfg.variant.setUpInitialPosition(on: big)
        let normal = GameBoard(config: .standard)
        GameConfig.standard.variant.setUpInitialPosition(on: normal)
        XCTAssertEqual(big.points[1].pieces.count, 17)
        let a = enc.encode(big, isWhitesTurn: true)
        let n = enc.encode(normal, isWhitesTurn: true)
        let ps = 18
        XCTAssertEqual(Array(a[0..<(26 * ps)]), Array(n[0..<(26 * ps)]), "unary part capped at 15")
        XCTAssertEqual(a.count, n.count)
    }

    func testSafePointBlocksPinningOnlyThere() {
        // White's safe point 6 (own numbering) = index 6; Black can't pin a lone White there.
        let cfg = GameConfig.standard.withHandicapRules(HandicapRules(white: SideRules(safePoint: 6)))
        let b = GameBoard(config: cfg)
        b.setPoint(6, pieces: [.white])
        b.setPoint(8, pieces: [.white])
        b.setPoint(9, pieces: [.black])
        XCTAssertFalse(b.variant.isOpen(6, for: .black, on: b))
        XCTAssertTrue(b.variant.isOpen(8, for: .black, on: b))
        XCTAssertTrue(b.variant.isOpen(9, for: .white, on: b), "Black has no safe point")
        let dice = Dice()
        dice.set(3, 1)
        let moves = b.variant.legalMoves(on: b, color: .black, dice: dice)
        XCTAssertFalse(moves.contains { $0.halfMoves.contains { $0.to.position == 6 } })
    }

    // MARK: - Estimator (signs pinned to the bundled E3 table)

    private func bundledTable() throws -> HandicapTable {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TavliApp/TavliApp/Resources/HandicapTable.json")
        return try XCTUnwrap(HandicapTable.decode(try Data(contentsOf: url)))
    }

    private func white(_ setup: HandicapSetup, _ table: HandicapTable) -> Double {
        HandicapEstimator.combine(positionWhite: 0.5, setup: setup, table: table).whiteWinChance
    }

    func testTier2EstimateSignsMatchTheMeasurements() throws {
        let t = try bundledTable()
        XCTAssertEqual(white(HandicapSetup(white: HandicapItems(overshoot: true)), t), 0.755, accuracy: 1e-3)
        XCTAssertEqual(white(HandicapSetup(black: HandicapItems(overshoot: true)), t), 0.245, accuracy: 1e-3)
        XCTAssertEqual(white(HandicapSetup(white: HandicapItems(safePoint: 6)), t), 0.533, accuracy: 1e-3)
        // Fewer checkers is a disadvantage; more is an advantage.
        XCTAssertEqual(white(HandicapSetup(white: HandicapItems(checkers: 13)), t), 0.285, accuracy: 1e-3)
        XCTAssertEqual(white(HandicapSetup(black: HandicapItems(checkers: 14)), t), 0.6265, accuracy: 1e-3)
        XCTAssertEqual(white(HandicapSetup(white: HandicapItems(checkers: 17)), t), 0.6685, accuracy: 1e-3)
        XCTAssertEqual(white(HandicapSetup(black: HandicapItems(checkers: 16)), t), 0.384, accuracy: 1e-3)
        // A smaller home hurts its own side.
        XCTAssertEqual(white(HandicapSetup(white: HandicapItems(homeSize: 3)), t), 0.2575, accuracy: 1e-3)
        XCTAssertEqual(white(HandicapSetup(black: HandicapItems(homeSize: 4)), t), 0.632, accuracy: 1e-3)
    }

    func testTier2CombosUseExactCellsInAnyOrder() throws {
        let t = try bundledTable()
        // Three levers on White (spec side Black): the measured triple, not the sum.
        let triple = HandicapSetup(white: HandicapItems(overshoot: true, safePoint: 6, checkers: 14))
        XCTAssertEqual(white(triple, t), 0.7695, accuracy: 1e-3)
        // Levers from both app sides that handicap the same colour: White overshoot +
        // Black's smaller home 4 → the measured `overshoot:1+smaller_house:4`.
        let mixed = HandicapSetup(white: HandicapItems(overshoot: true), black: HandicapItems(homeSize: 4))
        XCTAssertEqual(white(mixed, t), 0.857, accuracy: 1e-3)
        // All four (White favoured: overshoot, safe 6, Black plays 16 is not in this cell…)
        let four = HandicapSetup(white: HandicapItems(overshoot: true, safePoint: 6, checkers: 14),
                                 black: HandicapItems(homeSize: 4))
        XCTAssertEqual(white(four, t), 0.8685, accuracy: 1e-3)
        // No exact cell: singles add in log-odds.
        let pair = HandicapSetup(white: HandicapItems(overshoot: true, safePoint: 2))
        let expected = 1 / (1 + exp(-(t.cells["overshoot:1"]!.logOddsShift! + t.cells["safe_point:2"]!.logOddsShift!)))
        XCTAssertEqual(white(pair, t), expected, accuracy: 1e-9)
        // Opposite colours: each group shifts its own way.
        let both = HandicapSetup(white: HandicapItems(overshoot: true), black: HandicapItems(overshoot: true))
        XCTAssertEqual(white(both, t), 0.5, accuracy: 1e-9)
        XCTAssertTrue(HandicapEstimator.combine(positionWhite: 0.5, setup: four, table: t).unmeasured.isEmpty)
    }

    // MARK: - Session plumbing

    func testTier2GameSavesResumesAndReplays() throws {
        let setup = HandicapSetup(white: HandicapItems(overshoot: true, checkers: 16),
                                  black: HandicapItems(safePoint: 6, homeSize: 5))
        let s = GameSession(startingPlayer: .white, animationTimings: .off, handicap: setup)
        XCTAssertEqual(s.game.board.config.handicapRules, setup.rules)
        // Play a few plies with fixed dice.
        for (d1, d2) in [(6, 5), (3, 1), (4, 4), (2, 6)] {
            s.setDice(d1, d2)
            guard let chosen = s.moveBuilder.activeMoves.first else { continue }
            while s.phase == .picking || s.phase == .moving {
                guard let h = nextOfferedHalf(s.moveBuilder, of: chosen) else { break }
                s.selectPoint(h.from.position)
                s.commitHalfMove(from: h.from.position, to: h.to.position)
            }
        }
        XCTAssertFalse(s.record.plies.isEmpty)
        let save = s.snapshot(name: "t2")
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let back = try d.decode(GameSave.self, from: e.encode(save))
        XCTAssertEqual(back.record.handicap, setup.normalized)
        let r = GameSession.resume(from: back, animationTimings: .off)
        XCTAssertEqual(r.game.board.config.handicapRules, setup.rules)
        XCTAssertEqual(r.game.board.captureStacks(), s.game.board.captureStacks())
        // Replay from the record (review / notation) rebuilds the same position.
        XCTAssertEqual(s.record.replayConfig.handicapRules, setup.rules)
        let board = GameBoard(config: s.record.replayConfig)
        s.record.setUpInitialPosition(on: board)
        XCTAssertEqual(board.points[1].pieces.count, 16)
        XCTAssertEqual(MoveNotation.game(s.record.plies, startingPlayer: .white, config: .standard,
                                         handicap: setup).count, s.record.plies.count)
    }
}
