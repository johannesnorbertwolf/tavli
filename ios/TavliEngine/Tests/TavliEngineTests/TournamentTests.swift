import XCTest
@testable import TavliEngine

final class TournamentTests: XCTestCase {

    // Build a tournament with named human players (deterministic), no AI.
    private func make(_ names: [String]) -> Tournament {
        var t = Tournament()
        for n in names { t.addPlayer(name: n) }
        return t
    }

    private func id(_ t: Tournament, _ name: String) -> UUID {
        t.players.first { $0.name == name }!.id
    }

    // ── Round-robin reconciliation ──────────────────────────────────────────────

    func testRoundRobinPairingCount() {
        let t = make(["A", "B", "C", "D"])
        // C(4,2) = 6 unique pairings, no self-pairings, no duplicates.
        XCTAssertEqual(t.matches.count, 6)
        let keys = Set(t.matches.map { Set([$0.a, $0.b]) })
        XCTAssertEqual(keys.count, 6)
        XCTAssertFalse(t.matches.contains { $0.a == $0.b })
    }

    func testAddingPlayerPreservesExistingResults() {
        var t = make(["A", "B", "C"])
        let ab = t.matches.first { $0.contains(id(t, "A")) && $0.contains(id(t, "B")) }!
        t.setResult(matchID: ab.id, winner: id(t, "A"))

        t.addPlayer(name: "D")

        // The A–B result and its match id survive; new pairings for D appear.
        XCTAssertEqual(t.matches.count, 6)
        let again = t.match(ab.id)
        XCTAssertEqual(again?.winner, id(t, "A"))
        XCTAssertEqual(t.wins(for: id(t, "A")), 1)
    }

    func testRemovingPlayerDropsTheirMatchesButKeepsOthers() {
        var t = make(["A", "B", "C"])
        let ab = t.matches.first { $0.contains(id(t, "A")) && $0.contains(id(t, "B")) }!
        t.setResult(matchID: ab.id, winner: id(t, "A"))
        let cID = id(t, "C")

        t.removePlayer(cID)

        XCTAssertEqual(t.players.count, 2)
        XCTAssertEqual(t.matches.count, 1)                       // only A–B remains
        XCTAssertFalse(t.matches.contains { $0.contains(cID) })
        XCTAssertEqual(t.match(ab.id)?.winner, id(t, "A"))      // surviving result intact
    }

    // ── Results ──────────────────────────────────────────────────────────────────

    func testSetResultRejectsNonParticipantAndClears() {
        var t = make(["A", "B", "C"])
        let ab = t.matches.first { $0.contains(id(t, "A")) && $0.contains(id(t, "B")) }!

        // C is not in the A–B match → ignored.
        t.setResult(matchID: ab.id, winner: id(t, "C"))
        XCTAssertNil(t.match(ab.id)?.winner)

        t.setResult(matchID: ab.id, winner: id(t, "B"))
        XCTAssertEqual(t.match(ab.id)?.winner, id(t, "B"))
        XCTAssertNotNil(t.match(ab.id)?.playedAt)

        t.clearResult(matchID: ab.id)
        XCTAssertNil(t.match(ab.id)?.winner)
        XCTAssertNil(t.match(ab.id)?.playedAt)
    }

    func testResultsAreOverwritable() {
        var t = make(["A", "B"])
        let ab = t.matches[0]
        t.setResult(matchID: ab.id, winner: id(t, "A"))
        t.setResult(matchID: ab.id, winner: id(t, "B"))
        XCTAssertEqual(t.match(ab.id)?.winner, id(t, "B"))
        XCTAssertEqual(t.wins(for: id(t, "A")), 0)
        XCTAssertEqual(t.wins(for: id(t, "B")), 1)
    }

    // ── Standings ───────────────────────────────────────────────────────────────

    private func win(_ t: inout Tournament, _ winner: String, over loser: String) {
        let m = t.matches.first { $0.contains(id(t, winner)) && $0.contains(id(t, loser)) }!
        t.setResult(matchID: m.id, winner: id(t, winner))
    }

    func testStandingsOrderByWins() {
        var t = make(["A", "B", "C"])
        // A beats B and C; B beats C. → A:2, B:1, C:0.
        win(&t, "A", over: "B")
        win(&t, "A", over: "C")
        win(&t, "B", over: "C")

        let s = t.standings()
        XCTAssertEqual(s.map(\.player.name), ["A", "B", "C"])
        XCTAssertEqual(s.map(\.rank), [1, 2, 3])
        XCTAssertEqual(s[0].wins, 2)
        XCTAssertEqual(s[1].wins, 1)
        XCTAssertEqual(s[2].losses, 2)
    }

    func testSubTableBreaksEqualWinsTie() {
        // Ann and Bob both finish on 2 wins; the sub-table among the tied pair is
        // just their head-to-head, which Bob won → Bob ranks above Ann despite the
        // alphabetical base order. (Cy and Deb sit below on 1 win each.)
        var t = make(["Ann", "Bob", "Cy", "Deb"])
        win(&t, "Bob", over: "Ann")   // sub-table: Bob > Ann
        win(&t, "Ann", over: "Cy")
        win(&t, "Ann", over: "Deb")
        win(&t, "Bob", over: "Cy")
        win(&t, "Deb", over: "Bob")
        win(&t, "Cy", over: "Deb")
        // Ann: Cy, Deb → 2; Bob: Ann, Cy → 2; Cy: Deb → 1; Deb: Bob → 1.

        let s = t.standings()
        let bobRank = s.first { $0.player.name == "Bob" }!.rank
        let annRank = s.first { $0.player.name == "Ann" }!.rank
        XCTAssertEqual(t.wins(for: id(t, "Bob")), 2)
        XCTAssertEqual(t.wins(for: id(t, "Ann")), 2)
        XCTAssertLessThan(bobRank, annRank)
    }

