import XCTest
@testable import TavliEngine

/// The wire payload that lives in a Game Center match's `matchData` (#134, #145):
/// encode/decode round-trip, colour assignment, the per-game ply diff, the match-score
/// derivation, v1 back-compat, and version gating.
final class OnlineMatchTests: XCTestCase {
    private func samplePlies() -> [PlyRecord] {
        [
            PlyRecord(die1: 3, die2: 5, halfMoves: [[1, 4], [1, 6]]),
            PlyRecord(die1: 4, die2: 2, halfMoves: [[24, 20], [24, 22]]),
            PlyRecord(die1: 2, die2: 2, halfMoves: [[1, 3], [3, 5], [5, 7], [7, 9]]),
        ]
    }

    func testEncodeDecodeRoundTrip() throws {
        let payload = OnlineMatchPayload(
            startingPlayer: .white,
            colorByPlayerID: ["G:host": .white, "G:guest": .black],
            plies: samplePlies()
        )
        let data = try payload.encoded()
        let decoded = try OnlineMatchPayload.decoded(from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.startingColor, .white)
    }

    func testBestOfThreeRoundTrip() throws {
        let payload = OnlineMatchPayload(
            targetWins: 2,
            startingPlayer: .white,
            colorByPlayerID: ["G:host": .white, "G:guest": .black],
            games: [
                GameLog(plies: samplePlies(), winner: .white),
                GameLog(plies: Array(samplePlies().prefix(2)), winner: nil),
            ]
        )
        let decoded = try OnlineMatchPayload.decoded(from: try payload.encoded())
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.targetWins, 2)
        XCTAssertEqual(decoded.games.count, 2)
        XCTAssertEqual(decoded.completedGameWinners, [.white])
    }

    func testColorAssignmentByPlayerID() {
        let payload = OnlineMatchPayload(
            startingPlayer: .black,
            colorByPlayerID: ["G:host": .black, "G:guest": .white],
            plies: []
        )
        XCTAssertEqual(payload.color(forPlayerID: "G:host"), .black)
        XCTAssertEqual(payload.color(forPlayerID: "G:guest"), .white)
        XCTAssertNil(payload.color(forPlayerID: "G:stranger"))
    }

    func testMatchStateDerivation() {
        // White leads 1–0 with game 2 in progress.
        let payload = OnlineMatchPayload(
            targetWins: 2,
            startingPlayer: .white,
            colorByPlayerID: [:],
            games: [GameLog(plies: samplePlies(), winner: .white), GameLog()]
        )
        let m = payload.matchState
        XCTAssertEqual(m.targetWins, 2)
        XCTAssertEqual(m.baseStartingPlayer, .white)
        XCTAssertEqual(m.wins(for: .white), 1)
        XCTAssertEqual(m.completedGames, 1)
        XCTAssertEqual(m.currentGameNumber, 2)
        XCTAssertFalse(m.isComplete)
        // Current game index tracks the in-progress game; its starter alternates.
        XCTAssertEqual(payload.currentGameIndex, 1)
        XCTAssertEqual(payload.startingPlayer(forGameIndex: 0), .white)
        XCTAssertEqual(payload.startingPlayer(forGameIndex: 1), .black)
    }

    func testPendingPliesWithinCurrentGame() {
        let payload = OnlineMatchPayload(
            startingPlayer: .white,
            colorByPlayerID: [:],
            plies: samplePlies()
        )
        let all = payload.pendingPlies(fromGameIndex: 0, plyCount: 0)
        XCTAssertEqual(all.map(\.gameIndex), [0, 0, 0])
        XCTAssertEqual(all.map(\.ply), samplePlies())

        let tail = payload.pendingPlies(fromGameIndex: 0, plyCount: 2)
        XCTAssertEqual(tail.map(\.ply), [samplePlies()[2]])

        XCTAssertTrue(payload.pendingPlies(fromGameIndex: 0, plyCount: 3).isEmpty)
        XCTAssertTrue(payload.pendingPlies(fromGameIndex: 9, plyCount: 0).isEmpty)
    }

    func testPendingPliesAcrossGameBoundary() {
        // A receiver mid game 0 (2 plies applied) catches up to: game 0's final ply
        // plus game 1's two plies.
        let payload = OnlineMatchPayload(
            targetWins: 2,
            startingPlayer: .white,
            colorByPlayerID: [:],
            games: [
                GameLog(plies: samplePlies(), winner: .white),               // game 0: 3 plies
                GameLog(plies: Array(samplePlies().prefix(2)), winner: nil),  // game 1: 2 plies
            ]
        )
        let pending = payload.pendingPlies(fromGameIndex: 0, plyCount: 2)
        XCTAssertEqual(pending.map(\.gameIndex), [0, 1, 1])
        XCTAssertEqual(pending.map(\.ply),
                       [samplePlies()[2], samplePlies()[0], samplePlies()[1]])
    }

    func testDecodeRejectsNewerSchema() throws {
        var payload = OnlineMatchPayload(startingPlayer: .white, colorByPlayerID: [:])
        payload.schemaVersion = OnlineMatchPayload.currentSchemaVersion + 1
        let data = try payload.encoded()
        XCTAssertThrowsError(try OnlineMatchPayload.decoded(from: data)) { error in
            XCTAssertEqual(error as? OnlineMatchError,
                           .unsupportedSchemaVersion(OnlineMatchPayload.currentSchemaVersion + 1))
        }
    }

    /// A v1 payload (flat `plies`, no `games`/`targetWins`) still decodes as a single game.
    func testDecodeV1BackCompat() throws {
        let v1: [String: Any] = [
            "schemaVersion": 1,
            "startingPlayer": "B",
            "colorByPlayerID": ["G:host": "B", "G:guest": "W"],
            "plies": [
                ["die1": 3, "die2": 5, "halfMoves": [[1, 4], [1, 6]]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: v1)
        let decoded = try OnlineMatchPayload.decoded(from: data)
        XCTAssertEqual(decoded.targetWins, 1)
        XCTAssertEqual(decoded.games.count, 1)
        XCTAssertEqual(decoded.games[0].plies.count, 1)
        XCTAssertNil(decoded.games[0].winner)
        XCTAssertEqual(decoded.startingColor, .black)
        XCTAssertEqual(decoded.color(forPlayerID: "G:guest"), .white)
    }

    func testGameSaveViewIsHumanVsHuman() {
        let payload = OnlineMatchPayload(
            startingPlayer: .black,
            colorByPlayerID: [:],
            plies: samplePlies()
        )
        let save = payload.gameSave()
        XCTAssertEqual(save.startingPlayer, "B")
        XCTAssertNil(save.aiColor)
        XCTAssertEqual(save.history, samplePlies())
    }

    func testGameSaveForLaterGameAlternatesStarter() {
        let payload = OnlineMatchPayload(
            targetWins: 2,
            startingPlayer: .white,
            colorByPlayerID: [:],
            games: [GameLog(plies: samplePlies(), winner: .white),
                    GameLog(plies: Array(samplePlies().prefix(1)))]
        )
        // Game 1 (index 1) starts with White's opponent.
        let save = payload.gameSave(forGameIndex: 1)
        XCTAssertEqual(save.startingPlayer, "B")
        XCTAssertEqual(save.history, Array(samplePlies().prefix(1)))
    }
}
