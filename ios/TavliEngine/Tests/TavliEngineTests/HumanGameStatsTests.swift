import XCTest
@testable import TavliEngine

private func records(_ outcomes: [Bool]) -> [HumanGameRecord] {
    outcomes.enumerated().map { i, won in
        HumanGameRecord(date: Date(timeIntervalSince1970: TimeInterval(i)), humanWon: won)
    }
}

final class HumanGameStatsTests: XCTestCase {
    func testEmptyHistory() {
        let s = HumanGameStats(records: [])
        XCTAssertEqual(s.total, 0)
        XCTAssertEqual(s.wins, 0)
        XCTAssertEqual(s.losses, 0)
        XCTAssertEqual(s.winRate, 0)
        XCTAssertTrue(s.recent.isEmpty)
        XCTAssertEqual(s.streakCount, 0)
        XCTAssertFalse(s.streakIsWin)
        XCTAssertEqual(s, .empty)
    }

    func testOverallCountsAndWinRate() {
        // 5 wins, 3 losses.
        let s = HumanGameStats(records: records([true, false, true, true, false, true, true, false]))
        XCTAssertEqual(s.total, 8)
        XCTAssertEqual(s.wins, 5)
        XCTAssertEqual(s.losses, 3)
        XCTAssertEqual(s.winRate, 5.0 / 8.0, accuracy: 1e-9)
    }

    func testRecentKeepsLast20OldestFirst() {
        // 25 games: indices 0…24, win iff even index.
        let outcomes = (0..<25).map { $0 % 2 == 0 }
        let s = HumanGameStats(records: records(outcomes))
        XCTAssertEqual(s.recent.count, 20)
        // Oldest-first: the kept window is indices 5…24.
        XCTAssertEqual(s.recent, Array(outcomes[5...]))
    }

    func testRecentShorterThanTwentyKeepsAll() {
        let s = HumanGameStats(records: records([true, false, true]))
        XCTAssertEqual(s.recent, [true, false, true])
    }

    func testWinningStreakCountsFromMostRecent() {
        // …loss, then three wins.
        let s = HumanGameStats(records: records([true, false, true, true, true]))
        XCTAssertEqual(s.streakCount, 3)
        XCTAssertTrue(s.streakIsWin)
    }

    func testLosingStreak() {
        let s = HumanGameStats(records: records([true, true, false, false]))
        XCTAssertEqual(s.streakCount, 2)
        XCTAssertFalse(s.streakIsWin)
    }

    func testSingleGameStreak() {
        let s = HumanGameStats(records: records([true]))
        XCTAssertEqual(s.streakCount, 1)
        XCTAssertTrue(s.streakIsWin)
    }
}

/// Store tests run against a real temp-file-backed `HumanGameLogStore` (mirroring
/// the `SaveStore` test style) so persistence is exercised end to end without
/// touching the app's real `Documents`.
@MainActor
final class HumanStatsStoreTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("humanstats-\(UUID().uuidString)", isDirectory: true)
        fileURL = dir.appendingPathComponent("HumanGameLog.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> HumanGameLogStore { HumanGameLogStore(fileURL: fileURL) }

    func testRecordAppendsAndPersists() {
        let store = HumanStatsStore(store: makeStore())
        XCTAssertEqual(store.records.count, 0)

        store.record(humanWon: true)
        store.record(humanWon: false)

        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.stats.wins, 1)
        XCTAssertEqual(store.stats.losses, 1)
        // A fresh store over the same file sees the persisted records.
        XCTAssertEqual(HumanStatsStore(store: makeStore()).records.count, 2)
    }

    func testLoadsExistingHistoryOnInit() {
        makeStore().save([
            HumanGameRecord(date: Date(timeIntervalSince1970: 0), humanWon: true),
            HumanGameRecord(date: Date(timeIntervalSince1970: 1), humanWon: true),
        ])
        let store = HumanStatsStore(store: makeStore())
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.stats.streakCount, 2)
        XCTAssertTrue(store.stats.streakIsWin)
    }

    func testFileStoreRoundTrips() {
        let store = makeStore()
        XCTAssertTrue(store.load().isEmpty)

        let recs = [
            HumanGameRecord(date: Date(timeIntervalSince1970: 10), humanWon: false),
            HumanGameRecord(date: Date(timeIntervalSince1970: 20), humanWon: true),
        ]
        store.save(recs)
        XCTAssertEqual(store.load(), recs)
    }

    func testIncompatibleSchemaIsSkipped() throws {
        // A log written under a future schema version is ignored (read as empty),
        // mirroring how SaveStore.list() skips incompatible files.
        let future = HumanGameLog(
            schemaVersion: HumanGameLog.currentSchemaVersion + 1,
            games: [HumanGameRecord(date: Date(timeIntervalSince1970: 0), humanWon: true)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(future).write(to: fileURL)

        XCTAssertTrue(makeStore().load().isEmpty)
    }
}
