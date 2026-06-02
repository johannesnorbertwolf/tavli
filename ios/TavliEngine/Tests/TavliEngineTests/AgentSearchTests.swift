import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Exercises the multi-ply expectimax search ported from `ai/agent.py` (#58):
/// the `pruneBranches` beam helper, the `evaluateMovesNply` recursion, and the
/// time-budget iterative-deepening `getBestMove`.
final class AgentSearchTests: XCTestCase {
    private static var agent: Agent!
    private static var fixtures: Fixtures!

    override class func setUp() {
        super.setUp()
        fixtures = try! FixtureLoader.load()
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
        agent = Agent(model: model, encoder: BoardEncoder(config: gameConfig(fixtures.config)))
    }

    // MARK: - pruneBranches (pure, no model)

    func testPruneBranchesRelativeCutoffSortsBestFirst() {
        // best = 0.90, relative cutoff 0.08 → keep score >= 0.828.
        let scores: [Float] = [0.50, 0.90, 0.86, 0.83, 0.10, 0.88]
        let kept = Agent.pruneBranches(scores: scores, beamThreshold: 0.08,
                                       relativeCutoff: 0.08, maxBranch: nil)
        XCTAssertEqual(kept, [1, 5, 2, 3])
    }

    func testPruneBranchesMaxBranchCaps() {
        let scores: [Float] = [0.50, 0.90, 0.86, 0.83, 0.10, 0.88]
        let kept = Agent.pruneBranches(scores: scores, beamThreshold: 0.08,
                                       relativeCutoff: 0.08, maxBranch: 2)
        XCTAssertEqual(kept, [1, 5])
    }

    func testPruneBranchesTightCutoffKeepsOnlyBest() {
        let scores: [Float] = [0.90, 0.10, 0.20]
        let kept = Agent.pruneBranches(scores: scores, beamThreshold: 0.0,
                                       relativeCutoff: 0.0, maxBranch: 5)
        XCTAssertEqual(kept, [0])
    }

    func testPruneBranchesTiesResolveByIndex() {
        let scores: [Float] = [0.50, 0.50, 0.50]
        let kept = Agent.pruneBranches(scores: scores, beamThreshold: 0.08,
                                       relativeCutoff: 0.08, maxBranch: nil)
        XCTAssertEqual(kept, [0, 1, 2])
    }

    // MARK: - nply recursion

    /// Independent depth-2 expectimax, built only from the parity-validated 1-ply
    /// primitive (`evaluateMoves`) and the dice distribution. Unpruned, so it must
    /// equal the production `evaluateMovesNply` run with pruning disabled.
    private func referenceTwoPly(_ board: GameBoard, _ moves: [Move], color: Color) throws -> [Float] {
        let encoder = BoardEncoder(config: gameConfig(Self.fixtures.config))
        let opp = color.opponent
        let dice = Dice()
        let saved = board.captureStacks()
        defer { board.restoreStacks(saved) }
        var out: [Float] = []
        for m in moves {
            board.apply(m)
            if board.hasWon(color) {
                out.append(1.0)
                board.undo(m)
                continue
            }
            var expected: Float = 0
            for o in diceOutcomes {
                dice.set(o.d1, o.d2)
                let oppMoves = PossibleMoves(board: board, color: opp, dice: dice).findMoves()
                if oppMoves.isEmpty {
                    expected += o.weight * (try Self.agent.value(encoder.encode(board, isWhitesTurn: color.isWhite)))
                } else {
                    let replyScores = try Self.agent.evaluateMoves(board, oppMoves, color: opp)
                    expected += o.weight * (1 - replyScores.max()!)
                }
            }
            out.append(expected)
            board.undo(m)
        }
        return out
    }

    func testNplyMatchesIndependentTwoPlyReference() throws {
        let config = gameConfig(Self.fixtures.config)
        let bigBeam: Float = 1e9   // keep == best - 1e9 → no replies pruned
        var checked = 0
        var maxDiff: Float = 0

        for c in Self.fixtures.move_cases where c.moves.count >= 2 {
            let board = makeBoard(c.points, config: config)
            let color = parseColor(c.color)
            let dice = Dice(numberOfSides: config.dieSides)
            dice.set(c.dice[0], c.dice[1])
            let moves = PossibleMoves(board: board, color: color, dice: dice).findMoves()
            guard moves.count >= 2 else { continue }

            let reference = try referenceTwoPly(board, moves, color: color)
            let production = try Self.agent.evaluateMovesNply(
                board, moves, color: color, depth: 2,
                beamThreshold: bigBeam, relativeCutoff: nil, maxBranch: nil, deadline: nil
            )
            XCTAssertEqual(production.count, reference.count)
            for i in production.indices {
                maxDiff = max(maxDiff, abs(production[i] - reference[i]))
            }
            checked += 1
            if checked >= 4 { break }
        }

        XCTAssertGreaterThan(checked, 0, "no multi-move fixture cases found")
        print("nply self-consistency: checked \(checked) cases, maxDiff=\(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 1e-4, "nply diverges from the independent 2-ply reference")
    }

    // MARK: - time-budget iterative deepening

    func testTimeBudgetSearchProducesLegalMoveAtDepthTwo() throws {
        let config = gameConfig(Self.fixtures.config)

        var picked: (board: GameBoard, moves: [Move], color: Color)?
        for c in Self.fixtures.move_cases where c.moves.count >= 3 {
            let board = makeBoard(c.points, config: config)
            let color = parseColor(c.color)
            let dice = Dice(numberOfSides: config.dieSides)
            dice.set(c.dice[0], c.dice[1])
            let moves = PossibleMoves(board: board, color: color, dice: dice).findMoves()
            if moves.count >= 3 { picked = (board, moves, color); break }
        }
        let (board, moves, color) = try XCTUnwrap(picked, "no fixture case with >= 3 moves")
        let checkersBefore = board.points.reduce(0) { $0 + $1.count }

        let start = Date()
        let result = try Self.agent.getBestMove(
            board, moves, color: color, timeBudget: 10,
            relativeCutoff: 0.08, maxBranch: 5, maxDepth: 2
        )
        let elapsed = Date().timeIntervalSince(start)

        let r = try XCTUnwrap(result)
        XCTAssertGreaterThanOrEqual(r.depth, 2, "multi-ply search never engaged")
        XCTAssertTrue((0..<moves.count).contains(r.index), "index out of range: \(r.index)")
        XCTAssertEqual(moves[r.index], r.move, "returned move/index disagree")
        XCTAssertTrue(r.score >= 0 && r.score <= 1, "score out of range: \(r.score)")
        XCTAssertLessThan(elapsed, 10, "search exceeded its time budget")
        let checkersAfter = board.points.reduce(0) { $0 + $1.count }
        XCTAssertEqual(checkersAfter, checkersBefore, "search left the board mutated")
    }

    /// A single legal move skips the search entirely (depth 1, index 0).
    func testTimeBudgetSearchSingleMoveFastPath() throws {
        let config = gameConfig(Self.fixtures.config)
        var single: (board: GameBoard, moves: [Move], color: Color)?
        for c in Self.fixtures.move_cases {
            let board = makeBoard(c.points, config: config)
            let color = parseColor(c.color)
            let dice = Dice(numberOfSides: config.dieSides)
            dice.set(c.dice[0], c.dice[1])
            let moves = PossibleMoves(board: board, color: color, dice: dice).findMoves()
            if moves.count == 1 { single = (board, moves, color); break }
        }
        let (board, moves, color) = try XCTUnwrap(single, "no single-move fixture case found")
        let result = try XCTUnwrap(try Self.agent.getBestMove(
            board, moves, color: color, timeBudget: 10, maxDepth: 2
        ))
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(result.depth, 1)
    }
}
