import XCTest
@testable import TavliEngine

/// The wire payload that lives in a Game Center match's `matchData` (#134): encode/
/// decode round-trip, colour assignment, the new-ply diff, and version gating.
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

    func testNewPliesSinceLocalCount() {
        let payload = OnlineMatchPayload(
            startingPlayer: .white,
            colorByPlayerID: [:],
            plies: samplePlies()
        )
        XCTAssertEqual(Array(payload.newPlies(since: 0)).count, 3)
        XCTAssertEqual(Array(payload.newPlies(since: 2)), [samplePlies()[2]])
        XCTAssertTrue(payload.newPlies(since: 3).isEmpty)
        XCTAssertTrue(payload.newPlies(since: 9).isEmpty)   // already ahead → nothing
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
}
