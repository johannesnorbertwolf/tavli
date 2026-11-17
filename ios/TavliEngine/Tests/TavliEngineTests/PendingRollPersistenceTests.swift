import Foundation
import XCTest
@testable import TavliEngine

/// #171 — the roll of the turn in progress survives a crash/relaunch: `snapshot`
/// carries it as `GameSave.pendingRoll`, and `resume` + `start()` re-enter the turn
/// with exactly those dice (no new roll), for the human and the AI, in every variant.
/// No model or fixtures needed (the AI side uses the random fallback).
@MainActor
final class PendingRollPersistenceTests: XCTestCase {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private func pairs(_ moves: [Move]) -> [[[Int]]] {
        moves.map { $0.halfMoves.map { [$0.from.position, $0.to.position] } }
    }

    private func signature(_ s: GameSession) -> [[Color]] { s.game.board.points.map(\.pieces) }

    private func legal(_ s: GameSession, _ d1: Int, _ d2: Int) -> [Move] {
        let dice = Dice(numberOfSides: 6)
        dice.set(d1, d2)
        return s.game.variant.legalMoves(on: s.game.board, color: s.currentPlayer, dice: dice)
    }

    /// A roll (random order) that has at least one legal move for the side on move.
    private func playableRoll(_ s: GameSession, using rng: inout SplitMix64) -> (Int, Int)? {
        var rolls: [(Int, Int)] = []
        for a in 1...6 { for b in 1...6 { rolls.append((a, b)) } }
        rolls.shuffle(using: &rng)
        return rolls.first { !legal(s, $0.0, $0.1).isEmpty }
    }

    /// A roll with no legal move for the side on move, if any.
    private func blockedRoll(_ s: GameSession) -> (Int, Int)? {
        for a in 1...6 { for b in a...6 where legal(s, a, b).isEmpty { return (a, b) } }
        return nil
    }

    /// Play one whole turn through the session intents with `d1`/`d2`.
    private func playTurn(_ s: GameSession, _ d1: Int, _ d2: Int, pick: Int = 0) {
        guard s.phase == .awaitingRoll else { return }
        s.setDice(d1, d2)
        let active = s.moveBuilder.activeMoves
        guard !active.isEmpty else { return }   // forced pass
        let chosen = active[pick % active.count]
        while s.phase == .picking || s.phase == .moving {
            guard let h = nextOfferedHalf(s.moveBuilder, of: chosen) else {
                XCTFail("no legal play order for \(chosen)"); return
            }
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
    }

    private func encodeDecode(_ save: GameSave) throws -> GameSave {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(GameSave.self, from: enc.encode(save))
    }

    private func jsonObject(_ save: GameSave) throws -> [String: Any] {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: enc.encode(save)) as! [String: Any]
    }

    // ── Human turn round trip, every variant ───────────────────────────────────

