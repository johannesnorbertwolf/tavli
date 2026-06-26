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

    /// Deterministic generator so a played-out game (and any failure) is reproducible.
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// `[from, to]` half-move pairs of a move, in stored order.
    private func pairs(of move: Move) -> [[Int]] {
        move.halfMoves.map { [$0.from.position, $0.to.position] }
    }

    /// Deterministically play a full game (always the first legal move) from `seed`,
    /// recording every ply. Advances the board with the same in-place pop/push that
    /// `GameReview.analyze` replays with, so the analyzer reconstructs an identical
    /// board and every recorded move stays legal. Reports how many human (White)
    /// non-pass plies there were, the ply number of the last one, whether White ever
    /// faced a forced single legal move, and whether the game finished.
    private func playOutGame(seed: UInt64)
        -> (plies: [PlyRecord], humanNonPass: Int, lastHumanPly: Int,
            sawForcedHumanPly: Bool, finished: Bool) {
        let board = GameBoard(config: Self.config)
        board.initializeBoard()
        let dice = Dice(numberOfSides: Self.config.dieSides)
        var rng = LCG(seed)

        var plies: [PlyRecord] = []
        var mover: Color = .white
        var humanNonPass = 0
        var lastHumanPly = 0
        var sawForced = false
        var finished = false

        while plies.count < 600 {
            let d1 = Int.random(in: 1...Self.config.dieSides, using: &rng)
            let d2 = Int.random(in: 1...Self.config.dieSides, using: &rng)
            dice.set(d1, d2)
            let legal = PossibleMoves(board: board, color: mover, dice: dice).findMoves()
            let chosen = legal.first.map { pairs(of: $0) } ?? []
            plies.append(PlyRecord(die1: d1, die2: d2, halfMoves: chosen))

            if mover == .white && !chosen.isEmpty {
                humanNonPass += 1
                lastHumanPly = plies.count   // 1-based ply index
                if legal.count == 1 { sawForced = true }
            }

            for pair in chosen where pair.count == 2 {
                board.points[pair[0]].pop()
                board.points[pair[1]].push(mover)
            }
            if board.hasWon(mover) { finished = true; break }
            mover = mover.opponent
        }
        return (plies, humanNonPass, lastHumanPly, sawForced, finished)
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
            board, moves, color: color, depth: 2,
            beamThreshold: 0.08, relativeCutoff: 0.08, maxBranch: 4, deadline: nil
        )
        return (moves, scores)
    }

    // MARK: - Blunder flagging

    /// The worst-scoring legal move at the opening is scored exactly, but the opening
    /// is so near-even that its shortfall is under one percentage point — so the
    /// absolute floor in `isBlunder` correctly keeps it from registering as a blunder
    /// at any relative threshold (#105 rule). The analyzer wiring (exact played/best
    /// scores, a positive relative gap) is still verified.
    func testNearEvenWorstMoveIsNotABlunder() {
        let (moves, scores) = openingScores(color: .white, die1: 6, die2: 5)
        XCTAssertGreaterThan(moves.count, 1, "opening 6,5 should offer a real choice")

        let worstIdx = scores.indices.min { scores[$0] < scores[$1] }!
        let bestScore = scores.max()!
        XCTAssertLessThan(scores[worstIdx], bestScore, "model must rank some opening move below the best")

        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: pairs(of: moves[worstIdx]))]
        )
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 2)

        XCTAssertEqual(result.evaluations.count, 1)
        let e = result.evaluations[0]
        XCTAssertEqual(e.mover, .white)
        XCTAssertEqual(e.plyNumber, 1)
        XCTAssertEqual(e.playedScore, scores[worstIdx], accuracy: 1e-5)
        XCTAssertEqual(e.bestScore, bestScore, accuracy: 1e-5)
        XCTAssertGreaterThan(e.relativeGap, 0)

        // Near-even opening: the absolute shortfall is under a point, so it is not a
        // blunder — even at a zero relative threshold.
        XCTAssertLessThan(e.absoluteGap, 0.01)
        XCTAssertFalse(e.isBlunder(threshold: 0.10))
        XCTAssertFalse(e.isBlunder(threshold: 0.0))
        XCTAssertTrue(result.blunders(threshold: 0.10).isEmpty)
    }

    /// A large *relative* miss on a near-even position whose *absolute* shortfall is
    /// under one percentage point is not a blunder (the `isBlunder` absolute floor).
    func testTinyAbsoluteGapIsNotABlunder() {
        let e = PlyEvaluation(plyNumber: 1, die1: 1, die2: 2, boardStacks: [],
                              mover: .white, playedMove: [], playedScore: 0.040,
                              bestMove: [], bestScore: 0.048)
        XCTAssertGreaterThanOrEqual(e.relativeGap, 0.10)   // 0.008 / 0.048 ≈ 17%
        XCTAssertLessThan(e.absoluteGap, 0.01)             // 0.008 < 0.01
        XCTAssertFalse(e.isBlunder(threshold: 0.10))
    }

    /// Meeting both the relative threshold and the one-percentage-point absolute floor
    /// flags a blunder.
    func testGapPastBothThresholdsIsABlunder() {
        let e = PlyEvaluation(plyNumber: 1, die1: 1, die2: 2, boardStacks: [],
                              mover: .white, playedMove: [], playedScore: 0.80,
                              bestMove: [], bestScore: 0.95)
        XCTAssertGreaterThanOrEqual(e.relativeGap, 0.10)
        XCTAssertGreaterThanOrEqual(e.absoluteGap, 0.01)
        XCTAssertTrue(e.isBlunder(threshold: 0.10))
    }

    /// Playing the AI's own best move yields a zero gap and is never flagged.
    func testBestMoveIsNotABlunder() {
        let (moves, scores) = openingScores(color: .white, die1: 6, die2: 5)
        let bestIdx = scores.indices.max { scores[$0] < scores[$1] }!

        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: pairs(of: moves[bestIdx]))]
        )
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 2)

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
        let asBlack = GameReview.analyze(record: record, agent: Self.agent, humanColor: .black, depth: 2)
        XCTAssertTrue(asBlack.evaluations.isEmpty)

        let asWhite = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 2)
        XCTAssertEqual(asWhite.evaluations.count, 1)
        XCTAssertTrue(asWhite.evaluations.allSatisfy { $0.mover == .white })
    }

    /// A forced pass (empty half-moves) is never evaluated.
    func testForcedPassIsSkipped() {
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 3, die2: 4, halfMoves: [])]  // human pass
        )
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 2)
        XCTAssertTrue(result.evaluations.isEmpty)
    }

    /// Regression for #131: the review must not stop short of the end. Every human
    /// non-pass ply of a finished game — including the forced single-legal-move plies
    /// that dominate the bear-off endgame — is represented, and the final human ply
    /// is among them. Plays a full game out (deterministic, first-legal-move) so the
    /// endgame's forced plies actually occur, then checks coverage against the count
    /// of human non-pass plies. Forced plies are flagged `hadChoice == false`.
    func testForcedEndgamePliesAreNotDropped() {
        // Play games from successive seeds until one contains a forced (single legal
        // move) White ply, so the fix is genuinely exercised — forced plies are
        // common in the bear-off endgame but not guaranteed for any single seed.
        var game: (plies: [PlyRecord], humanNonPass: Int, lastHumanPly: Int, finished: Bool)?
        for seed in UInt64(0)..<80 {
            let g = playOutGame(seed: seed)
            if g.finished && g.sawForcedHumanPly {
                game = (g.plies, g.humanNonPass, g.lastHumanPly, g.finished)
                break
            }
        }
        guard let game else {
            return XCTFail("no seed in 0..<80 produced a finished game with a forced White ply")
        }

        let record = GameRecord(startingPlayer: .white, aiColor: .black, plies: game.plies)
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 2)

        // Every human non-pass ply is represented — none dropped for being forced.
        XCTAssertEqual(result.evaluations.count, game.humanNonPass,
                       "forced single-move plies must not be dropped from the review")
        // The review reaches the final human move.
        XCTAssertEqual(result.evaluations.last?.plyNumber, game.lastHumanPly,
                       "review must include the last human ply, not stop short")
        // Forced plies are flagged and carry a zero gap (never a blunder).
        for e in result.evaluations where !e.hadChoice {
            XCTAssertEqual(e.absoluteGap, 0, accuracy: 1e-6)
            XCTAssertFalse(e.isBlunder(threshold: 0.0))
        }
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
        let result = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 2)

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
        _ = GameReview.analyze(record: record, agent: Self.agent, humanColor: .white, depth: 2) { done, total in
            box.last = (done, total)
        }
        XCTAssertEqual(box.last?.0, 1)
        XCTAssertEqual(box.last?.1, 1)
    }
}
