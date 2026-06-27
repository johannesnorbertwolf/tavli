import XCTest
@testable import TavliEngine

// Game log + optional analysis persistence (#104). All synthetic — no Core ML, no
// training/eval — so these run in milliseconds alongside the fast engine tests.

// ── GameSave v1 ↔ v2 schema migration / back-compat ──────────────────────────────

final class GameSaveSchemaTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func sample(analysis: [AnalysisEntry]? = nil) -> GameSave {
        // Whole-second date: `.iso8601` drops sub-second precision, so a fractional
        // `Date()` would round-trip unequal even though every field prints the same.
        let wholeSecond = Date(timeIntervalSince1970: 1_750_000_000)
        return GameSave(gameId: UUID(), name: "g", savedAt: wholeSecond,
                        startingPlayer: "W", aiColor: "B", outcome: "W",
                        history: [PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4]])],
                        analysis: analysis)
    }

    /// No analysis ⇒ the file is written at schemaVersion 1 and omits the `analysis`
    /// key entirely, so a v1 reader is unaffected.
    func testNoAnalysisEncodesAsV1WithoutKey() throws {
        let json = try encoder.encode(sample(analysis: nil))
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertNil(obj["analysis"])
        // gameId/outcome are still present (extra keys a v1 reader ignores).
        XCTAssertNotNil(obj["gameId"])
        XCTAssertEqual(obj["outcome"] as? String, "W")
    }

    /// Present analysis ⇒ the file is bumped to schemaVersion 2 and carries the array.
    func testAnalysisEncodesAsV2() throws {
        let entry = AnalysisEntry(plyNumber: 1, playedMove: [[1, 4]], playedScore: 0.4,
                                  bestMove: [[1, 6]], bestScore: 0.8, depth: 3)
        let json = try encoder.encode(sample(analysis: [entry]))
        let obj = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertEqual(obj["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(obj["analysis"])
    }

    /// A literal pre-#104 v1 payload (no gameId/outcome/analysis) decodes cleanly,
    /// with the optionals nil — the core back-compat guarantee.
    func testDecodeV1PayloadWithoutNewKeys() throws {
        let v1 = """
        {"schemaVersion":1,"name":"old","savedAt":"2026-01-01T00:00:00Z",
         "startingPlayer":"W","history":[{"die1":3,"die2":5,"halfMoves":[[1,4]]}]}
        """
        let save = try decoder.decode(GameSave.self, from: Data(v1.utf8))
        XCTAssertEqual(save.schemaVersion, 1)
        XCTAssertNil(save.gameId)
        XCTAssertNil(save.outcome)
        XCTAssertNil(save.analysis)
        XCTAssertEqual(save.history.count, 1)
    }

    /// Round-trip with analysis preserves every field.
    func testV2RoundTrip() throws {
        let entry = AnalysisEntry(plyNumber: 2, playedMove: [[13, 7]], playedScore: 0.42,
                                  bestMove: [[13, 10], [10, 7]], bestScore: 0.61, depth: 2)
        let original = sample(analysis: [entry])
        let decoded = try decoder.decode(GameSave.self, from: encoder.encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.analysis, [entry])
    }

    /// The `GameRecord` bridge carries in-play analysis through to a v2 file (#146,
    /// the exact shape the game-over hook writes), and empty analysis stays v1.
    func testRecordBridgeCarriesInPlayAnalysis() throws {
        let record = GameRecord(startingPlayer: .white, aiColor: .black,
                                plies: [PlyRecord(die1: 1, die2: 2, halfMoves: [[1, 3]])],
                                outcome: .white, gameId: UUID())
        let entries = [AnalysisEntry(plyNumber: 1, playedMove: [[1, 3]], playedScore: 0.5,
                                     bestMove: [[1, 3]], bestScore: 0.5, depth: 2)]
        let withAnalysis = GameSave(record: record, name: "g", analysis: entries)
        let decoded = try decoder.decode(GameSave.self, from: encoder.encode(withAnalysis))
        XCTAssertEqual(decoded.analysis, entries)
        XCTAssertEqual(decoded.schemaVersion, 2)

        let none = GameSave(record: record, name: "g", analysis: nil)
        let obj = try JSONSerialization.jsonObject(
            with: encoder.encode(none)) as! [String: Any]
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertNil(obj["analysis"])
    }

    /// The `GameRecord` bridge carries gameId + outcome both ways.
    func testRecordBridgeCarriesIdAndOutcome() {
        let id = UUID()
        let record = GameRecord(startingPlayer: .white, aiColor: .black,
                                plies: [PlyRecord(die1: 1, die2: 2, halfMoves: [[1, 3]])],
                                outcome: .black, gameId: id)
        let save = GameSave(record: record, name: "x")
        XCTAssertEqual(save.gameId, id)
        XCTAssertEqual(save.outcome, "B")
        let back = save.record
        XCTAssertEqual(back.gameId, id)
        XCTAssertEqual(back.outcome, .black)
    }

    /// A save lacking a gameId still yields a (fresh) record id, never crashing.
    func testRecordBridgeSynthesizesMissingId() {
        let save = GameSave(name: "no-id", savedAt: Date(), startingPlayer: "W",
                            aiColor: nil, history: [])
        XCTAssertNil(save.gameId)
        XCTAssertNotNil(save.record.gameId)
    }
}

// ── GameLogStore: append-only log + analysis write-back ──────────────────────────

final class GameLogStoreTests: XCTestCase {
    private var dir: URL!
    private var log: GameLogStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gamelog-\(UUID().uuidString)", isDirectory: true)
        log = GameLogStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func finishedSave(id: UUID = UUID(), outcome: String? = "W",
                              savedAt: Date = Date()) -> GameSave {
        GameSave(gameId: id, name: "Game", savedAt: savedAt,
                 startingPlayer: "W", aiColor: "B", outcome: outcome,
                 history: [PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4]]),
                           PlyRecord(die1: 6, die2: 2, halfMoves: [[24, 18]])])
    }

    func testAppendListLoad() throws {
        let id = UUID()
        try log.append(finishedSave(id: id))
        let list = log.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].gameId, id)
        XCTAssertEqual(list[0].outcome, "W")
        XCTAssertEqual(list[0].aiColor, "B")
        XCTAssertEqual(list[0].plyCount, 2)
        XCTAssertFalse(list[0].hasAnalysis)

        let loaded = try XCTUnwrap(log.load(gameId: id))
        XCTAssertEqual(loaded.gameId, id)
        XCTAssertEqual(loaded.history.count, 2)
    }

    /// Re-appending the same game id overwrites in place (no duplicate entries).
    func testAppendSameIdOverwrites() throws {
        let id = UUID()
        try log.append(finishedSave(id: id, outcome: "W"))
        try log.append(finishedSave(id: id, outcome: "B"))
        XCTAssertEqual(log.list().count, 1)
        XCTAssertEqual(log.load(gameId: id)?.outcome, "B")
    }

    /// A logged game starts analysis-free; attaching it bumps to v2 and reads back.
    func testAttachAnalysisRoundTrip() throws {
        let id = UUID()
        try log.append(finishedSave(id: id))
        XCTAssertNil(log.analysis(forGameId: id))

        let entries = [AnalysisEntry(plyNumber: 1, playedMove: [[1, 4]], playedScore: 0.4,
                                     bestMove: [[1, 6]], bestScore: 0.8, depth: 2)]
        let found = try log.attachAnalysis(entries, forGameId: id)
        XCTAssertTrue(found)
        XCTAssertEqual(log.analysis(forGameId: id), entries)
        XCTAssertEqual(log.load(gameId: id)?.schemaVersion, 2)
        XCTAssertTrue(log.list().first?.hasAnalysis ?? false)
        // The move history survives the patch untouched.
        XCTAssertEqual(log.load(gameId: id)?.history.count, 2)
    }

    /// Attaching to a game that isn't logged is a no-op (returns false, writes nothing).
    func testAttachAnalysisMissingGameIsNoOp() throws {
        let found = try log.attachAnalysis(
            [AnalysisEntry(plyNumber: 1, playedMove: [], playedScore: 0,
                           bestMove: [], bestScore: 0, depth: 1)],
            forGameId: UUID())
        XCTAssertFalse(found)
        XCTAssertTrue(log.list().isEmpty)
    }

    func testListSortsNewestFirst() throws {
        try log.append(finishedSave(savedAt: Date(timeIntervalSince1970: 1000)))
        try log.append(finishedSave(savedAt: Date(timeIntervalSince1970: 2000)))
        let times = log.list().map(\.playedAt)
        XCTAssertEqual(times, times.sorted(by: >))
    }

    func testDelete() throws {
        let id = UUID()
        try log.append(finishedSave(id: id))
        try log.delete(gameId: id)
        XCTAssertTrue(log.list().isEmpty)
        XCTAssertNil(log.load(gameId: id))
    }

    /// `append` is the only writer real code uses; it always lands an addressable file
    /// even when the save carries no gameId (a fresh one is assigned).
    func testAppendAssignsIdWhenMissing() throws {
        let save = GameSave(name: "no-id", savedAt: Date(), startingPlayer: "W",
                            aiColor: nil, outcome: "W", history: [])
        let id = try log.append(save)
        XCTAssertNotNil(log.load(gameId: id))
        XCTAssertEqual(log.list().count, 1)
    }
}

