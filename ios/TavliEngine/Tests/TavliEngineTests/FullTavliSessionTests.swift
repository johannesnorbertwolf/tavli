import XCTest
@testable import TavliEngine

/// Full Tavli (#144): the Portes → Fevga → Plakoto sequence, points scoring with
/// doubles and draws, drawn sessions, Codable + save round-trips, resume mid-leg and
/// between legs, the Plakoto-leg variant choice and the per-leg AI gate.
final class FullTavliSessionTests: XCTestCase {

    // ── Sequence + advance ───────────────────────────────────────────────────

    func testFreshSessionStartsWithPortes() {
        let s = FullTavliSession()
        XCTAssertEqual(s.legVariantIDs, ["portes", "fevga", "plakoto"])
        XCTAssertEqual(s.currentLegIndex, 0)
        XCTAssertEqual(s.currentVariant?.id, "portes")
        XCTAssertEqual(s.currentLegNumber, 1)
        XCTAssertEqual(s.completedLegs, 0)
        XCTAssertFalse(s.isComplete)
        XCTAssertNil(s.winner)
        XCTAssertFalse(s.isDrawn)
    }

    func testAdvancesThroughAllThreeLegsInOrder() {
        var s = FullTavliSession()
        s.recordGame(winner: .white, points: 1)
        XCTAssertEqual(s.currentVariant?.id, "fevga")
        XCTAssertEqual(s.currentLegNumber, 2)
        s.recordGame(winner: .black, points: 1)
        XCTAssertEqual(s.currentVariant?.id, "plakoto")
        XCTAssertEqual(s.currentLegNumber, 3)
        s.recordGame(winner: .white, points: 1)
        XCTAssertTrue(s.isComplete)
        XCTAssertNil(s.currentLegIndex)
        XCTAssertNil(s.currentVariant)
        XCTAssertEqual(s.currentLegNumber, 3)
        XCTAssertEqual(s.winner, .white)
    }

    func testRecordingAfterCompletionIsANoOp() {
        var s = FullTavliSession(results: [.win(.white), .win(.white), .win(.black)])
        s.recordGame(winner: .black, points: 2)
        XCTAssertEqual(s.results.count, 3)
        XCTAssertEqual(s.score(for: .black), 1)
    }

    // ── Scoring ──────────────────────────────────────────────────────────────

    func testDoubleGamesCountTwoAndHousePlakotoCountsOne() {
        var s = FullTavliSession()
        s.recordGame(winner: .black, points: 2)   // Portes double
        s.recordGame(winner: .white, points: 2)   // Fevga double
        s.recordGame(winner: .white, points: 2)   // house Plakoto: clamped to 1
        XCTAssertEqual(s.score(for: .black), 2)
        XCTAssertEqual(s.score(for: .white), 3)
        XCTAssertEqual(s.results.last, .win(.white, points: 1))
        XCTAssertEqual(s.winner, .white)
    }

    func testStandardPlakotoLegScoresDoubles() {
        var s = FullTavliSession(plakotoVariantID: "plakoto_standard")
        s.recordGame(winner: .white, points: 1)
        s.recordGame(winner: .white, points: 1)
        s.recordGame(winner: .black, points: 2)
        XCTAssertEqual(s.score(for: .black), 2)
        XCTAssertEqual(s.score(for: .white), 2)
        XCTAssertTrue(s.isDrawn)
    }

    func testDrawnLegScoresZeroAndStillAdvances() {
        var s = FullTavliSession(plakotoVariantID: "plakoto_standard")
        s.recordGame(winner: .white, points: 2)
        s.recordGame(winner: .black, points: 1)
        s.recordGame(winner: nil, points: 0)      // both mothers pinned
        XCTAssertTrue(s.isComplete)
        XCTAssertEqual(s.results.last, .draw)
        XCTAssertEqual(s.score(for: .white), 2)
        XCTAssertEqual(s.score(for: .black), 1)
        XCTAssertEqual(s.winner, .white)
    }

