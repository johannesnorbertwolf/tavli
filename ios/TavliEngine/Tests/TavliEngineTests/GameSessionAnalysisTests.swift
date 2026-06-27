import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Exercises in-play analysis (#146): the 2-ply analysis the `GameSession` accumulates
/// *during* play — captured from the AI's own search on its turns, ranked in the
/// background during the human's thinking time on theirs — and the seeded refine path
/// the post-game review uses on top of it. Uses the fixture value model so scores match
/// real inference.
@MainActor
final class GameSessionAnalysisTests: XCTestCase {

    /// Compile the bundled test model the same way the other suites do, or skip when
    /// the generated fixture is absent.
    private func loadAgent() throws -> Agent {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else {
            throw XCTSkip("PlakotoValue.mlpackage not found — run ios/scripts/convert_to_coreml.py")
        }
        let compiled = try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly   // match Python CPU inference; avoid ANE float drift
        let model = try MLModel(contentsOf: compiled, configuration: cfg)
        return Agent(model: model, encoder: BoardEncoder(config: .standard))
    }

    // MARK: - Driving a session

    /// Commit the human (white) turn by replaying the first surviving legal move, exactly
    /// as `GameSessionAITests` does.
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

    /// Drive a human-vs-AI session (white = human) to game over or `maxPlies` recorded
    /// plies, awaiting the human's background ranking before each commit so every human
    /// ply is captured. The AI rolls/plays itself off the main actor (animations off);
    /// we **sleep-poll** while it thinks rather than busy-spinning `Task.yield()`, and a
    /// hard wall-clock deadline fails fast (and breaks) if a game ever stalls — a failing
    /// `XCTAssert` would not stop the loop.
    private func play(_ s: GameSession, maxPlies: Int, timeout: TimeInterval = 120) async {
        s.start()
        let deadline = Date().addingTimeInterval(timeout)
        while s.record.plies.count < maxPlies {
            if Date() > deadline {
                XCTFail("game stalled at \(s.record.plies.count) plies, phase \(s.phase)"); return
            }
            switch s.phase {
            case .gameOver:
                return
            case .awaitingRoll:
                // AI turns auto-run (they don't sit here); only the human rolls.
                if s.currentPlayer == s.aiColor { await Self.tick() }
                else { s.roll() }
            case .picking, .moving:
                await s.awaitInPlayAnalysisForTesting()
                playHumanTurn(s)
            case .aiThinking, .animating:
                await Self.tick()
            }
        }
    }

    /// Suspend ~2ms so the off-main AI search can complete without burning the CPU.
    private static func tick() async {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }

    /// The 1-based ply numbers `record` assigns to `color`'s own non-pass plies — the
    /// plies in-play analysis captures for that side.
    private func plyNumbers(of color: Color, in record: GameRecord) -> Set<Int> {
        var mover = record.startingPlayer
        var result: Set<Int> = []
        for (i, ply) in record.plies.enumerated() {
            if mover == color && !ply.halfMoves.isEmpty { result.insert(i + 1) }
            mover = mover.opponent
        }
        return result
    }

    // MARK: - Human capture matches a from-scratch review

    /// The key invariant: each human ply captured during play is identical to a
    /// from-scratch 2-ply review of the same game — same best move, same scores, depth 2.
    func testHumanCaptureMatchesFromScratchReview() async throws {
        let agent = try loadAgent()
        // maxDepth: 1 → fast 1-ply AI; the human ranking is depth-2 regardless, with the
        // same beam params `.standard` (and thus the review) uses.
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1),
                            animationTimings: .off, inPlayAnalysis: true)
        await play(s, maxPlies: 14)

        let human = s.aiColor!.opponent
        let review = GameReview.analyze(record: s.record, agent: agent, humanColor: human,
                                        depth: 2, searchConfig: SearchConfig(maxDepth: 1))
        XCTAssertFalse(review.evaluations.isEmpty, "expected human plies to review")

        let captured = Dictionary(s.inPlayAnalysis.map { ($0.plyNumber, $0) },
                                  uniquingKeysWith: { a, _ in a })
        let humanPlies = plyNumbers(of: human, in: s.record)

        // Every reviewed human ply was captured in play, and matches it exactly.
        XCTAssertEqual(captured.keys.filter { humanPlies.contains($0) }.count,
                       review.evaluations.count,
                       "every human ply should have an in-play entry")
        for eval in review.evaluations {
            guard let entry = captured[eval.plyNumber] else {
                XCTFail("missing in-play entry for human ply \(eval.plyNumber)"); continue
            }
            XCTAssertEqual(entry.depth, 2)
            XCTAssertEqual(entry.playedScore, Double(eval.playedScore), accuracy: 1e-4,
                           "played score mismatch at ply \(eval.plyNumber)")
            XCTAssertEqual(entry.bestScore, Double(eval.bestScore), accuracy: 1e-4,
                           "best score mismatch at ply \(eval.plyNumber)")
            XCTAssertEqual(entry.bestMove, eval.bestMove,
                           "best move mismatch at ply \(eval.plyNumber)")
        }
    }

    // MARK: - Opponent capture

    /// The AI's plies are captured from its own search: played == best (it plays its
    /// best), a real win-probability score, and the depth the search reached.
    func testOpponentCaptureIsSelfConsistent() async throws {
        let agent = try loadAgent()
        // A 2-ply search (bounded so AI turns stay quick), so non-forced AI plies are
        // captured at depth 2.
        let s = GameSession(startingPlayer: .black, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(timeBudget: 5, maxDepth: 2, rootSoftBudget: 5),
                            animationTimings: .off, inPlayAnalysis: true)
        await play(s, maxPlies: 14)

        let aiPlies = plyNumbers(of: s.aiColor!, in: s.record)
        let aiEntries = s.inPlayAnalysis.filter { aiPlies.contains($0.plyNumber) }
        XCTAssertFalse(aiEntries.isEmpty, "expected at least one AI ply captured")
        for e in aiEntries {
            XCTAssertEqual(e.playedMove, e.bestMove, "AI played its best, so played == best")
            XCTAssertEqual(e.playedScore, e.bestScore)
            XCTAssertGreaterThan(e.playedScore, 0)   // a real win prob, not the forced-move sentinel
            XCTAssertLessThanOrEqual(e.playedScore, 1)
            XCTAssertEqual(e.depth, 2, "a 2-ply search reaches depth 2 on a real choice")
        }
    }

    // MARK: - Cancellation

    /// `surrender()` cancels the in-flight human ranking and drops its staged scores.
    func testSurrenderCancelsInFlightHumanAnalysis() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1),
                            animationTimings: .off, inPlayAnalysis: true)
        s.start()
        s.roll()
        await s.awaitInPlayAnalysisForTesting()
        XCTAssertTrue(s.inPlayAnalysisReadyForTesting, "scores should be staged after awaiting")

        s.surrender()
        XCTAssertFalse(s.inPlayAnalysisReadyForTesting, "surrender drops the staged scores")
        XCTAssertFalse(s.inPlayAnalysisTaskActiveForTesting, "surrender cancels the task")
        XCTAssertTrue(s.isTerminal)
    }

    /// `newGame()` cancels analysis and clears everything accumulated so far.
    func testNewGameClearsAccumulatedAnalysis() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1),
                            animationTimings: .off, inPlayAnalysis: true)
        await play(s, maxPlies: 8)
        XCTAssertFalse(s.inPlayAnalysis.isEmpty, "expected some captured plies before reset")

        s.newGame(startingPlayer: .white)
        XCTAssertTrue(s.inPlayAnalysis.isEmpty, "newGame clears accumulated analysis")
        XCTAssertFalse(s.inPlayAnalysisTaskActiveForTesting)
    }

    // MARK: - Setting off

    /// With analysis disabled nothing is accumulated, on either side.
    func testDisabledCapturesNothing() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1),
                            animationTimings: .off, inPlayAnalysis: false)
        await play(s, maxPlies: 12)
        XCTAssertTrue(s.inPlayAnalysis.isEmpty)
        XCTAssertFalse(s.inPlayAnalysisTaskActiveForTesting)
    }

    // MARK: - Seeded refine (GameReview, #146)

    /// The core of the seed mechanic: a complete depth-≤2 seed (what in-play analysis
    /// writes) makes the 1-/2-ply passes **no-ops** — nothing is recomputed — and the
    /// result is byte-identical to the seed. (The deeper-pass 3-ply borderline behaviour
    /// itself is the pre-existing progressive logic, covered by `GameReviewTests`; here
    /// we only run depth ≤2 so the test stays fast.) Without the seed-skip the same
    /// 2-ply pass re-ranks every real-choice ply, so this also pins the saving.
    func testSeededAnalysisSkipsAlreadyScoredPlies() async throws {
        let agent = try loadAgent()
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1),
                            animationTimings: .off, inPlayAnalysis: true)
        await play(s, maxPlies: 12)
        let record = s.record
        let human = s.aiColor!.opponent
        guard !record.plies.isEmpty else { throw XCTSkip("no plies played") }

        // Authoritative depth-≤2 result; reuse it as a full seed.
        let baseline = GameReview.analyzeProgressive(
            record: record, agent: agent, humanColor: human, depths: [1, 2],
            includeOpponent: true)
        let seed = [AnalysisEntry](reviewResult: baseline)
        guard !seed.isEmpty else { throw XCTSkip("no analyzable plies in this game") }

        // Re-run the same passes seeded with the full result: nothing should recompute.
        let recomputed = LockedCounter()
        let seeded = GameReview.analyzeProgressive(
            record: record, agent: agent, humanColor: human, depths: [1, 2],
            includeOpponent: true, seed: seed,
            onEvaluation: { _ in recomputed.increment() })

        XCTAssertEqual(recomputed.value, 0, "a full ≤2 seed leaves nothing to recompute")
        XCTAssertEqual(seeded.evaluations.count, baseline.evaluations.count)
        let baseByPly = Dictionary(baseline.evaluations.map { ($0.plyNumber, $0) },
                                   uniquingKeysWith: { a, _ in a })
        for e in seeded.evaluations {
            guard let b = baseByPly[e.plyNumber] else { XCTFail("ply \(e.plyNumber) absent"); continue }
            XCTAssertEqual(e.depth, b.depth, "depth mismatch at ply \(e.plyNumber)")
            XCTAssertEqual(Double(e.playedScore), Double(b.playedScore), accuracy: 1e-4)
            XCTAssertEqual(Double(e.bestScore), Double(b.bestScore), accuracy: 1e-4)
            XCTAssertEqual(e.bestMove, b.bestMove)
        }
    }
}

/// A trivially thread-safe counter for the `@Sendable` analysis callback.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