// ── Cached-analysis reconstruction (the write-back → read-back round-trip) ────────

final class GameReviewCachedResultTests: XCTestCase {
    /// Replaying a record + its saved analysis must rebuild full `PlyEvaluation`s —
    /// crucially the `boardStacks` the drill needs — purely from the move history, with
    /// no model. This is what lets a second review/drill skip re-analysis.
    func testCachedResultReconstructsBoardStacksAndScores() {
        // A real game position so the replay produces a non-trivial board: White opens
        // from the standard start. We synthesize an analysis entry for ply 1.
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [
                PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4], [1, 6]]),
                PlyRecord(die1: 2, die2: 4, halfMoves: [[24, 22], [24, 20]]),
            ])
        let analysis = [
            AnalysisEntry(plyNumber: 1, playedMove: [[1, 4], [1, 6]], playedScore: 0.55,
                          bestMove: [[1, 4], [1, 6]], bestScore: 0.55, depth: 3),
        ]
        let result = GameReview.cachedResult(record: record, analysis: analysis)

        XCTAssertEqual(result.evaluations.count, 1)
        let e = result.evaluations[0]
        XCTAssertEqual(e.plyNumber, 1)
        XCTAssertEqual(e.mover, .white)
        XCTAssertEqual(e.die1, 3)
        XCTAssertEqual(e.die2, 5)
        XCTAssertEqual(e.playedScore, 0.55, accuracy: 1e-6)
        XCTAssertEqual(e.bestScore, 0.55, accuracy: 1e-6)
        XCTAssertEqual(e.depth, 3)
        // boardStacks is the PRE-move position: the initial board (White still on 1).
        XCTAssertFalse(e.boardStacks.isEmpty)
        XCTAssertEqual(e.boardStacks[1], Array(repeating: Color.white, count: 15))
        // hadChoice is recomputed from the legal moves at the position, not from
        // played == best: the opening offers many moves, so it's a real choice even
        // though the player happened to play the best one.
        XCTAssertTrue(e.hadChoice)
    }

    /// played ≠ best ⇒ reconstructed as a real choice (hadChoice == true).
    func testCachedResultMarksChoiceWhenMovesDiffer() {
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4], [1, 6]])])
        let analysis = [
            AnalysisEntry(plyNumber: 1, playedMove: [[1, 4], [1, 6]], playedScore: 0.40,
                          bestMove: [[1, 6], [6, 9]], bestScore: 0.70, depth: 2),
        ]
        let e = GameReview.cachedResult(record: record, analysis: analysis).evaluations[0]
        XCTAssertTrue(e.hadChoice)
        XCTAssertTrue(e.isBlunder(threshold: 0.10))
    }

    /// Analysis entries whose ply can't be located (a stale/cleared log) are dropped,
    /// not crashed on.
    func testCachedResultDropsUnknownPlies() {
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4], [1, 6]])])
        let analysis = [
            AnalysisEntry(plyNumber: 99, playedMove: [[1, 4]], playedScore: 0.5,
                          bestMove: [[1, 4]], bestScore: 0.5, depth: 1),
        ]
        XCTAssertTrue(GameReview.cachedResult(record: record, analysis: analysis)
                        .evaluations.isEmpty)
    }

    /// The full loop: GameReviewResult → AnalysisEntry array → cachedResult.
    /// The scores survive the Float→Double→Float trip within tolerance.
    func testAnalysisEntriesFromReviewResultRoundTrip() {
        let board = GameBoard(); board.initializeBoard()
        let stacks = board.captureStacks()
        let eval = PlyEvaluation(plyNumber: 1, die1: 3, die2: 5, boardStacks: stacks,
                                 mover: .white, playedMove: [[1, 4]], playedScore: 0.42,
                                 bestMove: [[1, 6]], bestScore: 0.61, hadChoice: true, depth: 2)
        let entries = [AnalysisEntry](reviewResult: GameReviewResult(evaluations: [eval]))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].plyNumber, 1)
        XCTAssertEqual(entries[0].playedScore, 0.42, accuracy: 1e-6)
        XCTAssertEqual(entries[0].bestMove, [[1, 6]])
        XCTAssertEqual(entries[0].depth, 2)
    }
}
