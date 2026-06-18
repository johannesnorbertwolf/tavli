import XCTest
@testable import TavliEngine

/// Multi-iPad sync: the entity-level last-writer-wins `merged(with:)` and the
/// in-process `LoopbackTransport`. These cover the correctness-critical part —
/// concurrent-edit conflict resolution — with zero devices (the real radio,
/// `MultipeerTransport`, is app-target glue verified by `xcodebuild`).
final class TournamentSyncTests: XCTestCase {

    private let deviceA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let deviceB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let deviceC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

    // Build a human-only tournament (deterministic) on a given device.
    private func tournament(_ names: [String], by device: UUID) -> Tournament {
        var t = Tournament()
        for n in names { t.addPlayer(name: n, by: device) }
        return t
    }

    private func pid(_ t: Tournament, _ name: String) -> UUID { t.players.first { $0.name == name }!.id }

    private func mid(_ t: Tournament, _ x: String, _ y: String) -> UUID {
        t.matches.first { $0.contains(pid(t, x)) && $0.contains(pid(t, y)) }!.id
    }

    /// Winner of a pairing by player names — works across devices (the per-device
    /// match id differs; the pair is the stable identity).
    private func winner(_ t: Tournament, _ x: String, _ y: String) -> String? {
        let xid = pid(t, x), yid = pid(t, y)
        return t.matches.first { $0.contains(xid) && $0.contains(yid) }?.winner.flatMap { t.name($0) }
    }

    // ── Idempotence / no-op ───────────────────────────────────────────────────────

    func testMergeOfIdenticalIsNoOp() {
        let t = Tournament.makeDefault()
        XCTAssertEqual(t.merged(with: t), t)
        let (m, changed) = t.mergingForSync(t)
        XCTAssertFalse(changed)
        XCTAssertEqual(m, t)
    }

    func testTwoPristineDevicesMergeToNoChange() {
        // Both seed the fixed roster independently. They share player ids (fixed seed)
        // but each has its own random match ids — so they're not byte-identical, yet
        // merging brings nothing new: each side keeps its own ids and no results move.
        // The property that matters for sync is that the merge is a *no-op* both ways.
        let a = Tournament.makeDefault()
        let b = Tournament.makeDefault()
        XCTAssertFalse(a.mergingForSync(b).changed)   // a unchanged by b
        XCTAssertFalse(b.mergingForSync(a).changed)   // b unchanged by a
        XCTAssertEqual(a.merged(with: b), a)
        XCTAssertEqual(b.merged(with: a), b)
    }

    // ── Results ───────────────────────────────────────────────────────────────────

    func testConcurrentDifferentMatchResultsBothSurvive() {
        let base = tournament(["P", "Q", "R"], by: deviceA)
        var a = base, b = base
        a.setResult(matchID: mid(base, "P", "Q"), winner: pid(a, "P"), by: deviceA)
        b.setResult(matchID: mid(base, "P", "R"), winner: pid(b, "R"), by: deviceB)

        let m = a.merged(with: b)
        XCTAssertEqual(winner(m, "P", "Q"), "P")   // A's edit
        XCTAssertEqual(winner(m, "P", "R"), "R")   // B's edit — not clobbered

        // Commutative: the other merge order yields the same content.
        let n = b.merged(with: a)
        XCTAssertEqual(winner(n, "P", "Q"), "P")
        XCTAssertEqual(winner(n, "P", "R"), "R")
    }

    func testConcurrentSameMatchResolvesByStampDeterministically() {
        let base = tournament(["P", "Q"], by: deviceA)
        let pq = mid(base, "P", "Q")
        var a = base, b = base
        b.setResult(matchID: pq, winner: pid(b, "Q"), by: deviceB)   // counter n
        a.setResult(matchID: pq, winner: pid(a, "P"), by: deviceA)   // counter n
        a.setResult(matchID: pq, winner: pid(a, "Q"), by: deviceA)   // counter n+1 → newest

        XCTAssertEqual(winner(a.merged(with: b), "P", "Q"), "Q")
        XCTAssertEqual(winner(b.merged(with: a), "P", "Q"), "Q")     // same on both peers
    }