    /// Roll → snapshot → JSON → resume → start gives the same dice, the same legal
    /// moves, the same board and history, lands in `.picking`, and consumes no new
    /// roll — with auto-roll off and on. Portes is additionally driven to a position
    /// where the mover has a checker on the bar (bar entry).
    func testHumanRollRoundTripsInEveryVariant() throws {
        for variant in GameVariants.all {
            for autoRoll in [false, true] {
                var rng = SplitMix64(seed: 0x171)
                let config = GameConfig(variant: variant)
                let needsBar = variant.id == "portes"
                func onBar(_ s: GameSession) -> Bool {
                    BoardLayout.barCount(s.currentPlayer, stacks: s.game.board.captureStacks(),
                                         variant: variant) > 0
                }
                var a = GameSession(startingPlayer: .white, config: config, animationTimings: .off)
                // Random moves (so Portes hits happen); restart a finished game until the
                // position wanted is reached (12+ plies; Portes: mover on the bar).
                for _ in 0..<50 {
                    a = GameSession(startingPlayer: .white, config: config, animationTimings: .off)
                    var turns = 0
                    while a.phase == .awaitingRoll && (turns < 12 || (needsBar && !onBar(a))) {
                        guard let r = playableRoll(a, using: &rng) else { break }
                        playTurn(a, r.0, r.1, pick: Int(rng.next() % 64))
                        turns += 1
                    }
                    if a.phase == .awaitingRoll && (!needsBar || onBar(a)) { break }
                }
                XCTAssertEqual(a.phase, .awaitingRoll, variant.id)
                XCTAssertNil(a.pendingRoll, "\(variant.id): no roll pending between turns")
                if variant.id == "portes" {
                    XCTAssertGreaterThan(BoardLayout.barCount(a.currentPlayer,
                                                              stacks: a.game.board.captureStacks(),
                                                              variant: variant), 0,
                                         "portes: expected a bar-entry position")
                }
                guard let r = playableRoll(a, using: &rng) else { return XCTFail(variant.id) }
                a.setDice(r.0, r.1)
                XCTAssertEqual(a.phase, .picking, variant.id)
                XCTAssertEqual(a.pendingRoll, PendingRoll(die1: r.0, die2: r.1), variant.id)

                let save = try encodeDecode(a.snapshot(name: "mid-turn"))
                XCTAssertEqual(save.pendingRoll, PendingRoll(die1: r.0, die2: r.1), variant.id)
                XCTAssertEqual(save.schemaVersion, 1, "\(variant.id): pendingRoll never bumps the schema")

                let b = GameSession.resume(from: save, animationTimings: .off, autoRoll: autoRoll)
                XCTAssertEqual(b.pendingRoll, save.pendingRoll, variant.id)
                b.start()
                XCTAssertEqual(b.phase, .picking, "\(variant.id) autoRoll=\(autoRoll)")
                XCTAssertEqual(b.game.dice.die1.value, r.0, variant.id)
                XCTAssertEqual(b.game.dice.die2.value, r.1, variant.id)
                XCTAssertEqual(pairs(b.legalMoves), pairs(a.legalMoves), variant.id)
                XCTAssertEqual(signature(b), signature(a), variant.id)
                XCTAssertEqual(b.currentPlayer, a.currentPlayer, variant.id)
                XCTAssertEqual(b.history, a.history, variant.id)
                // Nothing re-rolls afterwards (an auto-roll task would change the dice).
                try await_(0.05)
                XCTAssertEqual(b.phase, .picking, variant.id)
                XCTAssertEqual(b.game.dice.die1.value, r.0, variant.id)
                XCTAssertEqual(b.game.dice.die2.value, r.1, variant.id)
                XCTAssertEqual(b.pendingRoll, PendingRoll(die1: r.0, die2: r.1), variant.id)

                // The restored turn plays on normally and clears the pending roll.
                let chosen = b.moveBuilder.activeMoves.first!
                while b.phase == .picking || b.phase == .moving {
                    guard let h = nextOfferedHalf(b.moveBuilder, of: chosen) else { break }
                    b.commitHalfMove(from: h.from.position, to: h.to.position)
                }
                XCTAssertEqual(b.history.count, a.history.count + 1, variant.id)
                XCTAssertEqual(b.history.last?.die1, r.0, variant.id)
                XCTAssertEqual(b.history.last?.die2, r.1, variant.id)
                XCTAssertNil(b.pendingRoll, variant.id)
            }
        }
    }

