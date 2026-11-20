import XCTest
@testable import TavliEngine

// ── An in-memory Game Center: one server, one service per device ───────────────

/// Simulates Game Center's turn-based server closely enough to exercise the match
/// flows end to end: seats that are filled only when the turn reaches them
/// (auto-match / unresolved invites), invitations that must be accepted, turn
/// hand-off, ending, quitting, and failed sends. Every change is pushed to the other
/// device's controller like a turn notification, unless that device is offline.
@MainActor
final class FakeGameCenter {
    struct Seat {
        var playerID: String?
        /// The player who fills an unresolved seat once the turn reaches it.
        var revealsAs: String?
        var displayName: String?
        var status: OnlineParticipantStatus
        var outcome: OnlineMatchOutcome = .none
    }
    struct Match {
        var data: Data?
        var seats: [Seat]
        var current: Int?
        var isEnded = false
    }

    var matches: [String: Match] = [:]
    var devices: [String: FakeDevice] = [:]
    private var nextID = 1

    /// A new match created by `creator`; the second seat is either a known invitee
    /// (`invited`) or an unfilled auto-match seat that becomes `opponent` later.
    func createMatch(creator: String, opponent: String, opponentKnown: Bool) -> String {
        let id = "m\(nextID)"; nextID += 1
        let other = opponentKnown
            ? Seat(playerID: opponent, displayName: opponent.uppercased(), status: .invited)
            : Seat(playerID: nil, revealsAs: opponent, displayName: nil, status: .matching)
        matches[id] = Match(data: nil,
                            seats: [Seat(playerID: creator, displayName: creator.uppercased(), status: .active), other],
                            current: 0)
        return id
    }

    func snapshot(_ id: String) -> OnlineMatchSnapshot {
        let m = matches[id]!
        return OnlineMatchSnapshot(
            matchID: id, data: m.data,
            participants: m.seats.map {
                OnlineParticipant(playerID: $0.playerID, displayName: $0.displayName,
                                  status: $0.status, outcome: $0.outcome)
            },
            currentPlayerID: m.current.flatMap { m.seats[$0].playerID },
            isEnded: m.isEnded)
    }

    func seatIndex(_ player: String, _ id: String) -> Int? {
        matches[id]!.seats.firstIndex { $0.playerID == player }
    }

    /// Pass the turn to the other seat, filling it if it was unresolved.
    func passTurn(_ id: String, from player: String) {
        guard let me = seatIndex(player, id) else { return }
        let other = 1 - me
        if matches[id]!.seats[other].playerID == nil, let reveal = matches[id]!.seats[other].revealsAs {
            matches[id]!.seats[other].playerID = reveal
            matches[id]!.seats[other].displayName = reveal.uppercased()
            matches[id]!.seats[other].status = .active
        }
        matches[id]!.current = other
    }

    /// Notify every device other than `except` (a turn notification).
    func notify(_ id: String, except player: String) {
        for (pid, device) in devices where pid != player && device.online {
            if matches[id]!.seats.contains(where: { $0.playerID == pid }) {
                device.controller.receive(snapshot(id))
            }
        }
    }
}

@MainActor
final class FakeDevice: OnlineMatchService {
    let localPlayerID: String
    unowned let server: FakeGameCenter
    var controller: OnlineMatchController!
    var online = true
    /// Fail the next N write operations (simulates a dropped connection).
    var failNextWrites = 0
    var acceptedInvites: [String] = []
    var quitCalls = 0

    init(_ id: String, server: FakeGameCenter) {
        localPlayerID = id
        self.server = server
        controller = OnlineMatchController(service: self, animationTimings: .off, retryDelay: nil)
        server.devices[id] = self
    }

    struct Offline: Error {}

    private func write(_ completion: OnlineCompletion, _ body: () -> Void, notify id: String) {
        if failNextWrites > 0 || !online {
            failNextWrites = max(0, failNextWrites - 1)
            completion(Offline())
            return
        }
        body()
        completion(nil)
        server.notify(id, except: localPlayerID)
    }

