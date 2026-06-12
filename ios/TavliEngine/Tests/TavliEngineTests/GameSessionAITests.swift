import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Exercises the T6 AI integration: a human-vs-AI session where the AI side
/// auto-rolls and auto-plays, with a graceful random fallback when no model is
/// present. Both tests drive the human (white) side by replaying the first
/// surviving legal move through the session intents.
@MainActor
final class GameSessionAITests: XCTestCase {

    /// Compile the bundled test model the same way `AgentParityTests` does, or
    /// skip when the generated fixture is absent.
    private func loadAgent() throws -> Agent {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else {
            throw XCTSkip("PlakotoValue.mlpackage not found — run ios/scripts/convert_to_coreml.py")
        }
        let compiled = try MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiled, configuration: cfg)
        return Agent(model: model, encoder: BoardEncoder(config: .standard))
    }

    /// Yield until the AI's off-main inference has applied its move.
    private func waitForAI(_ s: GameSession) async {
        while s.phase == .aiThinking { await Task.yield() }
    }

    /// Play the human (white) turn by replaying the first surviving legal move.
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

    /// Real model: the AI must reach a win playing actual moves and update
    /// `winProbability` off its 0.5 default (a value only the model can set).
    func testHumanVsAIPlaysRealMovesAndUpdatesWinProb() async throws {
        let agent = try loadAgent()
        // maxDepth: 1 keeps the AI at 1-ply so full-game tests stay fast; the
        // multi-ply search itself is covered by AgentSearchTests.
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1),
                            animationTimings: .off)
        s.start()
        await waitForAI(s)

        var turns = 0
        loop: while true {
            switch s.phase {
            case .gameOver:
                break loop
            case .awaitingRoll:
                turns += 1
                XCTAssertLessThan(turns, 100_000, "game failed to terminate")
                // Analysis (AI + overlay scoring) apply/undoes on the live board;
                // a leaked move would change the total checker count. Guard it.
                let total = s.game.board.points.reduce(0) { $0 + $1.count }
                XCTAssertEqual(total, 2 * s.game.board.numberOfPieces,
                               "checkers must be conserved across turns")
                s.setManualDice(Int.random(in: 1...6), Int.random(in: 1...6))
            case .picking, .moving:
                playHumanTurn(s)
                await waitForAI(s)
            case .aiThinking, .animating:
                await waitForAI(s)
            }
        }

        guard case .gameOver = s.phase else { return XCTFail("game did not finish") }
        XCTAssertTrue(s.game.isOver())
        XCTAssertNotEqual(s.winProbability, 0.5, accuracy: 1e-9,
                          "winProbability never updated — AI likely fell back to random")
    }

    /// Reproduces the debug overlay's path: `DebugOverlay.recomputeCandidates`
    /// scores the live shared board with `evaluateMoves` on every clean human turn.
    /// A thrown Core ML error mid-scoring (swallowed by the overlay's `try?`) must
    /// not leave a move applied — `evaluateMoves`'s `defer` guarantees the undo.
    /// Plays a full game, scoring the way the overlay does, and asserts checkers are
    /// conserved throughout; a leaked analysis apply would drift the counts.
    func testOverlayScoringPreservesCheckers() async throws {
        let agent = try loadAgent()
        // maxDepth: 1 keeps the AI at 1-ply so full-game tests stay fast; the
        // multi-ply search itself is covered by AgentSearchTests.
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1),
                            animationTimings: .off)
        s.start()
        await waitForAI(s)

        func assertConserved() {
            let total = s.game.board.points.reduce(0) { $0 + $1.count }
            XCTAssertEqual(total, 2 * s.game.board.numberOfPieces,
                           "checkers must be conserved across overlay scoring")
        }

        var turns = 0
        loop: while true {
            switch s.phase {
            case .gameOver:
                break loop
            case .awaitingRoll:
                turns += 1
                XCTAssertLessThan(turns, 100_000, "game failed to terminate")
                assertConserved()
                s.setManualDice(Int.random(in: 1...6), Int.random(in: 1...6))
            case .picking, .moving:
                // Mimic the overlay: score the live board at a clean turn start.
                if s.moveBuilder.built.isEmpty, !s.legalMoves.isEmpty {
                    _ = try? agent.evaluateMoves(s.game.board, s.legalMoves, color: s.currentPlayer)
                    assertConserved()
                }
                playHumanTurn(s)
                await waitForAI(s)
            case .aiThinking, .animating:
                await waitForAI(s)
            }
        }

        guard case .gameOver = s.phase else { return XCTFail("game did not finish") }
        assertConserved()
    }

    /// Real model: the win probability goes live on the human's turn — it sits at
    /// the 0.5 default before the first roll, then moves off it once the human rolls
    /// (the model scores the live board, before any AI move).
    func testWinProbUpdatesOnHumanTurn() throws {
        let agent = try loadAgent()
        // maxDepth: 1 keeps the AI at 1-ply so full-game tests stay fast; the
        // multi-ply search itself is covered by AgentSearchTests.
        let s = GameSession(startingPlayer: .white, agent: agent, aiColor: .black,
                            searchConfig: SearchConfig(maxDepth: 1),
                            animationTimings: .off)
        s.start()                                             // human (white) to move
        XCTAssertEqual(s.winProbability, 0.5, accuracy: 1e-9) // not yet evaluated
        s.setManualDice(3, 5)                                 // beginTurn → refreshEvaluation
        XCTAssertNotEqual(s.winProbability, 0.5, accuracy: 1e-9,
                          "win prob should update on the human's turn after rolling")
    }

    /// Missing model: AI turns fall back to random legal moves, the game still
    /// terminates, and `winProbability` stays at its 0.5 default (never scored).
    func testMissingModelFallsBackToRandom() throws {
        let s = GameSession(startingPlayer: .white, agent: nil, aiColor: .black,
                            animationTimings: .off)
        s.start()

        var turns = 0
        loop: while true {
            switch s.phase {
            case .gameOver:
                break loop
            case .awaitingRoll:
                turns += 1
                XCTAssertLessThan(turns, 100_000, "game failed to terminate")
                s.setManualDice(Int.random(in: 1...6), Int.random(in: 1...6))
            case .picking, .moving:
                playHumanTurn(s)
            case .aiThinking, .animating:
                XCTFail("random fallback should be synchronous, never aiThinking")
                break loop
            }
        }

        guard case .gameOver = s.phase else { return XCTFail("game did not finish") }
        XCTAssertTrue(s.game.isOver())
        XCTAssertEqual(s.winProbability, 0.5, accuracy: 1e-9)
    }
}