    /// `roll()` (a tap) records the pending roll and bumps `rollRevision` — the app's
    /// autosave trigger — and the move that consumes it clears it again.
    func testTapRollPublishesPendingRollAndRevision() {
        let s = GameSession(startingPlayer: .white, animationTimings: .off)
        XCTAssertNil(s.pendingRoll)
        let rev = s.rollRevision
        s.roll()
        XCTAssertEqual(s.rollRevision, rev + 1)
        XCTAssertEqual(s.pendingRoll, PendingRoll(die1: s.game.dice.die1.value, die2: s.game.dice.die2.value))
        XCTAssertNotNil(s.snapshot(name: "x").pendingRoll)
        guard s.phase == .picking else { return }   // (a pass already cleared it)
        let chosen = s.moveBuilder.activeMoves.first!
        while s.phase == .picking || s.phase == .moving {
            guard let h = nextOfferedHalf(s.moveBuilder, of: chosen) else { break }
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
        XCTAssertNil(s.pendingRoll)
        XCTAssertNil(s.snapshot(name: "y").pendingRoll)
    }

    /// Auto-roll (animated tumble) publishes the roll as soon as it is made, before
    /// the tumble settles — and a save taken mid-tumble resumes straight to `.picking`.
    func testAutoRollPublishesRollBeforeTumbleSettles() async throws {
        let s = GameSession(startingPlayer: .white,
                            animationTimings: AnimationTimings(aiDiceRollDuration: 5, aiMoveAnimationDuration: 0),
                            autoRoll: true)
        s.start()
        for _ in 0..<200 where s.pendingRoll == nil { await Task.yield() }
        let roll = try XCTUnwrap(s.pendingRoll)
        XCTAssertTrue(s.humanDiceRolling)
        let save = s.snapshot(name: "tumbling")
        s.newGame()   // cancel the old tumble

        let b = GameSession.resume(from: save, animationTimings: .off, autoRoll: true)
        b.start()
        XCTAssertEqual(PendingRoll(die1: b.game.dice.die1.value, die2: b.game.dice.die2.value), roll)
        XCTAssertFalse(b.humanDiceRolling)
        if b.phase == .picking {
            XCTAssertEqual(pairs(b.legalMoves), pairs(legal(b, roll.die1, roll.die2)))
        } else {
            XCTAssertEqual(b.history.count, 1, "a blocked roll passes as it would live")
        }
    }

    // ── AI turn ────────────────────────────────────────────────────────────────

    /// A save taken after the AI rolled (mid-animation) resumes with the AI playing
    /// that same roll — not a new one — in every variant.
    func testAIRollResumesWithSameDice() throws {
        for variant in GameVariants.all {
            let config = GameConfig(variant: variant)
            // Long timings: the AI's roll is made up front, then the turn sits animating.
            let a = GameSession(startingPlayer: .black, config: config, aiColor: .black,
                                animationTimings: AnimationTimings(aiDiceRollDuration: 30,
                                                                   aiMoveAnimationDuration: 30))
            a.start()
            XCTAssertEqual(a.phase, .animating, variant.id)
            let roll = try XCTUnwrap(a.pendingRoll, variant.id)
            let save = try encodeDecode(a.snapshot(name: "ai-rolled"))
            XCTAssertEqual(save.pendingRoll, roll, variant.id)
            a.newGame()   // cancel the in-flight animation

            let b = GameSession.resume(from: save, config: config, animationTimings: .off)
            XCTAssertEqual(b.aiColor, .black, variant.id)
            b.start()
            XCTAssertEqual(b.history.count, 1, "\(variant.id): the AI played on resume")
            XCTAssertEqual(b.history.first?.die1, roll.die1, variant.id)
            XCTAssertEqual(b.history.first?.die2, roll.die2, variant.id)
            XCTAssertEqual(b.currentPlayer, .white, variant.id)
            XCTAssertEqual(b.phase, .awaitingRoll, variant.id)
            XCTAssertNil(b.pendingRoll, variant.id)
        }
    }

    // ── Forced pass, awaiting roll, two-player ────────────────────────────────

    /// A restored roll with no legal move runs the live forced-pass path.
    func testRestoredBlockedRollPasses() throws {
        var rng = SplitMix64(seed: 0xB10C)
        let a = GameSession(startingPlayer: .white, animationTimings: .off)
        var found: (Int, Int)? = nil
        for _ in 0..<600 {
            guard a.phase == .awaitingRoll else { break }
            if let b = blockedRoll(a) { found = b; break }
            guard let r = playableRoll(a, using: &rng) else { break }
            playTurn(a, r.0, r.1)
        }
        let blocked = try XCTUnwrap(found, "no blocked position reached")
        var save = a.snapshot(name: "blocked")
        save.pendingRoll = PendingRoll(die1: blocked.0, die2: blocked.1)
        let mover = a.currentPlayer

        let b = GameSession.resume(from: try encodeDecode(save), animationTimings: .off)
        b.start()
        XCTAssertEqual(b.history.count, a.history.count + 1)
        XCTAssertEqual(b.history.last?.halfMoves, [])
        XCTAssertEqual(b.history.last?.die1, blocked.0)
        XCTAssertEqual(b.history.last?.die2, blocked.1)
        XCTAssertEqual(b.currentPlayer, mover.opponent)
        XCTAssertEqual(b.phase, .awaitingRoll)
    }

    /// A save taken while awaiting a roll has no pending roll and resumes awaiting a
    /// roll exactly as before; its JSON carries no `pendingRoll` key.
    func testSaveAwaitingRollResumesAwaitingRoll() throws {
        var rng = SplitMix64(seed: 7)
        let a = GameSession(startingPlayer: .white, animationTimings: .off)
        for _ in 0..<4 { if let r = playableRoll(a, using: &rng) { playTurn(a, r.0, r.1) } }
        let save = a.snapshot(name: "between")
        XCTAssertNil(save.pendingRoll)
        XCTAssertNil(try jsonObject(save)["pendingRoll"])
        let b = GameSession.resume(from: try encodeDecode(save), animationTimings: .off)
        XCTAssertEqual(b.phase, .awaitingRoll)
        b.start()
        XCTAssertEqual(b.phase, .awaitingRoll)
        XCTAssertNil(b.pendingRoll)
        XCTAssertEqual(signature(b), signature(a))
        b.roll()   // a fresh roll works as usual
        XCTAssertNotNil(b.pendingRoll)
    }

    /// A Full Tavli leg's snapshot carries both the session and the pending roll.
    func testFullTavliSnapshotCarriesPendingRoll() throws {
        let ft = FullTavliSession(plakotoVariantID: "plakoto", aiColor: nil)
        let s = GameSession(startingPlayer: .white, config: GameConfig(variant: GameVariants.portes),
                            animationTimings: .off)
        s.setDice(6, 1)
        let save = try encodeDecode(s.snapshot(name: "leg", fullTavli: ft))
        XCTAssertNotNil(save.fullTavli)
        XCTAssertEqual(save.pendingRoll, PendingRoll(die1: 6, die2: 1))
        let b = GameSession.resume(from: save, animationTimings: .off)
        b.start()
        XCTAssertEqual(b.phase, .picking)
        XCTAssertEqual(pairs(b.legalMoves), pairs(s.legalMoves))
    }

    // ── Wire format ───────────────────────────────────────────────────────────

    /// Invalid or malformed stored dice are ignored (the save still loads, awaiting a roll).
    func testInvalidStoredDiceAreIgnored() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for bad in [#"{"die1":0,"die2":3}"#, #"{"die1":4,"die2":7}"#, #"{"die1":-1,"die2":2}"#,
                    #"{"die1":"x","die2":2}"#, #"[3,4]"#, #""oops""#, #"{"die1":3}"#] {
            let json = """
            {"schemaVersion":1,"name":"bad","savedAt":"2026-01-01T00:00:00Z",
             "startingPlayer":"W","history":[],"pendingRoll":\(bad)}
            """
            let save = try dec.decode(GameSave.self, from: Data(json.utf8))
            XCTAssertNil(save.pendingRoll, bad)
            let s = GameSession.resume(from: save, animationTimings: .off)
            s.start()
            XCTAssertEqual(s.phase, .awaitingRoll, bad)
        }
        // A valid one decodes (doubles are two equal values).
        let ok = """
        {"schemaVersion":2,"name":"ok","savedAt":"2026-01-01T00:00:00Z",
         "startingPlayer":"W","history":[],"pendingRoll":{"die1":4,"die2":4}}
        """
        XCTAssertEqual(try dec.decode(GameSave.self, from: Data(ok.utf8)).pendingRoll,
                       PendingRoll(die1: 4, die2: 4))
        // A programmatically invalid roll is ignored by resume too.
        var save = GameSession(startingPlayer: .white).snapshot(name: "p")
        save.pendingRoll = PendingRoll(die1: 9, die2: 1)
        let s = GameSession.resume(from: save, animationTimings: .off)
        XCTAssertNil(s.pendingRoll)
        s.start()
        XCTAssertEqual(s.phase, .awaitingRoll)
    }

