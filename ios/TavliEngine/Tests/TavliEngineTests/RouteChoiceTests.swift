import XCTest
@testable import TavliEngine

/// #169 — Portes: one checker moved with both dice (or 2-4 steps of a double) in one
/// gesture. Routes ending in the same position play directly; routes ending in different
/// positions (hit vs no hit, different blots) enter a pending `routeChoice` that the
/// player resolves by tapping an intermediate point, or cancels with nothing played.
///
/// White moves up the board (enters from its bar at 0, bears off at 25). Every position
/// parks White's other 14 checkers on 24 (immobile while one is outside home) and Black's
/// spare checkers on 1, out of the way.
@MainActor
final class RouteChoiceTests: XCTestCase {

    private func session(white: [Int: Int], black: [Int: Int], whiteBar: Int = 0,
                         dice: (Int, Int)) -> GameSession {
        let s = GameSession(startingPlayer: .white, config: GameConfig(variant: GameVariants.portes),
                            animationTimings: .off)
        PortesVariant.setPosition(on: s.game.board, white: white, black: black, whiteBar: whiteBar)
        s.setManualDice(dice.0, dice.1)
        return s
    }

    private func stacks(_ s: GameSession) -> [[Color]] { s.game.board.captureStacks() }
    private func blackBar(_ s: GameSession) -> Int { PortesVariant.barCount(.black, on: s.game.board) }
    private func whiteAt(_ s: GameSession, _ p: Int) -> Int { s.game.board.points[p].countForColor(.white) }

    // ── Two dice, one checker ─────────────────────────────────────────────────

    /// Both routes 5→7→10 and 5→8→10 land on empty points: one result, played at once.
    func testUnambiguousRoutesPlayInOneGesture() {
        let s = session(white: [5: 1, 24: 14], black: [1: 15], dice: (2, 3))
        XCTAssertTrue(s.moveBuilder.validDestinations(for: 5).contains(10))
        XCTAssertEqual(s.moveBuilder.routeOptions(from: 5, to: 10).count, 1)
        s.selectPoint(5)
        s.commitHalfMove(from: 5, to: 10)
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(whiteAt(s, 10), 1)
        XCTAssertEqual(whiteAt(s, 5), 0)
        XCTAssertEqual(s.currentPlayer, .black, "both dice used — the turn is over")
        XCTAssertEqual(s.record.plies.last?.halfMoves.count, 2)
    }

    /// A blot on 7 but not on 8: hitting or not are different positions → choose.
    func testHitVersusNoHitAsksForTheRoute() {
        let s = session(white: [5: 1, 24: 14], black: [7: 1, 1: 14], dice: (2, 3))
        let before = stacks(s)
        s.selectPoint(5)
        s.commitHalfMove(from: 5, to: 10)
        let choice = try! XCTUnwrap(s.routeChoice)
        XCTAssertEqual(choice.source, 5)
        XCTAssertEqual(choice.destination, 10)
        XCTAssertEqual(choice.intermediatePoints, [7, 8])
        XCTAssertEqual(stacks(s), before, "nothing is played until a route is chosen")
        XCTAssertTrue(s.moveBuilder.built.isEmpty)
        XCTAssertEqual(s.phase, .moving)

        s.chooseRoute(via: 7)
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(blackBar(s), 1, "route via 7 hits the blot")
        XCTAssertEqual(whiteAt(s, 10), 1)
        XCTAssertEqual(s.currentPlayer, .black)
    }

    func testChoosingTheQuietRouteDoesNotHit() {
        let s = session(white: [5: 1, 24: 14], black: [7: 1, 1: 14], dice: (2, 3))
        s.commitHalfMove(from: 5, to: 10)
        s.chooseRoute(via: 8)
        XCTAssertEqual(blackBar(s), 0)
        XCTAssertEqual(s.game.board.points[7].countForColor(.black), 1)
        XCTAssertEqual(whiteAt(s, 10), 1)
    }

    /// Blots on 7 and 8: both routes hit, but different checkers → still a choice.
    func testHitsOnTwoDifferentBlotsAskForTheRoute() {
        let s = session(white: [5: 1, 24: 14], black: [7: 1, 8: 1, 1: 13], dice: (2, 3))
        s.commitHalfMove(from: 5, to: 10)
        XCTAssertEqual(s.routeChoice?.intermediatePoints, [7, 8])
        s.chooseRoute(via: 8)
        XCTAssertEqual(blackBar(s), 1)
        XCTAssertEqual(s.game.board.points[7].countForColor(.black), 1, "the blot on 7 survives")
        XCTAssertEqual(s.game.board.points[8].countForColor(.black), 0)
    }

