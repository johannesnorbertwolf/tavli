import XCTest
@testable import TavliEngine

/// #143 — the non-view logic behind the variant selector and per-variant board UI:
/// display mapping (Portes bar, Fevga wrap), match scoring with points and draws,
/// the online game log's draw/points fields, model-availability gating, the persisted
/// variant preference, and equity scaling.
final class VariantSelectorTests: XCTestCase {

    private func stacks(_ board: GameBoard) -> [[Color]] { board.points.map(\.pieces) }

    // ── BoardLayout: Portes bar ────────────────────────────────────────────────

    func testPortesBarCheckersMoveToBarSlotsAndTraysKeepOnlyBorneOff() {
        let board = GameBoard(config: GameConfig(variant: GameVariants.portes))
        PortesVariant.setPosition(on: board, white: [5: 2], black: [20: 1],
                                  whiteBar: 2, blackBar: 1, whiteOff: 3, blackOff: 4)
        let v = GameVariants.portes
        let display = BoardLayout.displayStacks(stacks(board), variant: v)

        XCTAssertEqual(display.count, BoardLayout.slotCount)
        XCTAssertEqual(display[0], Array(repeating: .black, count: 4), "tray 0 = Black off only")
        XCTAssertEqual(display[25], Array(repeating: .white, count: 3), "tray 25 = White off only")
        XCTAssertEqual(display[BoardLayout.whiteBarSlot], [.white, .white])
        XCTAssertEqual(display[BoardLayout.blackBarSlot], [.black])
        XCTAssertEqual(display[5], [.white, .white])

        XCTAssertEqual(BoardLayout.borneOffCount(.white, stacks: stacks(board), variant: v), 3)
        XCTAssertEqual(BoardLayout.borneOffCount(.black, stacks: stacks(board), variant: v), 4)
        XCTAssertEqual(BoardLayout.barCount(.white, stacks: stacks(board), variant: v), 2)
        XCTAssertEqual(BoardLayout.barCount(.black, stacks: stacks(board), variant: v), 1)
    }

    func testPortesBarSourcesMapToBarSlotsAndBack() {
        let v = GameVariants.portes
        XCTAssertEqual(BoardLayout.barPosition(for: .white, variant: v), 0)
        XCTAssertEqual(BoardLayout.barPosition(for: .black, variant: v), 25)
        XCTAssertEqual(BoardLayout.displaySlot(forSource: 0, variant: v), BoardLayout.whiteBarSlot)
        XCTAssertEqual(BoardLayout.displaySlot(forSource: 25, variant: v), BoardLayout.blackBarSlot)
        XCTAssertEqual(BoardLayout.displaySlot(forSource: 7, variant: v), 7)
        XCTAssertEqual(BoardLayout.sourcePosition(forDisplaySlot: BoardLayout.whiteBarSlot, variant: v), 0)
        XCTAssertEqual(BoardLayout.sourcePosition(forDisplaySlot: BoardLayout.blackBarSlot, variant: v), 25)
        XCTAssertEqual(BoardLayout.sourcePosition(forDisplaySlot: 13, variant: v), 13)
        XCTAssertNil(BoardLayout.sourcePosition(forDisplaySlot: 0, variant: v), "a tray is never a source")
        XCTAssertNil(BoardLayout.sourcePosition(forDisplaySlot: 25, variant: v))
    }

