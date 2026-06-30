import XCTest
@testable import TavliEngine

/// The best-of-N match score (#145): win counting, completion / short-circuit,
/// the game counter, the alternating per-game starter, and Codable round-trip.
final class MatchStateTests: XCTestCase {

    func testFreshBestOfThree() {
        let m = MatchState.bestOfThree(baseStartingPlayer: .white)
        XCTAssertEqual(m.targetWins, 2)
        XCTAssertEqual(m.maxGames, 3)
        XCTAssertEqual(m.completedGames, 0)
        XCTAssertEqual(m.currentGameNumber, 1)
        XCTAssertFalse(m.isComplete)
        XCTAssertNil(m.matchWinner)
        XCTAssertTrue(m.isMatch)
        XCTAssertEqual(m.wins(for: .white), 0)
        XCTAssertEqual(m.wins(for: .black), 0)
    }

    func testWinCountingAndCurrentGameNumber() {
        var m = MatchState.bestOfThree(baseStartingPlayer: .white)
        m.recordGame(winner: .white)
        XCTAssertEqual(m.wins(for: .white), 1)
        XCTAssertEqual(m.completedGames, 1)
        XCTAssertEqual(m.currentGameNumber, 2)
        XCTAssertFalse(m.isComplete)

        m.recordGame(winner: .black)
        XCTAssertEqual(m.wins(for: .black), 1)
        XCTAssertEqual(m.currentGameNumber, 3)
        XCTAssertFalse(m.isComplete)
        XCTAssertNil(m.matchWinner)
    }

    func testTwoZeroShortCircuit() {
        var m = MatchState.bestOfThree(baseStartingPlayer: .black)
        m.recordGame(winner: .black)
        m.recordGame(winner: .black)
        XCTAssertTrue(m.isComplete)
        XCTAssertEqual(m.matchWinner, .black)
        XCTAssertEqual(m.completedGames, 2)
        // A stray extra game cannot overturn the settled result.
        m.recordGame(winner: .white)
        XCTAssertEqual(m.completedGames, 2)
        XCTAssertEqual(m.matchWinner, .black)
    }

    func testDecidingThirdGame() {
        var m = MatchState.bestOfThree(baseStartingPlayer: .white)
        m.recordGame(winner: .white)
        m.recordGame(winner: .black)
        m.recordGame(winner: .black)
        XCTAssertTrue(m.isComplete)
        XCTAssertEqual(m.matchWinner, .black)
    }

    func testAlternatingStartingPlayer() {
        var m = MatchState.bestOfThree(baseStartingPlayer: .white)
        XCTAssertEqual(m.currentStartingPlayer, .white)   // game 1
        m.recordGame(winner: .white)
        XCTAssertEqual(m.currentStartingPlayer, .black)   // game 2
        m.recordGame(winner: .black)
        XCTAssertEqual(m.currentStartingPlayer, .white)   // game 3
    }

    func testSingleGame() {
        var m = MatchState.single(baseStartingPlayer: .black)
        XCTAssertEqual(m.targetWins, 1)
        XCTAssertEqual(m.maxGames, 1)
        XCTAssertFalse(m.isMatch)
        m.recordGame(winner: .white)
        XCTAssertTrue(m.isComplete)
        XCTAssertEqual(m.matchWinner, .white)
    }

    func testCodableRoundTrip() throws {
        var m = MatchState.bestOfThree(baseStartingPlayer: .black)
        m.recordGame(winner: .black)
        m.recordGame(winner: .white)
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(MatchState.self, from: data)
        XCTAssertEqual(decoded, m)
        XCTAssertEqual(decoded.gameWinners, [.black, .white])
        XCTAssertEqual(decoded.baseStartingPlayer, .black)
        XCTAssertEqual(decoded.targetWins, 2)
    }
}