    func testEqualTotalsAreADrawnSession() {
        var s = FullTavliSession()
        s.recordGame(winner: .white, points: 1)
        s.recordGame(winner: .black, points: 1)
        XCTAssertFalse(s.isDrawn)                 // not complete yet
        s.record(.draw)
        XCTAssertTrue(s.isComplete)
        XCTAssertTrue(s.isDrawn)
        XCTAssertNil(s.winner)
    }

    // ── Plakoto-leg variant choice ───────────────────────────────────────────

    func testPlakotoLegFollowsStandardPreferenceOnly() {
        XCTAssertEqual(FullTavliSession.plakotoLegVariantID(preferredID: "plakoto_standard"), "plakoto_standard")
        for other in ["plakoto", "portes", "fevga", nil, "unknown"] as [String?] {
            XCTAssertEqual(FullTavliSession.plakotoLegVariantID(preferredID: other), "plakoto")
        }
        XCTAssertEqual(FullTavliSession(preferredVariantID: "plakoto_standard", aiColor: .black)
                        .legVariantIDs, ["portes", "fevga", "plakoto_standard"])
        XCTAssertEqual(FullTavliSession(preferredVariantID: "fevga", aiColor: nil).plakotoVariantID,
                       "plakoto")
    }

    func testPreferenceIsReadFromUserDefaults() {
        let defaults = UserDefaults(suiteName: "FullTavliTest-\(UUID().uuidString)")!
        VariantPreference.save(GameVariants.plakotoStandard, to: defaults)
        let s = FullTavliSession(preferredVariantID: VariantPreference.load(from: defaults).id, aiColor: nil)
        XCTAssertEqual(s.plakotoVariantID, "plakoto_standard")
    }

    // ── AI gating ────────────────────────────────────────────────────────────

    func testAIGateRequiresEveryLegsModel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullTavliCatalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = ModelCatalog(directory: dir)
        func bundle(_ name: String) throws {
            try FileManager.default.createDirectory(
                at: dir.appendingPathComponent("\(name).mlpackage"), withIntermediateDirectories: true)
        }

        let house = FullTavliSession(aiColor: .black)
        let standard = FullTavliSession(plakotoVariantID: "plakoto_standard", aiColor: .black)

        try bundle("PlakotoValue")                 // today's app: only house Plakoto
        XCTAssertFalse(house.isAIAvailable(in: catalog))
        XCTAssertEqual(house.unavailableLegVariantIDs(in: catalog), ["portes", "fevga"])

        try bundle("PortesValue")
        try bundle("FevgaValue")
        XCTAssertTrue(house.isAIAvailable(in: catalog))
        XCTAssertFalse(standard.isAIAvailable(in: catalog))
        XCTAssertEqual(standard.unavailableLegVariantIDs(in: catalog), ["plakoto_standard"])