    func testPortesHitIsDetectedAsBarGrowth() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [3: 1], black: [6: 1])
        let before = BoardLayout.displayStacks(stacks(board), variant: v)
        // White 3 → 6 hits Black's blot.
        let hm = HalfMove(from: board.points[3], to: board.points[6], color: .white)
        v.applyHalfMove(hm, on: board)
        let after = BoardLayout.displayStacks(stacks(board), variant: v)

        XCTAssertEqual(after[BoardLayout.blackBarSlot], [.black])
        let hits = BoardLayout.hits(from: before, to: after)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.from, 6)
        XCTAssertEqual(hits.first?.to, BoardLayout.blackBarSlot)
        XCTAssertEqual(hits.first?.color, .black)
        // Undo shrinks the bar: no hit animation.
        v.undoHalfMove(hm, on: board)
        XCTAssertTrue(BoardLayout.hits(from: after,
                                       to: BoardLayout.displayStacks(stacks(board), variant: v)).isEmpty)
    }

    func testPortesInitialMovesFromBarReachableThroughDisplaySlot() {
        // A White checker on the bar must enter: the session's source 0 is drawn on the bar.
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [12: 14], black: [13: 15], whiteBar: 1)
        let dice = Dice(numberOfSides: 6)
        dice.set(3, 5)
        let moves = v.legalMoves(on: board, color: .white, dice: dice)
        let sources = Set(moves.flatMap { $0.halfMoves.prefix(1).map(\.from.position) })
        XCTAssertEqual(sources, [0])
        XCTAssertEqual(sources.map { BoardLayout.displaySlot(forSource: $0, variant: v) },
                       [BoardLayout.whiteBarSlot])
    }

    // ── BoardLayout: variants without a bar ────────────────────────────────────

    func testPlakotoAndFevgaDisplayIsTheEngineStacksWithEmptyBars() {
        for v in [GameVariants.plakoto, GameVariants.plakotoStandard, GameVariants.fevga] as [any GameVariant] {
            let board = GameBoard(config: GameConfig(variant: v))
            v.setUpInitialPosition(on: board)
            board.setPoint(0, pieces: [.black, .black])
            board.setPoint(25, pieces: [.white])
            let display = BoardLayout.displayStacks(stacks(board), variant: v)
            XCTAssertEqual(Array(display[0...25]), stacks(board), v.id)
            XCTAssertTrue(display[BoardLayout.whiteBarSlot].isEmpty, v.id)
            XCTAssertTrue(display[BoardLayout.blackBarSlot].isEmpty, v.id)
            XCTAssertEqual(BoardLayout.borneOffCount(.black, stacks: stacks(board), variant: v), 2, v.id)
            XCTAssertEqual(BoardLayout.borneOffCount(.white, stacks: stacks(board), variant: v), 1, v.id)
        }
    }

    func testPlakotoPinnedStackStaysMixed() {
        let v = GameVariants.plakoto
        let board = GameBoard()
        board.setPoint(13, pieces: [.black, .white, .white])
        XCTAssertEqual(BoardLayout.displayStacks(stacks(board), variant: v)[13], [.black, .white, .white])
    }

    func testFevgaBlackWrapPathAndTrays() {
        let v = GameVariants.fevga
        // Black starts on 13 and wraps 24 → 1; its home is 7–12, off tray 0.
        XCTAssertEqual(v.pathIndex(of: 13, for: .black, boardSize: 24), 1)
        XCTAssertEqual(v.pathIndex(of: 24, for: .black, boardSize: 24), 12)
        XCTAssertEqual(v.pathIndex(of: 1, for: .black, boardSize: 24), 13)
        XCTAssertEqual(v.point(atPath: 13, for: .black, boardSize: 24), 1)
        XCTAssertEqual(v.point(atPath: 24, for: .black, boardSize: 24), 12)
        XCTAssertEqual(v.bearOffPoint(for: .black, boardSize: 24), 0)
        XCTAssertEqual(v.bearOffPoint(for: .white, boardSize: 24), 25)
        // White's path is the physical order.
        XCTAssertEqual(v.pathIndex(of: 7, for: .white, boardSize: 24), 7)
        // No bar: nothing ever maps to a bar slot.
        XCTAssertNil(BoardLayout.barPosition(for: .black, variant: v))
        XCTAssertEqual(BoardLayout.displaySlot(forSource: 24, variant: v), 24)
        // Start position: both colours in their corners.
        let board = GameBoard(config: GameConfig(variant: v))
        v.setUpInitialPosition(on: board)
        XCTAssertEqual(board.points[1].pieces, Array(repeating: .white, count: 15))
        XCTAssertEqual(board.points[13].pieces, Array(repeating: .black, count: 15))
    }

    func testFevgaBlackWrapMoveTargetsFollowPath() {
        // A Black checker on 23 with a 4 lands on 3 (path 11 → 15), across the wrap.
        let v = GameVariants.fevga
        let board = GameBoard(config: GameConfig(variant: v))
        board.clear()
        board.setPoint(23, pieces: [.black])
        board.setPoint(13, pieces: Array(repeating: .black, count: 14))
        board.setPoint(1, pieces: Array(repeating: .white, count: 15))
        let dice = Dice(numberOfSides: 6)
        dice.set(4, 4)
        let builder = MoveBuilder(legalMoves: v.legalMoves(on: board, color: .black, dice: dice),
                                  board: board, die1: 4, die2: 4)
        XCTAssertTrue(builder.validDestinations(for: 23).contains(3))
    }

    // ── MatchState: points and draws ──────────────────────────────────────────

    func testDoubleGameDecidesFirstToTwoMatch() {
        var m = MatchState.bestOfThree(baseStartingPlayer: .white)
        m.recordGame(winner: .black, points: 2)
        XCTAssertEqual(m.score(for: .black), 2)
        XCTAssertEqual(m.wins(for: .black), 1)
        XCTAssertEqual(m.matchWinner, .black)
        XCTAssertTrue(m.isComplete)
    }

    func testDrawScoresNothingAndExtendsTheMatch() {
        var m = MatchState.bestOfThree(baseStartingPlayer: .white)
        m.recordGame(winner: nil, points: 2)
        XCTAssertEqual(m.results, [.draw])
        XCTAssertEqual(m.score(for: .white) + m.score(for: .black), 0)
        XCTAssertEqual(m.draws, 1)
        XCTAssertEqual(m.maxGames, 4)
        XCTAssertEqual(m.currentGameNumber, 2)
        XCTAssertEqual(m.currentStartingPlayer, .black, "starter still alternates after a draw")
        XCTAssertFalse(m.isComplete)
        m.recordGame(winner: .white, points: 1)
        m.recordGame(winner: .white, points: 1)
        XCTAssertEqual(m.matchWinner, .white)
        m.recordGame(winner: .black, points: 2)
        XCTAssertEqual(m.completedGames, 3, "a decided match ignores further games")
    }

    func testSingleGameDrawDoesNotCompleteTheMatch() {
        var m = MatchState.single(baseStartingPlayer: .black)
        m.record(.draw)
        XCTAssertFalse(m.isComplete)
        m.record(.win(.white))
        XCTAssertEqual(m.matchWinner, .white)
    }

    func testMatchStateCodableRoundTripsResultsAndReadsLegacyWinners() throws {
        var m = MatchState.bestOfThree(baseStartingPlayer: .white)
        m.recordGame(winner: nil, points: 0)
        m.recordGame(winner: .black, points: 2)
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(MatchState.self, from: data), m)

        let legacy = #"{"targetWins":2,"baseStartingPlayer":"W","gameWinners":["B","W"]}"#
        let old = try JSONDecoder().decode(MatchState.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.results, [.win(.black), .win(.white)])
        XCTAssertEqual(old.score(for: .black), 1)
    }

    func testGameRecordResult() {
        XCTAssertNil(GameRecord(startingPlayer: .white).result)
        XCTAssertEqual(GameRecord(startingPlayer: .white, outcome: .black).result, .win(.black))
        XCTAssertEqual(GameRecord(startingPlayer: .white, outcome: .white, points: 2).result,
                       .win(.white, points: 2))
        XCTAssertEqual(GameRecord(startingPlayer: .white, isDraw: true).result, .draw)
    }

    // ── Online GameLog: draw / points ─────────────────────────────────────────

    func testGameLogCarriesDrawAndPointsBackwardCompatibly() throws {
        let plain = GameLog(plies: [], result: .win(.white))
        let plainJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        XCTAssertNil(plainJSON["drawn"], "Plakoto logs gain no new keys")
        XCTAssertNil(plainJSON["points"])

        let draw = GameLog(plies: [], result: .draw)
        XCTAssertTrue(draw.isComplete)
        XCTAssertEqual(draw.result, .draw)
        let double = GameLog(plies: [], result: .win(.black, points: 2))
        XCTAssertEqual(double.result, .win(.black, points: 2))

        let payload = OnlineMatchPayload(targetWins: 2, startingPlayer: .white,
                                         colorByPlayerID: ["a": .white, "b": .black],
                                         games: [draw, double, GameLog()], variant: "plakoto_standard")
        let decoded = try OnlineMatchPayload.decoded(from: payload.encoded())
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.matchState.results, [.draw, .win(.black, points: 2)])
        XCTAssertEqual(decoded.matchState.matchWinner, .black)
        XCTAssertEqual(decoded.currentGameIndex, 2)

        // An older log without the new keys reads as a 1-point win.
        let old = try JSONDecoder().decode(GameLog.self, from: Data(#"{"plies":[],"winnerRaw":"W"}"#.utf8))
        XCTAssertEqual(old.result, .win(.white))
    }

    // ── Model availability gating ─────────────────────────────────────────────

    func testModelCatalogGatesVariantsByBundledModel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCatalogTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("PlakotoValue.mlpackage"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("PortesValue.mlmodelc"),
                                                withIntermediateDirectories: true)
        let catalog = ModelCatalog(directory: dir)

        XCTAssertTrue(catalog.isAvailable(GameVariants.plakoto))
        XCTAssertTrue(catalog.isAvailable(GameVariants.portes))
        XCTAssertFalse(catalog.isAvailable(GameVariants.fevga))
        XCTAssertFalse(catalog.isAvailable(GameVariants.plakotoStandard))
        XCTAssertEqual(Set(catalog.availableVariantIDs), ["plakoto", "portes"])
        XCTAssertEqual(catalog.modelURL(for: GameVariants.portes)?.pathExtension, "mlmodelc")
        // A missing model never yields an agent (no silent random fallback).
        XCTAssertNil(catalog.makeAgent(config: GameConfig(variant: GameVariants.fevga)))
    }

    func testModelCatalogLoadsTheRealFixtureModel() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let catalog = ModelCatalog(directory: fixtures)
        XCTAssertTrue(catalog.isAvailable(GameVariants.plakoto))
        XCTAssertNotNil(catalog.makeAgent(config: .standard))
    }

    // ── Persisted variant preference ──────────────────────────────────────────

    func testVariantPreferencePersistsAndFallsBackToPlakoto() throws {
        let suite = "VariantPreferenceTest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(VariantPreference.load(from: defaults).id, "plakoto", "fresh install")
        VariantPreference.save(GameVariants.fevga, to: defaults)
        XCTAssertEqual(defaults.string(forKey: VariantPreference.key), "fevga")
        XCTAssertEqual(VariantPreference.load(from: defaults).id, "fevga")
        // A second defaults handle on the same suite (≈ the next launch) reads it back.
        XCTAssertEqual(VariantPreference.load(from: try XCTUnwrap(UserDefaults(suiteName: suite))).id, "fevga")
        defaults.set("tavli_9000", forKey: VariantPreference.key)
        XCTAssertEqual(VariantPreference.load(from: defaults).id, "plakoto", "unknown id")
    }

    // ── Equity scaling ────────────────────────────────────────────────────────

    func testEquityScaling() {
        XCTAssertFalse(GameVariants.plakoto.reportsEquity)
        XCTAssertTrue(GameVariants.portes.reportsEquity)
        XCTAssertEqual(GameVariants.portes.equity(fromValue: 0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(GameVariants.portes.equity(fromValue: 1.0), 2, accuracy: 1e-12)
        XCTAssertEqual(GameVariants.fevga.equity(fromValue: 0.25), -1, accuracy: 1e-12)
    }
}