    /// A made point on 7 leaves only the route via 8 — a single route plays directly,
    /// even when it hits.
    func testSingleLegalRoutePlaysDirectlyEvenWhenItHits() {
        let s = session(white: [5: 1, 24: 14], black: [7: 2, 8: 1, 1: 12], dice: (2, 3))
        XCTAssertEqual(s.moveBuilder.routeOptions(from: 5, to: 10).map { $0.map(\.to.position) }, [[8, 10]])
        s.commitHalfMove(from: 5, to: 10)
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(blackBar(s), 1)
        XCTAssertEqual(whiteAt(s, 10), 1)
    }

    /// Bar entry followed by a second step with the same checker: 0→2 (hit) →5 or 0→3 →5.
    func testBarEntryPlusSecondStep() {
        let s = session(white: [24: 14], black: [2: 1, 1: 14], whiteBar: 1, dice: (2, 3))
        XCTAssertEqual(s.selectableSources, [0])
        XCTAssertTrue(s.moveBuilder.validDestinations(for: 0).contains(5))
        s.selectPoint(0)
        s.commitHalfMove(from: 0, to: 5)
        XCTAssertEqual(s.routeChoice?.intermediatePoints, [2, 3])
        s.chooseRoute(via: 2)
        XCTAssertEqual(blackBar(s), 1)
        XCTAssertEqual(PortesVariant.barCount(.white, on: s.game.board), 0)
        XCTAssertEqual(whiteAt(s, 5), 1)
    }

    func testBarEntryPlusSecondStepWithoutBlotsPlaysDirectly() {
        let s = session(white: [24: 14], black: [1: 15], whiteBar: 1, dice: (2, 3))
        s.commitHalfMove(from: 0, to: 5)
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(whiteAt(s, 5), 1)
        XCTAssertEqual(s.currentPlayer, .black)
    }

    /// Only the larger die may be played (5→7→12 and 5→10→12 both blocked at 12):
    /// neither 12 nor the smaller-die stop 7 is offered.
    func testRoutesOutsideTheLegalMoveListAreNotOffered() {
        let s = session(white: [5: 1, 24: 14], black: [12: 2, 1: 13], dice: (2, 5))
        XCTAssertEqual(s.moveBuilder.validDestinations(for: 5), [10])
        XCTAssertTrue(s.moveBuilder.routeOptions(from: 5, to: 12).isEmpty)
        XCTAssertTrue(s.moveBuilder.routeOptions(from: 5, to: 7).isEmpty)
        let before = stacks(s)
        s.commitHalfMove(from: 5, to: 12)
        XCTAssertEqual(stacks(s), before)
        XCTAssertNil(s.routeChoice)
    }

    /// Bar first: with a checker on the bar, another checker's two-dice route is not offered.
    func testNoRouteForOtherCheckersWhileOnTheBar() {
        let s = session(white: [5: 1, 24: 13], black: [1: 15], whiteBar: 1, dice: (2, 3))
        XCTAssertTrue(s.moveBuilder.routeOptions(from: 5, to: 10).isEmpty)
    }

    // ── Cancel / undo ─────────────────────────────────────────────────────────

    /// Tapping anything but a candidate (or cancelling) aborts with nothing played; the
    /// same gesture can then be retried.
    func testCancelLeavesStateUntouched() {
        let s = session(white: [5: 1, 24: 14], black: [7: 1, 1: 14], dice: (2, 3))
        let before = stacks(s)
        let sources = s.selectableSources
        let active = s.moveBuilder.activeMoves.count

        s.commitHalfMove(from: 5, to: 10)
        XCTAssertNotNil(s.routeChoice)
        s.chooseRoute(via: 12)                          // not a candidate → cancel
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(stacks(s), before)
        XCTAssertEqual(s.selectableSources, sources)
        XCTAssertEqual(s.moveBuilder.activeMoves.count, active)
        XCTAssertTrue(s.moveBuilder.built.isEmpty)
        XCTAssertNil(s.selectedPoint)
        XCTAssertEqual(s.phase, .picking)
        XCTAssertEqual(s.currentPlayer, .white)

        s.commitHalfMove(from: 5, to: 10)
        s.cancelRouteChoice()
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(stacks(s), before)
        XCTAssertEqual(s.phase, .picking)

        s.commitHalfMove(from: 5, to: 10)
        s.selectPoint(24)                               // picking another point also aborts
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(stacks(s), before)
    }

