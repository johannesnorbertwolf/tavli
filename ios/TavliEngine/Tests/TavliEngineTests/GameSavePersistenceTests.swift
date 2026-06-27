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

/// Drive both sides through session intents (no agent). Sets the dice, then plays
/// the first active move's half-moves to completion (a forced pass advances on its
/// own). Returns once the turn has finished or the game is over.
@MainActor
private func playOneTurn(_ s: GameSession, _ d1: Int, _ d2: Int) {
    guard s.phase == .awaitingRoll else { return }
    s.setManualDice(d1, d2)
    guard let chosen = s.moveBuilder.activeMoves.first else { return }  // forced pass
    while s.phase == .picking || s.phase == .moving {
        let idx = s.moveBuilder.built.count
        guard idx < chosen.halfMoves.count else { break }
        let h = chosen.halfMoves[idx]
        s.selectPoint(h.from.position)
        s.commitHalfMove(from: h.from.position, to: h.to.position)
    }
}

@MainActor
private func signature(_ s: GameSession) -> [[Color]] { s.game.board.points.map(\.pieces) }

@MainActor
final class GameHistoryRecordingTests: XCTestCase {
    func testRecordsDiceAndHalfMovesPerPly() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        let chosen = s.moveBuilder.activeMoves.first!
        for h in chosen.halfMoves {
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
        XCTAssertEqual(s.history.count, 1)
        XCTAssertEqual(s.history[0].die1, 3)
        XCTAssertEqual(s.history[0].die2, 5)
        XCTAssertFalse(s.history[0].halfMoves.isEmpty)
        // Each recorded pair reproduces an applied single-die hop or merged move.
        for pair in s.history[0].halfMoves { XCTAssertEqual(pair.count, 2) }
    }

    func testForcedPassRecordsEmptyHalfMoves() {
        let s = GameSession(startingPlayer: .white)
        let b = s.game.board
        for i in 0...(b.boardSize + 1) { b.setPoint(i, pieces: []) }
        b.setPoint(5, pieces: [.white])
        b.setPoint(6, pieces: [.black, .black])   // blocks die 1
        b.setPoint(7, pieces: [.black, .black])   // blocks die 2

        s.setManualDice(1, 2)
        XCTAssertEqual(s.history.count, 1)
        XCTAssertTrue(s.history[0].halfMoves.isEmpty)   // a pass
        XCTAssertEqual(s.currentPlayer, .black)
    }