    func testClearBeatsStaleSet() {
        var base = tournament(["P", "Q"], by: deviceA)
        let pq = mid(base, "P", "Q")
        base.setResult(matchID: pq, winner: pid(base, "P"), by: deviceA)
        let a = base                                  // keeps the set result
        var b = base
        b.clearResult(matchID: pq, by: deviceB)       // later op → clear wins
        XCTAssertNil(winner(a.merged(with: b), "P", "Q"))
        XCTAssertNil(winner(b.merged(with: a), "P", "Q"))
    }

    // ── Players (LWW-element-set) ──────────────────────────────────────────────────

    func testAddedPlayerPropagates() {
        let base = tournament(["P", "Q", "R"], by: deviceA)
        var a = base
        a.addPlayer(name: "Zoe", by: deviceA)

        let m = base.merged(with: a)
        XCTAssertTrue(m.players.contains { $0.name == "Zoe" })
        XCTAssertEqual(m.players.count, 4)
        XCTAssertEqual(m.matches.count, 6)   // C(4,2): Zoe paired with each
    }

    func testRemovalTombstoneBeatsStaleActive() {
        let base = tournament(["P", "Q", "R"], by: deviceA)
        var a = base
        a.removePlayer(pid(base, "P"), by: deviceA)

        // B still has P; merging A's tombstone (newer) removes P everywhere.
        let m = base.merged(with: a)
        XCTAssertFalse(m.players.contains { $0.name == "P" })
        XCTAssertFalse(m.matches.contains { $0.contains(self.pid(base, "P")) })
        // Both directions agree.
        XCTAssertFalse(a.merged(with: base).players.contains { $0.name == "P" })
    }

    func testRenamePropagatesByStamp() {
        let base = tournament(["P", "Q"], by: deviceA)
        var a = base
        a.renamePlayer(pid(base, "P"), to: "Pete", by: deviceA)

        let m = base.merged(with: a)
        XCTAssertTrue(m.players.contains { $0.name == "Pete" })
        XCTAssertFalse(m.players.contains { $0.name == "P" })
    }

    func testReAddedAIBeatsItsOwnTombstone() {
        let base = Tournament.makeDefault()
        var a = base
        a.removePlayer(Tournament.seedAIPlayerID, by: deviceA)   // tombstone
        a.addAIPlayer(by: deviceA)                                // un-tombstone, newer

        // B still has the seed TavTav (.zero). The re-add (newest) wins on both.
        XCTAssertTrue(base.merged(with: a).hasAI)
        XCTAssertTrue(a.merged(with: base).hasAI)
    }

    func testRemovedAIStaysRemovedAgainstStalePeer() {
        let base = Tournament.makeDefault()
        var a = base
        a.removePlayer(Tournament.seedAIPlayerID, by: deviceA)
        XCTAssertFalse(base.merged(with: a).hasAI)
        XCTAssertFalse(a.merged(with: base).hasAI)
    }

    // ── Finale (LWW register) ──────────────────────────────────────────────────────

    func testFinaleWinnerPropagates() {
        var base = tournament(["P", "Q"], by: deviceA)
        base.setResult(matchID: mid(base, "P", "Q"), winner: pid(base, "P"), by: deviceA)
        var a = base
        XCTAssertTrue(a.startFinale(by: deviceA))
        a.setFinaleWinner(pid(a, "P"), by: deviceA)

        let m = base.merged(with: a)          // B had no finale
        XCTAssertEqual(m.champion?.name, "P")
    }

    func testFinaleClearBeatsStaleWinner() {
        var base = tournament(["P", "Q"], by: deviceA)
        base.setResult(matchID: mid(base, "P", "Q"), winner: pid(base, "P"), by: deviceA)
        base.startFinale(by: deviceA)
        base.setFinaleWinner(pid(base, "P"), by: deviceA)
        let a = base                          // keeps champion P
        var b = base
        b.clearFinale(by: deviceB)            // newer → clears
        XCTAssertNil(a.merged(with: b).finale)
        XCTAssertNil(b.merged(with: a).finale)
    }