    /// Stepping one die at a time still works: 5→7 (hit) then 7→10.
    func testManualSingleStepsStillWork() {
        let s = session(white: [5: 1, 24: 14], black: [7: 1, 1: 14], dice: (2, 3))
        s.selectPoint(5)
        s.commitHalfMove(from: 5, to: 7)
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(blackBar(s), 1)
        XCTAssertEqual(s.moveBuilder.built.count, 1)
        s.selectPoint(7)
        XCTAssertEqual(s.validTargets, [10])
        s.commitHalfMove(from: 7, to: 10)
        XCTAssertEqual(s.currentPlayer, .black)
    }

    // ── Doubles ───────────────────────────────────────────────────────────────

    /// One checker 2, 3 and 4 steps of a double in one gesture; a blot on the way is hit
    /// (fixed intermediate points → a single route, never a choice). Undo takes the whole
    /// gesture back at once.
    func testDoublesMultiStepGesturesAndUndo() {
        let s = session(white: [3: 1, 24: 14], black: [5: 1, 1: 14], dice: (2, 2))
        let start = stacks(s)
        XCTAssertEqual(s.moveBuilder.validDestinations(for: 3), [5, 7, 9, 11])
        for t in [5, 7, 9, 11] { XCTAssertEqual(s.moveBuilder.routeOptions(from: 3, to: t).count, 1) }

        s.commitHalfMove(from: 3, to: 7)                // two steps, hitting on 5
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(s.moveBuilder.built.count, 2)
        XCTAssertEqual(blackBar(s), 1)
        XCTAssertEqual(whiteAt(s, 7), 1)
        XCTAssertEqual(s.phase, .picking)

        s.undo()                                        // whole gesture
        XCTAssertTrue(s.moveBuilder.built.isEmpty)
        XCTAssertEqual(stacks(s), start)
        XCTAssertEqual(blackBar(s), 0)

        s.commitHalfMove(from: 3, to: 9)                // three steps
        XCTAssertEqual(s.moveBuilder.built.count, 3)
        s.undo()
        XCTAssertEqual(stacks(s), start)

        s.commitHalfMove(from: 3, to: 11)               // all four
        XCTAssertEqual(s.currentPlayer, .black)
        XCTAssertEqual(whiteAt(s, 11), 1)
        XCTAssertEqual(s.record.plies.last?.halfMoves.count, 4)
    }

    /// Every intermediate landing must be open: a made point on 7 stops the chain at 5.
    func testDoublesChainStopsAtABlockedPoint() {
        let s = session(white: [3: 1, 24: 14], black: [7: 2, 1: 13], dice: (2, 2))
        XCTAssertEqual(s.moveBuilder.validDestinations(for: 3), [5])
        XCTAssertTrue(s.moveBuilder.routeOptions(from: 3, to: 9).isEmpty)
    }

    /// Mixed gestures undo one gesture at a time: a single step, then a two-step chain.
    func testUndoIsPerGesture() {
        let s = session(white: [3: 1, 13: 1, 24: 13], black: [1: 15], dice: (2, 2))
        let start = stacks(s)
        s.commitHalfMove(from: 13, to: 15)              // gesture 1: one step
        let afterFirst = stacks(s)
        s.commitHalfMove(from: 3, to: 7)                // gesture 2: two steps
        XCTAssertEqual(s.moveBuilder.built.count, 3)
        XCTAssertEqual(s.moveBuilder.lastGesture.map(\.to.position), [5, 7])
        s.undo()
        XCTAssertEqual(stacks(s), afterFirst)
        XCTAssertEqual(s.moveBuilder.built.count, 1)
        s.undo()
        XCTAssertEqual(stacks(s), start)
        XCTAssertTrue(s.moveBuilder.built.isEmpty)
    }

    // ── MoveBuilder level ─────────────────────────────────────────────────────