    func testUnbrokenTieSharesRankAndSkips() {
        // A, B, C form a perfect cycle (A>B>C>A) and all three beat D, so they all
        // finish on 2 wins. The sub-table among {A,B,C} is that same cycle — one
        // win each — so the tie is *not* broken: they share rank 1. Standard
        // competition ranking then puts D at rank 4 (positions 2 and 3 are skipped).
        var t = make(["A", "B", "C", "D"])
        win(&t, "A", over: "B"); win(&t, "B", over: "C"); win(&t, "C", over: "A")
        win(&t, "A", over: "D"); win(&t, "B", over: "D"); win(&t, "C", over: "D")

        let s = t.standings()
        let rank = Dictionary(uniqueKeysWithValues: s.map { ($0.player.name, $0.rank) })
        XCTAssertEqual(rank["A"], 1)
        XCTAssertEqual(rank["B"], 1)
        XCTAssertEqual(rank["C"], 1)
        XCTAssertEqual(rank["D"], 4)
    }

    // ── Completion gate + finale ────────────────────────────────────────────────

    func testRoundRobinCompleteGate() {
        var t = make(["A", "B", "C"])
        XCTAssertFalse(t.isRoundRobinComplete)
        XCTAssertEqual(t.openMatchCount, 3)

        win(&t, "A", over: "B")
        win(&t, "A", over: "C")
        XCTAssertFalse(t.isRoundRobinComplete)

        win(&t, "B", over: "C")
        XCTAssertTrue(t.isRoundRobinComplete)
        XCTAssertEqual(t.openMatchCount, 0)
    }

    func testStartFinaleSnapshotsTopTwo() {
        var t = make(["A", "B", "C"])
        // Not complete → cannot start.
        XCTAssertFalse(t.startFinale())
        XCTAssertNil(t.finale)

        win(&t, "A", over: "B")
        win(&t, "A", over: "C")
        win(&t, "B", over: "C")
        XCTAssertTrue(t.startFinale())

        let finale = t.finale!
        XCTAssertEqual(Set([finale.a, finale.b]), Set([id(t, "A"), id(t, "B")]))

        t.setFinaleWinner(id(t, "A"))
        XCTAssertEqual(t.champion?.name, "A")
    }

    func testAddingPlayerReopensRoundRobinAndDropsFinaleReference() {
        var t = make(["A", "B"])
        win(&t, "A", over: "B")
        XCTAssertTrue(t.startFinale())
        XCTAssertNotNil(t.finale)

        // Late entrant: round robin reopens; finale still references valid players
        // (A & B remain), so it survives — but completion is now false.
        t.addPlayer(name: "C")
        XCTAssertFalse(t.isRoundRobinComplete)

        // Removing a finalist invalidates the finale.
        t.removePlayer(id(t, "A"))
        XCTAssertNil(t.finale)
    }

    // ── AI result mapping ───────────────────────────────────────────────────────

    func testAIGameWinnerMapping() {
        let human = UUID(), ai = UUID()
        // Human played White and White won → human wins.
        XCTAssertEqual(Tournament.aiGameWinner(humanID: human, aiID: ai, humanColor: .white, winner: .white), human)
        // Human played White, Black won → AI wins.
        XCTAssertEqual(Tournament.aiGameWinner(humanID: human, aiID: ai, humanColor: .white, winner: .black), ai)
        // Human played Black, Black won → human wins.
        XCTAssertEqual(Tournament.aiGameWinner(humanID: human, aiID: ai, humanColor: .black, winner: .black), human)
    }

    // ── Defaults + persistence round-trip ───────────────────────────────────────

    func testMakeDefaultSeedsGroupAndTavtav() {
        let t = Tournament.makeDefault()
        // The eight human guests plus the AI player.
        XCTAssertEqual(t.players.count, Tournament.defaultPlayerNames.count + 1)
        XCTAssertEqual(t.aiPlayer?.name, "Tavtav")
        XCTAssertTrue(t.hasAI)
        XCTAssertEqual(t.players.filter(\.isAI).count, 1)
        XCTAssertTrue(t.players.contains { $0.name == "Norbert" })
        XCTAssertTrue(t.players.contains { $0.name == "Frida" })
        // A full round robin over N players = N·(N−1)/2 pairings.
        let n = t.players.count
        XCTAssertEqual(t.matches.count, n * (n - 1) / 2)
    }

    func testReAddAIPlayer() {
        var t = Tournament.makeDefault()
        t.removePlayer(t.aiPlayer!.id)
        XCTAssertFalse(t.hasAI)
        t.addAIPlayer()
        XCTAssertTrue(t.hasAI)
        // Re-adding when one exists is a no-op.
        t.addAIPlayer()
        XCTAssertEqual(t.players.filter(\.isAI).count, 1)
    }

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TournamentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TournamentStore(directory: dir)

        XCTAssertNil(store.load())

        var t = make(["A", "B", "C"])
        win(&t, "A", over: "B")
        store.save(t)

        let loaded = store.load()
        XCTAssertEqual(loaded?.players.count, 3)
        XCTAssertEqual(loaded?.matches.count, 3)
        XCTAssertEqual(loaded?.wins(for: id(t, "A")), 1)

        store.clear()
        XCTAssertNil(store.load())
    }
}