    func testNewGameClearsHistory() {
        let s = GameSession(startingPlayer: .white)
        s.setManualDice(3, 5)
        let chosen = s.moveBuilder.activeMoves.first!
        for h in chosen.halfMoves {
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
        XCTAssertFalse(s.history.isEmpty)
        s.newGame(startingPlayer: .black)
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertEqual(s.startingPlayer, .black)
    }
}

@MainActor
final class GameSaveResumeTests: XCTestCase {
    /// Snapshot a mid-game session, resume from the save, and assert the board,
    /// the player to move, the starting player, and the history all match exactly.
    func testSnapshotResumeReproducesPosition() {
        let a = GameSession(startingPlayer: .white)
        var rng = SeededRNG(seed: 0xA5A5A5)
        for _ in 0..<10 {
            guard a.phase == .awaitingRoll else { break }
            playOneTurn(a, Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
        }
        XCTAssertFalse(a.history.isEmpty)

        let save = a.snapshot(name: "mid")
        let b = GameSession.resume(from: save)

        XCTAssertEqual(signature(b), signature(a))
        XCTAssertEqual(b.currentPlayer, a.currentPlayer)
        XCTAssertEqual(b.startingPlayer, a.startingPlayer)
        XCTAssertEqual(b.history, a.history)
        XCTAssertEqual(b.phase, .awaitingRoll)
    }

    /// A resumed game continues normally and can reach a win — the replay leaves a
    /// fully consistent board/turn state, not a frozen snapshot.
    func testResumedGameContinuesToWin() {
        let a = GameSession(startingPlayer: .black)
        var rng = SeededRNG(seed: 0xBEEF)
        for _ in 0..<8 {
            guard a.phase == .awaitingRoll else { break }
            playOneTurn(a, Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
        }

        let b = GameSession.resume(from: a.snapshot(name: "x"))
        // Continue with the SAME dice stream and assert it terminates.
        var turns = 0
        while b.phase != .gameOver(winner: .white), b.phase != .gameOver(winner: .black) {
            turns += 1
            XCTAssertLessThan(turns, 100_000, "resumed game failed to terminate")
            playOneTurn(b, Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
        }
        XCTAssertTrue(b.game.isOver())
    }

    /// A game played to completion serializes and resumes straight into gameOver.
    func testResumeOfFinishedGameIsTerminal() {
        let a = GameSession(startingPlayer: .black)
        var rng = SeededRNG(seed: 0x1234)
        var turns = 0
        while a.phase != .gameOver(winner: .white), a.phase != .gameOver(winner: .black) {
            turns += 1
            XCTAssertLessThan(turns, 100_000)
            playOneTurn(a, Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
        }
        let b = GameSession.resume(from: a.snapshot(name: "done"))
        guard case .gameOver = b.phase else { return XCTFail("expected terminal resume") }
        XCTAssertEqual(b.game.getWinner(), a.game.getWinner())
        XCTAssertEqual(signature(b), signature(a))
    }

    func testAIColorRoundTrips() {
        let a = GameSession(startingPlayer: .black, aiColor: .black)
        a.setManualDice(3, 5)   // black opens; no agent → no move, but turn order is set
        let b = GameSession.resume(from: a.snapshot(name: "ai"))
        XCTAssertEqual(b.aiColor, .black)
        XCTAssertEqual(b.startingPlayer, .black)
    }
}

final class SaveStoreTests: XCTestCase {
    private var dir: URL!
    private var store: SaveStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("savestore-\(UUID().uuidString)", isDirectory: true)
        store = SaveStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample(name: String, savedAt: Date = Date()) -> GameSave {
        GameSave(name: name, savedAt: savedAt, startingPlayer: "B", aiColor: "B",
                 history: [PlyRecord(die1: 3, die2: 5, halfMoves: [[24, 21], [24, 19]])])
    }

    func testWriteListLoadDelete() throws {
        let filename = try store.writeManual(sample(name: "My Game"))
        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].name, "My Game")
        XCTAssertEqual(list[0].plyCount, 1)
        XCTAssertFalse(list[0].isAutosave)

        // A save without analysis is a v1 file (#104): the on-disk schemaVersion is
        // derived from content, so compare the meaningful fields rather than the whole
        // struct (the in-memory `currentSchemaVersion` default doesn't round-trip).
        let loaded = try store.load(filename: filename)
        XCTAssertEqual(loaded.name, "My Game")
        XCTAssertEqual(loaded.startingPlayer, "B")
        XCTAssertEqual(loaded.aiColor, "B")
        XCTAssertEqual(loaded.history, sample(name: "My Game").history)
        XCTAssertNil(loaded.analysis, "no analysis was attached")
        XCTAssertEqual(loaded.schemaVersion, 1, "an analysis-free save stays a v1 file")

        try store.delete(filename: filename)
        XCTAssertTrue(store.list().isEmpty)
    }

    func testListSortsNewestFirst() throws {
        let old = GameSave(name: "old", savedAt: Date(timeIntervalSince1970: 1000),
                           startingPlayer: "W", aiColor: nil, history: [])
        let new = GameSave(name: "new", savedAt: Date(timeIntervalSince1970: 2000),
                           startingPlayer: "W", aiColor: nil, history: [])
        try store.write(old, filename: "a.json")
        try store.write(new, filename: "b.json")
        XCTAssertEqual(store.list().map(\.name), ["new", "old"])
    }

    func testAutosaveSlot() throws {
        XCTAssertNil(store.loadAutosave())
        try store.writeAutosave(sample(name: "auto"))
        XCTAssertEqual(store.loadAutosave()?.name, "auto")
        XCTAssertTrue(store.list().contains { $0.isAutosave })
        store.clearAutosave()
        XCTAssertNil(store.loadAutosave())
    }

    func testIncompatibleSchemaIsSkippedAndThrows() throws {
        // `GameSave.encode` derives the version from content (v1/v2, #104), so to forge
        // a file from a hypothetical *future* build, encode a valid save and patch the
        // schemaVersion in the serialized JSON to one above what we understand.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sample(name: "future"))
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict["schemaVersion"] = GameSave.currentSchemaVersion + 1
        let bumped = try JSONSerialization.data(withJSONObject: dict)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try bumped.write(to: dir.appendingPathComponent("future.json"))

        XCTAssertTrue(store.list().isEmpty, "incompatible saves are hidden from the list")
        XCTAssertThrowsError(try store.load(filename: "future.json"))
    }
}