    /// Back-compat: literal v1 and v2 payloads (no `pendingRoll`) decode unchanged,
    /// and a save without a pending roll encodes byte-identically to the pre-#171 shape.
    func testOlderSavesDecodeAndNoRollIsUnchangedFormat() throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let v1 = """
        {"schemaVersion":1,"name":"old","savedAt":"2026-01-01T00:00:00Z",
         "startingPlayer":"W","aiColor":"B","history":[{"die1":3,"die2":5,"halfMoves":[[1,4],[1,6]]}]}
        """
        let s1 = try dec.decode(GameSave.self, from: Data(v1.utf8))
        XCTAssertEqual(s1.schemaVersion, 1)
        XCTAssertNil(s1.pendingRoll)
        let r1 = GameSession.resume(from: s1, animationTimings: .off)
        XCTAssertEqual(r1.phase, .awaitingRoll)
        XCTAssertEqual(r1.history.count, 1)

        let v2 = """
        {"schemaVersion":2,"name":"v2","savedAt":"2026-01-01T00:00:00Z","startingPlayer":"W",
         "history":[],"analysis":[{"plyNumber":1,"playedMove":[[1,4]],"playedScore":0.5,
         "bestMove":[[1,4]],"bestScore":0.6,"depth":2}]}
        """
        let s2 = try dec.decode(GameSave.self, from: Data(v2.utf8))
        XCTAssertEqual(s2.schemaVersion, 2)
        XCTAssertEqual(s2.analysis?.count, 1)
        XCTAssertNil(s2.pendingRoll)