        try bundle("PlakotoStandardValue")
        XCTAssertTrue(standard.isAIAvailable(in: catalog))
    }

    // ── Codable + persistence ────────────────────────────────────────────────

    func testCodableRoundTrip() throws {
        let s = FullTavliSession(plakotoVariantID: "plakoto_standard", aiColor: .black,
                                 results: [.win(.white, points: 2), .draw])
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(FullTavliSession.self, from: data)
        XCTAssertEqual(decoded, s)
        XCTAssertEqual(decoded.aiColor, .black)
        XCTAssertEqual(decoded.currentVariant?.id, "plakoto_standard")

        let twoPlayer = FullTavliSession()
        XCTAssertEqual(try JSONDecoder().decode(FullTavliSession.self,
                                                from: JSONEncoder().encode(twoPlayer)), twoPlayer)
    }

    func testGameSaveCarriesSessionAndStaysBackwardCompatible() throws {
        let session = FullTavliSession(aiColor: .black, results: [.win(.black, points: 2)])
        var save = GameSave(name: "x", savedAt: Date(timeIntervalSince1970: 0), startingPlayer: "W",
                            aiColor: "B", history: [], variant: "fevga")
        // A standalone game writes no `fullTavli` key (unchanged file shape).
        let plain = String(decoding: try JSONEncoder().encode(save), as: UTF8.self)
        XCTAssertFalse(plain.contains("fullTavli"))

        save.fullTavli = session
        let decoded = try JSONDecoder().decode(GameSave.self, from: JSONEncoder().encode(save))
        XCTAssertEqual(decoded.fullTavli, session)
        XCTAssertEqual(decoded.schemaVersion, 1)

        // An older file (no key) decodes as a standalone game.
        let legacy = #"{"schemaVersion":1,"name":"old","savedAt":0,"startingPlayer":"W","history":[]}"#
        XCTAssertNil(try JSONDecoder().decode(GameSave.self, from: Data(legacy.utf8)).fullTavli)
    }

    func testSaveStoreListsTheSession() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FullTavliStore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SaveStore(directory: dir)
        var save = GameSave(name: "leg", savedAt: Date(), startingPlayer: "W", aiColor: nil,
                            history: [], variant: "portes")
        save.fullTavli = FullTavliSession()
        try store.writeAutosave(save)
        XCTAssertEqual(store.loadAutosave()?.fullTavli, FullTavliSession())
        XCTAssertEqual(store.list().first?.fullTavli, FullTavliSession())
    }

    // ── Resume ───────────────────────────────────────────────────────────────

    private func record(_ variant: String, outcome: Color? = nil, isDraw: Bool = false,
                        points: Int? = nil) -> GameRecord {
        GameRecord(startingPlayer: .white, outcome: outcome, variantID: variant,
                   isDraw: isDraw, points: points)
    }

    func testResumeMidLeg() {
        var s = FullTavliSession(results: [.win(.white)])
        XCTAssertEqual(s.resume(savedGame: record("fevga")), .inLeg(index: 1))
        XCTAssertEqual(s.results.count, 1)
    }

    func testResumeBetweenLegsAfterTheResultWasRecorded() {
        var s = FullTavliSession(results: [.win(.white, points: 2)])
        XCTAssertEqual(s.resume(savedGame: record("portes", outcome: .white, points: 2)),
                       .betweenLegs(nextIndex: 1))
        XCTAssertEqual(s.results.count, 1, "an already-counted leg is not recorded twice")
        XCTAssertEqual(s.score(for: .white), 2)
    }

    func testResumeRecordsAFinishedLegTheSessionMissed() {
        var s = FullTavliSession(results: [.win(.white)])
        XCTAssertEqual(s.resume(savedGame: record("fevga", outcome: .black, points: 2)),
                       .betweenLegs(nextIndex: 2))
        XCTAssertEqual(s.score(for: .black), 2)
        XCTAssertEqual(s.currentVariant?.id, "plakoto")
    }

    func testResumeAfterTheLastLegIsComplete() {
        var s = FullTavliSession(plakotoVariantID: "plakoto_standard",
                                 results: [.win(.white), .win(.black)])
        XCTAssertEqual(s.resume(savedGame: record("plakoto_standard", isDraw: true)), .complete)
        XCTAssertTrue(s.isDrawn)
    }

    func testResumeFromAPersistedSaveBetweenLegs() throws {
        // What the app writes when the Portes leg ends: the finished game + the session.
        var session = FullTavliSession(aiColor: .black)
        session.recordGame(winner: .black, points: 2)
        let save = GameSave(name: "leg 1", savedAt: Date(), startingPlayer: "W", aiColor: "B",
                            outcome: "B", history: [], variant: "portes", points: 2,
                            fullTavli: session)
        let loaded = try JSONDecoder().decode(GameSave.self, from: JSONEncoder().encode(save))
        var resumed = try XCTUnwrap(loaded.fullTavli)
        XCTAssertEqual(resumed.resume(savedGame: loaded.record), .betweenLegs(nextIndex: 1))
        XCTAssertEqual(resumed.currentVariant?.id, "fevga")
        XCTAssertEqual(resumed.score(for: .black), 2)
    }
}
