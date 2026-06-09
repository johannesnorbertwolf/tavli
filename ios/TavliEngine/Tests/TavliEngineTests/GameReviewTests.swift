import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Exercises the post-game blunder analyzer (`GameReview`, #62), the on-device
/// analogue of the CLI's `review` command (`play/loop.py:_collect_blunders`).
/// Uses the fixture value model so the scores match real inference.
final class GameReviewTests: XCTestCase {
    private static var agent: Agent!
    private static var config: GameConfig!

    override class func setUp() {
        super.setUp()
        let fixtures = try! FixtureLoader.load()
        config = gameConfig(fixtures.config)
        let bundle = Bundle.module
        let url = bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "PlakotoValue", withExtension: "mlpackage")
        guard let url else {
            fatalError("PlakotoValue.mlpackage not found — run ios/scripts/convert_to_coreml.py")
        }
        let compiled = try! MLModel.compileModel(at: url)
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly   // match Python CPU inference; avoid ANE float drift
        let model = try! MLModel(contentsOf: compiled, configuration: cfg)
        agent = Agent(model: model, encoder: BoardEncoder(config: config))
    }

    // MARK: - Helpers

    /// `[from, to]` half-move pairs of a move, in stored order.
    private func pairs(of move: Move) -> [[Int]] {
        move.halfMoves.map { [$0.from.position, $0.to.position] }
    }

    /// The opening position's legal moves for `color` under a fixed roll, plus
    /// their 3-ply scores — the same scoring `GameReview.analyze` performs.
    private func openingScores(color: Color, die1: Int, die2: Int) -> (moves: [Move], scores: [Float]) {
        let board = GameBoard(config: Self.config)
        board.initializeBoard()
        let dice = Dice(numberOfSides: Self.config.dieSides)
        dice.set(die1, die2)
        let moves = PossibleMoves(board: board, color: color, dice: dice).findMoves()
        let scores = try! Self.agent.evaluateMovesNply(
            board, moves, color: color, depth: 3,
            beamThreshold: 0.08, relativeCutoff: 0.08, maxBranch: 4, deadline: nil
        )
        return (moves, scores)
    }

    // MARK: - Blunder flagging

    /// A deliberately weak human move (the worst-scoring legal move at the opening)
    /// is evaluated with the exact played/best scores and flagged as a blunder once
    /// the threshold drops below its real relative gap.
    func testWeakHumanMoveIsFlaggedAsBlunder() {
        let (moves, scores) = openingScores(color: .white, die1: 6, die2: 5)
        XCTAssertGreaterThan(moves.count, 1, "opening 6,5 should offer a real choice")

        let worstIdx = scores.indices.min { scores[$0] < scores[$1] }!
        let bestScore = scores.max()!
        XCTAssertLessThan(scores[worstIdx], bestScore, "model must rank some opening move below the best")

        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: pairs(of: moves[worstIdx]))]
        )
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 3)

        XCTAssertEqual(result.evaluations.count, 1)
        let e = result.evaluations[0]
        XCTAssertEqual(e.mover, .white)
        XCTAssertEqual(e.plyNumber, 1)
        XCTAssertEqual(e.playedScore, scores[worstIdx], accuracy: 1e-5)
        XCTAssertEqual(e.bestScore, bestScore, accuracy: 1e-5)
        XCTAssertGreaterThan(e.relativeGap, 0)

        // Flagged just below its own gap, not flagged just above it.
        XCTAssertTrue(e.isBlunder(threshold: e.relativeGap - 1e-6))
        XCTAssertFalse(e.isBlunder(threshold: e.relativeGap + 1e-3))
        XCTAssertEqual(result.blunders(threshold: e.relativeGap - 1e-6).count, 1)
    }

    /// Playing the AI's own best move yields a zero gap and is never flagged.
    func testBestMoveIsNotABlunder() {
        let (moves, scores) = openingScores(color: .white, die1: 6, die2: 5)
        let bestIdx = scores.indices.max { scores[$0] < scores[$1] }!

        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: pairs(of: moves[bestIdx]))]
        )
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 3)

        XCTAssertEqual(result.evaluations.count, 1)
        let e = result.evaluations[0]
        XCTAssertEqual(e.relativeGap, 0, accuracy: 1e-6)
        XCTAssertFalse(e.isBlunder(threshold: 0.10))
        XCTAssertTrue(result.blunders(threshold: 0.10).isEmpty)
    }

    // MARK: - What gets evaluated

    /// Only the human's own plies are evaluated; the same record reviewed from the
    /// opponent's seat yields no evaluations for that side's absent plies.
    func testOnlyHumanPliesEvaluated() {
        let (moves, _) = openingScores(color: .white, die1: 6, die2: 5)
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: pairs(of: moves[0]))]
        )

        // The only ply is White's, so reviewing Black's moves finds nothing.
        let asBlack = GameReview.analyze(record: record, agent: Self.agent, humanColor: .black, depth: 3)
        XCTAssertTrue(asBlack.evaluations.isEmpty)

        let asWhite = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 3)
        XCTAssertEqual(asWhite.evaluations.count, 1)
        XCTAssertTrue(asWhite.evaluations.allSatisfy { $0.mover == .white })
    }

    /// A forced pass (empty half-moves) is never evaluated.
    func testForcedPassIsSkipped() {
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 3, die2: 4, halfMoves: [])]  // human pass
        )
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 3)
        XCTAssertTrue(result.evaluations.isEmpty)
    }

    // MARK: - Board reconstruction

    /// The captured `boardStacks` is the position *before* the move — for the first
    /// ply, the freshly initialized board.
    func testBoardSnapshotIsPreMovePosition() {
        let (moves, _) = openingScores(color: .white, die1: 6, die2: 5)
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: pairs(of: moves[0]))]
        )
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 3)

        let fresh = GameBoard(config: Self.config)
        fresh.initializeBoard()
        XCTAssertEqual(result.evaluations.first?.boardStacks, fresh.captureStacks())
    }

    // MARK: - Progress

    /// The progress callback ends at `done == total`, one tick per human ply.
    func testProgressReportsCompletion() {
        let (moves, _) = openingScores(color: .white, die1: 6, die2: 5)
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: pairs(of: moves[0]))]
        )

        // `analyze` invokes `progress` synchronously; a reference box collects the
        // last tick without a non-Sendable capture of a local `var`.
        final class Box: @unchecked Sendable { var last: (Int, Int)? }
        let box = Box()
        _ = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 3) { done, total in
            box.last = (done, total)
        }
        XCTAssertEqual(box.last?.0, 1)
        XCTAssertEqual(box.last?.1, 1)
    }
}
