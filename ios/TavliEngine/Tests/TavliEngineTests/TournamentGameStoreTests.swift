import XCTest
@testable import TavliEngine

/// File-backed round-trip + metadata derivations for the local per-game tournament
/// save store (the Setup "Gespeicherte Spiele" list).
final class TournamentGameStoreTests: XCTestCase {
    private var dir: URL!
    private var store: TournamentGameStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tgames-\(UUID().uuidString)", isDirectory: true)
        store = TournamentGameStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample(humanName: String? = "Anna",
                        humanColor: Color = .white,
                        outcome: Color? = nil,
                        updatedAt: Date = Date()) -> SavedTournamentGame {
        SavedTournamentGame(
            kind: .match,
            matchID: UUID(),
            humanPlayerID: UUID(),
            aiPlayerID: UUID(),
            humanName: humanName,
            aiName: "TavTav",
            humanColor: humanColor,
            startingPlayer: .white,
            manualDiceEntry: false,
            history: [PlyRecord(die1: 3, die2: 5, halfMoves: [[24, 21], [24, 19]])],
            outcome: outcome,
            updatedAt: updatedAt)
    }

    func testSaveListLoadDelete() {
        let g = sample()
        store.save(g)

        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, g.id)
        XCTAssertEqual(list[0].humanName, "Anna")
        XCTAssertEqual(list[0].plyCount, 1)
        XCTAssertFalse(list[0].isFinished)

        // Compare the meaningful fields (ISO8601 encoding drops sub-second date
        // precision, so a whole-struct == would spuriously fail).
        let loaded = store.load(id: g.id)
        XCTAssertEqual(loaded?.id, g.id)
        XCTAssertEqual(loaded?.kind, g.kind)
        XCTAssertEqual(loaded?.matchID, g.matchID)
        XCTAssertEqual(loaded?.humanName, g.humanName)
        XCTAssertEqual(loaded?.aiName, g.aiName)
        XCTAssertEqual(loaded?.humanColorRaw, g.humanColorRaw)
        XCTAssertEqual(loaded?.history, g.history)

        store.delete(id: g.id)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertNil(store.load(id: g.id))
    }

    func testListSortsNewestFirst() {
        store.save(sample(humanName: "old", updatedAt: Date(timeIntervalSince1970: 1000)))
        store.save(sample(humanName: "new", updatedAt: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(store.list().map(\.humanName), ["new", "old"])
    }

    /// The id is the filename key, so re-saving the same game overwrites it (an
    /// interrupted game gaining moves stays a single list entry, not a new one).
    func testSaveOverwritesSameID() {
        var g = sample()
        store.save(g)
        g.history.append(PlyRecord(die1: 1, die2: 2, halfMoves: [[1, 2]]))
        g.outcomeRaw = Color.white.rawValue   // human (white) won
        store.save(g)

        let list = store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].plyCount, 2)
        XCTAssertTrue(list[0].isFinished)
        XCTAssertEqual(list[0].humanWon, true)
    }

    func testIncompatibleSchemaSkipped() throws {
        var bad = sample()
        bad.schemaVersion = SavedTournamentGame.currentSchemaVersion + 1
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(bad).write(to: dir.appendingPathComponent("game-\(bad.id.uuidString).json"))

        XCTAssertTrue(store.list().isEmpty, "incompatible saves are hidden from the list")
    }

    func testOutcomeDerivations() {
        XCTAssertEqual(sample(humanColor: .white, outcome: .white).humanWon, true)

        let loss = sample(humanColor: .white, outcome: .black)
        XCTAssertEqual(loss.humanWon, false)
        XCTAssertEqual(loss.aiColor, .black)

        let inProgress = sample(outcome: nil)
        XCTAssertNil(inProgress.humanWon)
        XCTAssertFalse(inProgress.isFinished)
        XCTAssertFalse(inProgress.isConceded)   // absent flag = not conceded
    }

    func testConcededFlagRoundTrips() {
        var g = sample(outcome: nil)
        g.conceded = true
        store.save(g)

        let loaded = store.load(id: g.id)
        XCTAssertEqual(loaded?.conceded, true)
        XCTAssertEqual(loaded?.isConceded, true)

        // Finishing a conceded game clears the "conceded" status (it's now "Beendet").
        var finished = g
        finished.outcomeRaw = Color.black.rawValue
        XCTAssertFalse(finished.isConceded)
        XCTAssertTrue(finished.isFinished)
    }
}

/// The `gameSave` view onto a saved record must reconstruct the exact board, so a
/// resumed game continues precisely where it left off.
@MainActor
final class SavedTournamentGameResumeTests: XCTestCase {
    /// Drive one human turn through the session intents (no agent).
    private func playTurn(_ s: GameSession, _ d1: Int, _ d2: Int) {
        guard s.phase == .awaitingRoll else { return }
        s.setManualDice(d1, d2)
        guard let chosen = s.moveBuilder.activeMoves.first else { return }
        while s.phase == .picking || s.phase == .moving {
            let idx = s.moveBuilder.built.count
            guard idx < chosen.halfMoves.count else { break }
            let h = chosen.halfMoves[idx]
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
    }

    func testGameSaveResumesToSamePosition() {
        let a = GameSession(startingPlayer: .white)
        playTurn(a, 3, 5)
        playTurn(a, 2, 4)
        XCTAssertFalse(a.history.isEmpty)

        let saved = SavedTournamentGame(
            kind: .match,
            matchID: UUID(),
            humanPlayerID: UUID(),
            aiPlayerID: UUID(),
            humanName: "Anna",
            aiName: "TavTav",
            humanColor: .white,        // ⇒ AI is black
            startingPlayer: .white,
            history: a.history)

        let b = GameSession.resume(from: saved.gameSave)
        XCTAssertEqual(b.game.board.points.map(\.pieces), a.game.board.points.map(\.pieces))
        XCTAssertEqual(b.startingPlayer, .white)
        XCTAssertEqual(b.aiColor, .black)
        XCTAssertEqual(b.history, a.history)
    }
}