    // ── Loopback transport: 3-node gossip converges ────────────────────────────────

    /// A minimal sync node: merge on receive, rebroadcast only when something
    /// changed (mirrors what `TournamentModel` does in the app).
    private final class Node {
        var t: Tournament
        let device = UUID()
        let transport: LoopbackTransport
        private(set) var peerNames: [String] = []

        init(_ initial: Tournament, name: String, hub: LoopbackHub) {
            self.t = initial
            self.transport = LoopbackTransport(name: name, hub: hub)
            transport.onReceive = { [weak self] incoming in
                guard let self else { return }
                let (merged, changed) = self.t.mergingForSync(incoming)
                if changed { self.t = merged; self.transport.broadcast(merged) }
            }
            transport.onPeersChanged = { [weak self] names in self?.peerNames = names }
        }

        func start() { transport.start() }
        func edit(_ block: (inout Tournament, UUID) -> Void) {
            block(&t, device)
            transport.broadcast(t)
        }
    }

    func testLoopbackHubConnectsPeers() {
        let hub = LoopbackHub()
        let base = Tournament.makeDefault()
        let n1 = Node(base, name: "iPad-1", hub: hub)
        let n2 = Node(base, name: "iPad-2", hub: hub)
        let n3 = Node(base, name: "iPad-3", hub: hub)
        n1.start(); n2.start(); n3.start()
        XCTAssertEqual(n1.peerNames.count, 2)
        XCTAssertEqual(Set(n1.peerNames), ["iPad-2", "iPad-3"])
        n3.transport.stop()
        XCTAssertEqual(n1.peerNames.count, 1)
    }

    func testThreeNodesConvergeOnConcurrentEdits() {
        let hub = LoopbackHub()
        let base = Tournament.makeDefault()   // shared base → identical match ids
        let n1 = Node(base, name: "iPad-1", hub: hub)
        let n2 = Node(base, name: "iPad-2", hub: hub)
        let n3 = Node(base, name: "iPad-3", hub: hub)
        n1.start(); n2.start(); n3.start()

        n1.edit { t, d in t.setResult(matchID: t.matches.first { $0.contains(self.pid(t, "Norbert")) && $0.contains(self.pid(t, "Gisela")) }!.id, winner: self.pid(t, "Norbert"), by: d) }
        n2.edit { t, d in t.setResult(matchID: t.matches.first { $0.contains(self.pid(t, "Johannes")) && $0.contains(self.pid(t, "Theo")) }!.id, winner: self.pid(t, "Theo"), by: d) }
        n3.edit { t, d in t.setResult(matchID: t.matches.first { $0.contains(self.pid(t, "Albert")) && $0.contains(self.pid(t, "Frida")) }!.id, winner: self.pid(t, "Frida"), by: d) }

        // All three converge to identical state, with every edit preserved.
        XCTAssertEqual(n1.t, n2.t)
        XCTAssertEqual(n2.t, n3.t)
        XCTAssertEqual(winner(n1.t, "Norbert", "Gisela"), "Norbert")
        XCTAssertEqual(winner(n1.t, "Johannes", "Theo"), "Theo")
        XCTAssertEqual(winner(n1.t, "Albert", "Frida"), "Frida")
    }

    func testLoopbackPlayerRemovalConverges() {
        let hub = LoopbackHub()
        let base = Tournament.makeDefault()
        let n1 = Node(base, name: "iPad-1", hub: hub)
        let n2 = Node(base, name: "iPad-2", hub: hub)
        n1.start(); n2.start()

        n2.edit { t, d in t.removePlayer(self.pid(t, "Caspar"), by: d) }
        XCTAssertEqual(n1.t, n2.t)
        XCTAssertFalse(n1.t.players.contains { $0.name == "Caspar" })
    }
}
