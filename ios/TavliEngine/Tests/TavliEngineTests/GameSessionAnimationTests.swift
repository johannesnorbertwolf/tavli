import Foundation
import XCTest
import Combine
@testable import TavliEngine

/// Exercises the AI-turn animation driver (#93): the dice-roll phase, the
/// strictly sequential half-move hops with point-by-point board updates, the
/// zero-duration synchronous escape hatch, and cancellation via `newGame`.
/// All tests use `agent: nil` (the random legal fallback) so they run without
/// the Core ML fixture; the animated path is identical with a real model —
/// only how the move is *chosen* differs.
@MainActor
final class GameSessionAnimationTests: XCTestCase {

    /// Tiny but non-zero durations: the animated code path runs for real
    /// (sleeps, sequential publishes) without slowing the suite.
    private let fast = AnimationTimings(aiDiceRollDuration: 0.02,
                                        aiMoveAnimationDuration: 0.02)

    /// Yield until the session leaves the AI presentation phases (bounded).
    private func waitForTurnEnd(_ s: GameSession, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while s.phase == .aiThinking || s.phase == .animating, Date() < deadline {
            await Task.yield()
        }
    }

    private func totalCheckers(_ s: GameSession) -> Int {
        s.game.board.points.reduce(0) { $0 + $1.count }
    }

    /// Play the human turn by replaying the first surviving legal move.
    private func playHumanTurn(_ s: GameSession) {
        guard let chosen = s.moveBuilder.activeMoves.first else { return }
        while s.phase == .picking || s.phase == .moving {
            let idx = s.moveBuilder.built.count
            guard idx < chosen.halfMoves.count else { break }
            let h = chosen.halfMoves[idx]
            s.selectPoint(h.from.position)
            s.commitHalfMove(from: h.from.position, to: h.to.position)
        }
    }

    /// The animated AI turn tumbles the dice, then publishes each half-move as
    /// an in-flight hop one at a time; the board mutates only as hops land, so
    /// every intermediate position is observable. The published hops match the
    /// recorded ply exactly, in order.
    func testAnimatedAITurnPublishesSequentialHops() async throws {
        let s = GameSession(startingPlayer: .black, agent: nil, aiColor: .black,
                            animationTimings: fast)
        var hops: [AIAnimatedHop] = []
        var landedAtPublish: [Int] = []
        var cancellables: Set<AnyCancellable> = []
        s.$aiHopInFlight
            .compactMap { $0 }
            .sink { [weak s] hop in
                hops.append(hop)
                // At publish time exactly `id` earlier hops have landed.
                landedAtPublish.append(s?.moveBuilder.built.count ?? -1)
            }
            .store(in: &cancellables)

        s.start()
        // Random fallback skips `aiThinking`: the presentation starts at once.
        XCTAssertEqual(s.phase, .animating)
        XCTAssertTrue(s.aiDiceRolling, "dice must tumble before any checker moves")
        XCTAssertNil(s.aiHopInFlight, "no hop may fly while the dice still tumble")

        await waitForTurnEnd(s)

        XCTAssertEqual(s.phase, .awaitingRoll, "turn handed to the human")
        XCTAssertEqual(s.currentPlayer, .white)
        XCTAssertFalse(s.aiDiceRolling)
        XCTAssertNil(s.aiHopInFlight)
        XCTAssertFalse(s.canUndo, "no stale built half-moves after the AI turn")

        let ply = try XCTUnwrap(s.history.last)
        XCTAssertFalse(ply.halfMoves.isEmpty, "the opening roll always has a legal move")
        XCTAssertEqual(hops.map { [$0.from, $0.to] }, ply.halfMoves,
                       "published hops must replay the recorded move exactly")
        XCTAssertEqual(hops.map(\.id), Array(0..<hops.count), "hop ids are ordinal")
        XCTAssertEqual(landedAtPublish, Array(0..<hops.count),
                       "hop i is published with exactly i hops landed")
        XCTAssertEqual(totalCheckers(s), 2 * s.game.board.numberOfPieces)
    }

    /// Zero durations disable the animation entirely: the AI turn completes
    /// synchronously inside `start()` and no animation state is ever published.
    func testZeroDurationsSkipAnimationEntirely() {
        let s = GameSession(startingPlayer: .black, agent: nil, aiColor: .black,
                            animationTimings: .off)
        var publishes = 0
        var cancellables: Set<AnyCancellable> = []
        s.$aiHopInFlight.compactMap { $0 }.sink { _ in publishes += 1 }
            .store(in: &cancellables)
        s.$aiDiceRolling.filter { $0 }.sink { _ in publishes += 1 }
            .store(in: &cancellables)

        s.start()

        XCTAssertEqual(s.phase, .awaitingRoll, "AI turn finished synchronously")
        XCTAssertEqual(s.currentPlayer, .white)
        XCTAssertEqual(s.history.count, 1)
        XCTAssertEqual(publishes, 0, "no animation state with .off timings")
    }

    /// `newGame` mid-animation cancels the in-flight turn: the fresh game keeps
    /// the start position and no ply from the cancelled turn is ever recorded.
    func testNewGameCancelsAIAnimation() async {
        let s = GameSession(startingPlayer: .black, agent: nil, aiColor: .black,
                            animationTimings: AnimationTimings(aiDiceRollDuration: 0.05,
                                                               aiMoveAnimationDuration: 0.05))
        s.start()
        XCTAssertEqual(s.phase, .animating)

        s.newGame(startingPlayer: .white)   // human side opens the fresh game
        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertFalse(s.aiDiceRolling)
        XCTAssertNil(s.aiHopInFlight)

        // Long enough for every cancelled continuation to have fired had it survived.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(s.phase, .awaitingRoll)
        XCTAssertEqual(s.history.count, 0, "cancelled AI turn must not record a ply")
        let fresh = GameBoard()
        fresh.initializeBoard()
        for i in s.game.board.points.indices {
            XCTAssertEqual(s.game.board.points[i].pieces, fresh.points[i].pieces,
                           "point \(i) must hold the start position")
        }
    }

    /// A full animated game (near-zero durations) terminates, conserves
    /// checkers, and exercises the animated forced-pass path along the way.
    func testAnimatedFullGameTerminatesAndConservesCheckers() async {
        let s = GameSession(startingPlayer: .white, agent: nil, aiColor: .black,
                            animationTimings: AnimationTimings(aiDiceRollDuration: 0.001,
                                                               aiMoveAnimationDuration: 0.001))
        s.start()

        var turns = 0
        loop: while true {
            switch s.phase {
            case .gameOver:
                break loop
            case .awaitingRoll:
                turns += 1
                XCTAssertLessThan(turns, 100_000, "game failed to terminate")
                XCTAssertEqual(totalCheckers(s), 2 * s.game.board.numberOfPieces,
                               "checkers must be conserved across animated turns")
                s.setManualDice(Int.random(in: 1...6), Int.random(in: 1...6))
            case .picking, .moving:
                playHumanTurn(s)
            case .aiThinking, .animating:
                await Task.yield()
            }
        }

        XCTAssertTrue(s.game.isOver())
        XCTAssertEqual(totalCheckers(s), 2 * s.game.board.numberOfPieces)
    }
}