    /// The builder's gesture bookkeeping on its own: a two-dice route committed as one
    /// gesture is taken back whole and restores the full move set.
    func testBuilderCommitGestureAndUndoGesture() {
        let v = GameVariants.portes
        let board = GameBoard(config: GameConfig(variant: v))
        PortesVariant.setPosition(on: board, white: [5: 1, 24: 14], black: [7: 1, 1: 14])
        let dice = Dice(); dice.set(2, 3)
        let legal = v.legalMoves(on: board, color: .white, dice: dice)
        let b = MoveBuilder(legalMoves: legal, board: board, die1: 2, die2: 3)
        let all = b.activeMoves.count
        let options = b.routeOptions(from: 5, to: 10)
        XCTAssertEqual(options.count, 2)
        let before = board.captureStacks()
        let hops = options[0].map { HalfMove(from: board.points[$0.from.position], to: board.points[$0.to.position], color: .white) }
        for h in hops { v.applyHalfMove(h, on: board) }
        XCTAssertTrue(b.commit(halfMoves: hops))
        XCTAssertEqual(b.lastGesture.count, 2)
        for h in b.lastGesture.reversed() { v.undoHalfMove(h, on: board) }
        b.undoGesture()
        XCTAssertTrue(b.built.isEmpty)
        XCTAssertEqual(b.activeMoves.count, all)
        XCTAssertEqual(board.captureStacks(), before)
        XCTAssertTrue(board.undoLog.isEmpty)
    }

    // ── Other variants unchanged ──────────────────────────────────────────────

    /// Plakoto: landing on a blot mid-route pins it and leaving releases it, so both
    /// unmerged routes end in the same position — played directly, as before.
    func testPlakotoUnmergedRoutesNeverAsk() {
        let s = GameSession(startingPlayer: .white, animationTimings: .off)
        let b = s.game.board
        b.setPoint(4, pieces: [.black])
        b.setPoint(24, pieces: Array(repeating: .black, count: 14))
        s.setManualDice(3, 5)
        XCTAssertEqual(s.moveBuilder.routeOptions(from: 1, to: 9).count, 1)
        s.commitHalfMove(from: 1, to: 9)
        XCTAssertNil(s.routeChoice)
        XCTAssertEqual(b.points[9].countForColor(.white), 1)
        XCTAssertEqual(b.points[4].pieces, [.black])
    }

    /// Random Portes games played only by far-target gestures (choosing a random route
    /// when asked): every finished turn equals some legal move's result.
    func testRandomGestureGamesStayLegal() {
        let v = GameVariants.portes
        var rng = SplitMix64(seed: 0x169)
        var asked = 0
        for _ in 0..<3 {
            let s = GameSession(startingPlayer: .white, config: GameConfig(variant: v), animationTimings: .off)
            var turns = 0
            while !s.isTerminal && turns < 3000 {
                turns += 1
                guard s.phase == .awaitingRoll else { XCTFail("phase \(s.phase)"); return }
                s.setManualDice(Int.random(in: 1...6, using: &rng), Int.random(in: 1...6, using: &rng))
                guard s.phase == .picking else { continue }      // forced pass
                let mover = s.currentPlayer
                var results = Set<[[Color]]>()
                for m in s.legalMoves { v.apply(m, on: s.game.board); results.insert(s.game.board.captureStacks()); v.undo(m, on: s.game.board) }
                let pliesBefore = s.record.plies.count
                while s.phase == .picking && s.currentPlayer == mover && s.record.plies.count == pliesBefore {
                    let src = s.selectableSources.sorted()[Int.random(in: 0..<s.selectableSources.count, using: &rng)]
                    s.selectPoint(src)
                    let dests = s.validTargets.sorted()
                    s.commitHalfMove(from: src, to: dests.max(by: { abs($0 - src) < abs($1 - src) })!)
                    if let choice = s.routeChoice {
                        asked += 1
                        let mids = choice.intermediatePoints.sorted()
                        s.chooseRoute(via: mids[Int.random(in: 0..<mids.count, using: &rng)])
                    }
                }
                // The turn finished: the position before the opponent's roll must be a legal result.
                if s.record.plies.count > pliesBefore {
                    XCTAssertTrue(results.contains(s.game.board.captureStacks()), "illegal composed result")
                }
            }
        }
        XCTAssertGreaterThan(asked, 0, "the random games should hit at least one ambiguous route")
    }
}
