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

    // MARK: - Progressive analysis (#103)

    /// The 1-ply **base pass** covers every human non-pass ply, through the last one,
    /// at depth 1 (like `analyze`'s coverage but cheap — no 2-/3-ply model inference).
    /// Restricting `depths` to `[1]` keeps this in the seconds, not minutes, range.
    func testProgressiveBasePassCoversEveryPly() {
        var game: (plies: [PlyRecord], humanNonPass: Int, lastHumanPly: Int)?
        for seed in UInt64(0)..<80 {
            let g = playOutGame(seed: seed)
            if g.finished && g.sawForcedHumanPly {
                game = (g.plies, g.humanNonPass, g.lastHumanPly); break
            }
        }
        guard let game else { return XCTFail("no finished game with a forced ply in 0..<80") }
        let record = GameRecord(startingPlayer: .white, aiColor: .black, plies: game.plies)

        final class Box: @unchecked Sendable { var passes: [Int] = []; var plies = Set<Int>() }
        let box = Box()
        let result = GameReview.analyzeProgressive(
            record: record, agent: Self.agent, humanColor: .white, depths: [1],
            onEvaluation: { e in box.plies.insert(e.plyNumber) },
            onPassComplete: { pass, _ in box.passes.append(pass) })

        XCTAssertEqual(result.evaluations.count, game.humanNonPass)
        XCTAssertEqual(result.evaluations.last?.plyNumber, game.lastHumanPly)
        XCTAssertEqual(box.plies.count, game.humanNonPass)
        XCTAssertEqual(box.passes, [0])
        XCTAssertTrue(result.evaluations.allSatisfy { $0.depth == 1 })
    }

    /// A ply re-emits deeper across passes: the same `plyNumber` arrives at depth 1
    /// then depth 2, `onPassComplete` fires per pass, and the final result carries the
    /// deeper score. One opening ply at `[1, 2]` so it stays cheap.
    func testProgressiveReEmitsPlyDeeper() {
        let (moves, _) = openingScores(color: .white, die1: 6, die2: 5)
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: pairs(of: moves[0]))]
        )
        final class Box: @unchecked Sendable { var depths: [Int] = []; var passes: [Int] = [] }
        let box = Box()
        let result = GameReview.analyzeProgressive(
            record: record, agent: Self.agent, humanColor: .white, depths: [1, 2],
            onEvaluation: { e in box.depths.append(e.depth) },
            onPassComplete: { pass, _ in box.passes.append(pass) })

        XCTAssertEqual(result.evaluations.count, 1)
        XCTAssertEqual(box.passes, [0, 1])
        XCTAssertEqual(box.depths, [1, 2], "the ply is emitted at depth 1, then re-emitted at depth 2")
        XCTAssertEqual(result.evaluations[0].depth, 2)
    }

    /// The deepening cutoffs (`shouldRefine`) — pure logic, no model. Pass 1 (→2-ply)
    /// re-scores everything but the already-clear blunders; pass 2 (→3-ply) only the
    /// borderline calls; forced plies never deepen.
    func testProgressiveRefinementCutoffs() {
        func ev(played: Float, best: Float, hadChoice: Bool = true) -> PlyEvaluation {
            PlyEvaluation(plyNumber: 1, die1: 1, die2: 2, boardStacks: [], mover: .white,
                          playedMove: [], playedScore: played, bestMove: [], bestScore: best,
                          hadChoice: hadChoice, depth: 1)
        }
        // Forced ply: never deepened on any pass.
        let forced = ev(played: 0.5, best: 0.5, hadChoice: false)
        XCTAssertFalse(GameReview.shouldRefine(forced, pass: 1))
        XCTAssertFalse(GameReview.shouldRefine(forced, pass: 2))

        // Clear blunder (rel 30%, abs 15%): skipped at 2-ply and 3-ply.
        let clearBlunder = ev(played: 0.35, best: 0.50)
        XCTAssertFalse(GameReview.shouldRefine(clearBlunder, pass: 1))
        XCTAssertFalse(GameReview.shouldRefine(clearBlunder, pass: 2))

        // Borderline (rel 10%, abs 5%): refined at both 2-ply and 3-ply.
        let borderline = ev(played: 0.45, best: 0.50)
        XCTAssertTrue(GameReview.shouldRefine(borderline, pass: 1))
        XCTAssertTrue(GameReview.shouldRefine(borderline, pass: 2))

        // Best played (zero gap): refined at 2-ply (could shift), not 3-ply.
        let best = ev(played: 0.50, best: 0.50)
        XCTAssertTrue(GameReview.shouldRefine(best, pass: 1))
        XCTAssertFalse(GameReview.shouldRefine(best, pass: 2))

        // Tiny miss below the close band (rel 3%): refined at 2-ply, not 3-ply.
        let tiny = ev(played: 0.485, best: 0.50)
        XCTAssertTrue(GameReview.shouldRefine(tiny, pass: 1))
        XCTAssertFalse(GameReview.shouldRefine(tiny, pass: 2))
    }

    /// With `includeOpponent`, the AI's plies are evaluated too (#132) — included in
    /// play order, but kept at the 1-ply base depth while the human's plies deepen.
    /// Without it, only the human's plies appear.
    func testProgressiveOpponentMovesIncludedButNotDeepened() {
        // Build a two-ply record: White's opening, then Black's reply, each a real
        // choice. Black's legal moves come from the board after White's move.
        let board = GameBoard(config: Self.config)
        board.initializeBoard()
        let dice = Dice(numberOfSides: Self.config.dieSides)
        dice.set(6, 5)
        let whiteMove = PossibleMoves(board: board, color: .white, dice: dice).findMoves()[0]
        let wPairs = pairs(of: whiteMove)
        for p in wPairs { board.points[p[0]].pop(); board.points[p[1]].push(.white) }
        dice.set(4, 3)
        let blackMove = PossibleMoves(board: board, color: .black, dice: dice).findMoves()[0]
        let record = GameRecord(
            startingPlayer: .white, aiColor: .black,
            plies: [PlyRecord(die1: 6, die2: 5, halfMoves: wPairs),
                    PlyRecord(die1: 4, die2: 3, halfMoves: pairs(of: blackMove))]
        )

        let withOpp = GameReview.analyzeProgressive(
            record: record, agent: Self.agent, humanColor: .white,
            depths: [1, 2], includeOpponent: true)
        XCTAssertEqual(withOpp.evaluations.count, 2)
        let white = withOpp.evaluations.first { $0.mover == .white }
        let black = withOpp.evaluations.first { $0.mover == .black }
        XCTAssertNotNil(black, "the opponent's ply should be included")
        XCTAssertEqual(white?.depth, 2, "the human's ply deepens to 2-ply")
        XCTAssertEqual(black?.depth, 1, "the opponent's ply stays at the 1-ply base")

        let humanOnly = GameReview.analyzeProgressive(
            record: record, agent: Self.agent, humanColor: .white,
            depths: [1, 2], includeOpponent: false)
        XCTAssertEqual(humanOnly.evaluations.count, 1)
        XCTAssertTrue(humanOnly.evaluations.allSatisfy { $0.mover == .white })
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