        // No pending roll ⇒ the key is absent and the version stays 1.
        let plain = GameSave(name: "n", savedAt: Date(timeIntervalSince1970: 0),
                             startingPlayer: "W", aiColor: nil, history: [])
        let obj = try jsonObject(plain)
        XCTAssertNil(obj["pendingRoll"])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(Set(obj.keys), ["schemaVersion", "name", "savedAt", "startingPlayer", "history", "variant"])
        // With a pending roll: still v1, one extra key.
        var rolled = plain
        rolled.pendingRoll = PendingRoll(die1: 2, die2: 6)
        let robj = try jsonObject(rolled)
        XCTAssertEqual(robj["schemaVersion"] as? Int, 1)
        XCTAssertEqual(Set(robj.keys).subtracting(obj.keys), ["pendingRoll"])
    }

    /// Through `SaveStore` too: the autosave slot keeps the pending roll.
    func testAutosaveSlotKeepsPendingRoll() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-roll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SaveStore(directory: dir)
        let s = GameSession(startingPlayer: .white, animationTimings: .off)
        s.setDice(5, 2)
        try store.writeAutosave(s.snapshot(name: "auto"))
        XCTAssertEqual(store.loadAutosave()?.pendingRoll, PendingRoll(die1: 5, die2: 2))
    }

    /// Drill sessions seed their own dice and are unaffected.
    func testDrillSeedingUnaffected() {
        let s = GameSession(startingPlayer: .white)
        let d = GameSession.drill(boardStacks: s.game.board.captureStacks(), die1: 6, die2: 4, mover: .white)
        XCTAssertEqual(d.phase, .picking)
        XCTAssertEqual(d.game.dice.die1.value, 6)
        XCTAssertEqual(d.game.dice.die2.value, 4)
    }

    private func await_(_ seconds: TimeInterval) throws {
        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }
}