    func endTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        write(completion, {
            XCTAssertEqual(server.snapshot(matchID).currentPlayerID, localPlayerID, "endTurn out of turn")
            server.matches[matchID]!.data = data
            server.passTurn(matchID, from: localPlayerID)
        }, notify: matchID)
    }

    func saveTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        write(completion, {
            XCTAssertEqual(server.snapshot(matchID).currentPlayerID, localPlayerID, "saveTurn out of turn")
            server.matches[matchID]!.data = data
        }, notify: matchID)
    }

    func endMatch(matchID: String, data: Data, localWon: Bool, completion: @escaping OnlineCompletion) {
        write(completion, {
            XCTAssertEqual(server.snapshot(matchID).currentPlayerID, localPlayerID, "endMatch out of turn")
            var m = server.matches[matchID]!
            m.data = data
            for i in m.seats.indices where m.seats[i].outcome != .quit {
                let isLocal = m.seats[i].playerID == localPlayerID
                m.seats[i].outcome = (isLocal == localWon) ? .won : .lost
                m.seats[i].status = .done
            }
            m.current = nil
            m.isEnded = true
            server.matches[matchID] = m
        }, notify: matchID)
    }

    func quit(matchID: String, data: Data, inTurn: Bool, completion: @escaping OnlineCompletion) {
        quitCalls += 1
        write(completion, {
            guard let me = server.seatIndex(localPlayerID, matchID) else { return }
            server.matches[matchID]!.seats[me].outcome = .quit
            server.matches[matchID]!.seats[me].status = .done
            if inTurn {
                server.matches[matchID]!.data = data
                server.passTurn(matchID, from: localPlayerID)
            }
        }, notify: matchID)
    }

    func acceptInvite(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        acceptedInvites.append(matchID)
        if let me = server.seatIndex(localPlayerID, matchID) {
            server.matches[matchID]!.seats[me].status = .active
        }
        completion(server.snapshot(matchID), nil)
    }

    func load(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        guard online else { completion(nil, Offline()); return }
        completion(server.snapshot(matchID), nil)
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────────

@MainActor
final class OnlineMatchControllerTests: XCTestCase {

    private var server: FakeGameCenter!
    private var alice: FakeDevice!   // creator
    private var bob: FakeDevice!     // opponent

    override func setUp() async throws {
        server = FakeGameCenter()
        alice = FakeDevice("alice", server: server)
        bob = FakeDevice("bob", server: server)
    }

    /// Let deferred record observers (main queue) run.
    private func drain() async {
        for _ in 0..<3 { try? await Task.sleep(nanoseconds: 1_000_000) }
    }

    private struct LCG {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n)) + 1
        }
    }

    /// The device whose turn it is plays the first legal move for a pseudo-random roll.
    @discardableResult
    private func playOneTurn(_ device: FakeDevice, rng: inout LCG) async -> Bool {
        guard let s = device.controller.session, device.controller.isLocalTurn else { return false }
        let d1 = rng.next(6), d2 = rng.next(6)
        let dice = Dice(numberOfSides: 6)
        dice.set(d1, d2)
        let legal = s.game.variant.legalMoves(on: s.game.board, color: s.currentPlayer, dice: dice)
        let pairs = legal.first.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } } ?? []
        XCTAssertTrue(s.applyRemoteMove(PlyRecord(die1: d1, die2: d2, halfMoves: pairs)))
        await drain()
        return true
    }

    /// Alternate turns until the match is over on both devices (or a ply cap).
    private func playOut(rng: inout LCG, cap: Int = 4000) async {
        var plies = 0, stuck = 0
        while plies < cap {
            if alice.controller.isMatchOver && bob.controller.isMatchOver { return }
            if await playOneTurn(alice, rng: &rng) { plies += 1; stuck = 0; continue }
            if await playOneTurn(bob, rng: &rng) { plies += 1; stuck = 0; continue }
            // Neither can move: give an in-flight hand-off a moment, then call it a deadlock.
            await drain()
            stuck += 1
            if stuck > 20 { XCTFail("deadlock: neither device can move"); return }
        }
        XCTFail("match did not finish within \(cap) plies")
    }

    private func create(opponentKnown: Bool, targetWins: Int = 1) -> String {
        let id = server.createMatch(creator: "alice", opponent: "bob", opponentKnown: opponentKnown)
        alice.controller.open(server.snapshot(id), newMatchTargetWins: targetWins)
        return id
    }

    // MARK: - Colours & joining

    /// Auto-match: the opponent's seat is empty when the match is created. The joiner
    /// must still play Black (the old coordinator defaulted both players to White).
    func testAutoMatchJoinerPlaysBlack() async {
        let id = create(opponentKnown: false)
        XCTAssertEqual(alice.controller.localColor, .white)
        XCTAssertTrue(alice.controller.isLocalTurn)

        var rng = LCG(state: 1)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))
        XCTAssertEqual(bob.controller.localColor, .black)
        XCTAssertTrue(bob.controller.isLocalTurn)
        XCTAssertFalse(alice.controller.isLocalTurn)

        await playOneTurn(bob, rng: &rng)
        XCTAssertEqual(alice.controller.session?.history.count, 2, "Bob's move reached Alice")
        XCTAssertTrue(alice.controller.isLocalTurn)
        // Bob's colour is now written into the shared state.
        let colors = server.snapshot(id).payload?.colorByPlayerID
        XCTAssertEqual(colors?["bob"], Color.black.rawValue)
    }

    /// An invited player accepts the invitation before the match opens.
    func testInviteIsAcceptedOnOpen() async {
        let id = create(opponentKnown: true)
        var rng = LCG(state: 2)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))
        XCTAssertEqual(bob.acceptedInvites, [id])
        XCTAssertEqual(bob.controller.localColor, .black)
        XCTAssertTrue(bob.controller.isLocalTurn)
    }

    // MARK: - Whole matches

    /// A full single game: the loser's device applies the winning move from the
    /// match-ended update and shows the result (it used to freeze one move early).
    func testSingleGameBothDevicesSeeTheEnd() async {
        let id = create(opponentKnown: false)
        var rng = LCG(state: 3)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))
        await playOut(rng: &rng)

        XCTAssertTrue(server.matches[id]!.isEnded)
        for c in [alice.controller!, bob.controller!] {
            XCTAssertTrue(c.isMatchOver)
            XCTAssertNotNil(c.pendingGameResult)
            XCTAssertTrue(c.session?.isTerminal ?? false)
            XCTAssertFalse(c.isLocalTurn)
        }
        XCTAssertEqual(alice.controller.session?.history, bob.controller.session?.history)
        // Outcomes agree with the board.
        let winner = alice.controller.session!.record.outcome!
        let aliceWon = winner == alice.controller.localColor
        let outcomes = Dictionary(uniqueKeysWithValues: server.matches[id]!.seats.map { ($0.playerID!, $0.outcome) })
        XCTAssertEqual(outcomes["alice"], aliceWon ? .won : .lost)
        XCTAssertEqual(outcomes["bob"], aliceWon ? .lost : .won)
    }

    /// Best of three: games roll over (starter alternates) and both devices agree on
    /// every game and the final score.
    func testBestOfThreeRunsToCompletionOnBothDevices() async {
        let id = create(opponentKnown: false, targetWins: 2)
        var rng = LCG(state: 4)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))
        await playOut(rng: &rng, cap: 12000)

        let final = server.snapshot(id).payload!
        XCTAssertTrue(final.matchState.isComplete)
        XCTAssertGreaterThanOrEqual(final.games.count, 2)
        XCTAssertEqual(alice.controller.matchState, bob.controller.matchState)
        XCTAssertTrue(alice.controller.matchState.isComplete)
        XCTAssertTrue(server.matches[id]!.isEnded)
    }

    // MARK: - Leaving, quitting, other matches

    /// Going back to the lobby keeps the match; reopening restores it exactly.
    func testCloseDoesNotForfeitAndReopenRestores() async {
        let id = create(opponentKnown: false)
        var rng = LCG(state: 5)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))
        await playOneTurn(bob, rng: &rng)

        let before = alice.controller.session!.history
        alice.controller.close()
        XCTAssertNil(alice.controller.session)
        XCTAssertEqual(alice.quitCalls, 0)
        XCTAssertFalse(server.matches[id]!.isEnded)

        alice.controller.open(server.snapshot(id))
        XCTAssertEqual(alice.controller.session?.history, before)
        XCTAssertTrue(alice.controller.isLocalTurn)
    }

    /// The opponent forfeits: the other device detects it, closes the match as its
    /// own win and locks the board (it used to keep playing into a dead match).
    func testOpponentForfeitIsDetectedAndClosedAsWin() async {
        let id = create(opponentKnown: false)
        var rng = LCG(state: 6)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))
        await playOneTurn(bob, rng: &rng)

        alice.controller.forfeit()            // Alice's turn: quits in turn
        XCTAssertEqual(bob.controller.status, .opponentLeft)
        XCTAssertTrue(bob.controller.isMatchOver)
        XCTAssertFalse(bob.controller.isLocalTurn)
        XCTAssertTrue(server.matches[id]!.isEnded)
        let bobSeat = server.matches[id]!.seats.first { $0.playerID == "bob" }!
        XCTAssertEqual(bobSeat.outcome, .won)
    }

    /// A move in another match never replaces the game on screen.
    func testEventForAnotherMatchDoesNotHijackTheOpenGame() async {
        let a = create(opponentKnown: false)
        var rng = LCG(state: 7)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(a))

        // A second match where it's Bob's turn arrives while Bob is in match A.
        let b = server.createMatch(creator: "carol", opponent: "bob", opponentKnown: true)
        server.matches[b]!.data = server.matches[a]!.data
        server.matches[b]!.current = 1
        let handled = bob.controller.receive(server.snapshot(b))
        XCTAssertFalse(handled)
        XCTAssertEqual(bob.controller.activeMatchID, a)
        XCTAssertEqual(bob.controller.status, .yourTurnElsewhere("CAROL"))
    }

    // MARK: - Failed sends

    /// A move that fails to send stays on the board, a stale reload never rolls it
    /// back, and the next refresh resends it.
    func testFailedSendIsKeptAndResentOnRefresh() async {
        let id = create(opponentKnown: false)
        var rng = LCG(state: 8)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))

        bob.failNextWrites = 1
        await playOneTurn(bob, rng: &rng)
        XCTAssertEqual(bob.controller.status, .sendFailed)
        XCTAssertTrue(bob.controller.hasUnsentTurn)
        XCTAssertEqual(bob.controller.session?.history.count, 2, "the move stays on Bob's board")
        XCTAssertEqual(server.snapshot(id).payload?.games.last?.plies.count, 1, "server never got it")

        bob.controller.refresh()             // reload shows the stale state → resend
        XCTAssertFalse(bob.controller.hasUnsentTurn)
        XCTAssertNil(bob.controller.status)
        XCTAssertEqual(bob.controller.session?.history.count, 2)
        XCTAssertEqual(server.snapshot(id).payload?.games.last?.plies.count, 2)
        XCTAssertEqual(alice.controller.session?.history.count, 2, "Alice finally gets it")
        XCTAssertTrue(alice.controller.isLocalTurn)
    }

    /// A failed send retries on its own once the connection is back.
    func testFailedSendRetriesAutomatically() async {
        let server = FakeGameCenter()
        let a = FakeDevice("alice", server: server)
        let b = FakeDevice("bob", server: server)
        b.controller = OnlineMatchController(service: b, animationTimings: .off, retryDelay: 0.01)
        let id = server.createMatch(creator: "alice", opponent: "bob", opponentKnown: false)
        a.controller.open(server.snapshot(id))
        var rng = LCG(state: 10)
        await playOneTurn(a, rng: &rng)
        b.controller.open(server.snapshot(id))

        b.failNextWrites = 1
        await playOneTurn(b, rng: &rng)
        XCTAssertTrue(b.controller.hasUnsentTurn)
        for _ in 0..<50 where b.controller.hasUnsentTurn {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(b.controller.hasUnsentTurn, "retried without a manual refresh")
        XCTAssertEqual(server.snapshot(id).payload?.games.last?.plies.count, 2)
    }

    /// A late notification carrying an older state never rolls the board back.
    func testStaleUpdateIsIgnored() async {
        let id = create(opponentKnown: false)
        var rng = LCG(state: 11)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))
        let stale = server.snapshot(id)          // Bob to move, 1 ply
        await playOneTurn(bob, rng: &rng)        // now 2 plies, Alice to move
        XCTAssertEqual(bob.controller.session?.history.count, 2)

        bob.controller.receive(stale)            // delayed event arrives
        XCTAssertEqual(bob.controller.session?.history.count, 2, "not rolled back")
        XCTAssertFalse(bob.controller.isLocalTurn)
    }

    /// Catch-up after being offline: several turns applied in one update.
    func testOfflineDeviceCatchesUpOnRefresh() async {
        let id = create(opponentKnown: false)
        var rng = LCG(state: 9)
        await playOneTurn(alice, rng: &rng)
        bob.controller.open(server.snapshot(id))
        await playOneTurn(bob, rng: &rng)

        alice.online = false                 // Alice misses nothing yet; Bob is offline next
        alice.online = true
        bob.online = false
        await playOneTurn(alice, rng: &rng)  // Bob doesn't hear about it
        XCTAssertEqual(bob.controller.session?.history.count, 2)
        bob.online = true
        bob.controller.refresh()
        XCTAssertEqual(bob.controller.session?.history.count, 3)
        XCTAssertTrue(bob.controller.isLocalTurn)
    }
}
