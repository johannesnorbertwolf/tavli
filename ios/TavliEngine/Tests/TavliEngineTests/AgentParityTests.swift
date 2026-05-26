import Foundation
import XCTest
import CoreML
@testable import TavliEngine

func normalizeMove(_ move: [[Int]]) -> String {
    move.map { "\($0[0])->\($0[1])" }.sorted().joined(separator: ",")
}

final class AgentParityTests: XCTestCase {
    private static var fixtures: Fixtures!
    private static var agent: Agent!

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
        let encoder = BoardEncoder(config: gameConfig(fixtures.config))
        agent = Agent(model: model, encoder: encoder)
    }

    func testScoreAndBestMoveParity() throws {
        guard Self.fixtures.has_scores else {
            throw XCTSkip("fixtures generated without scores")
        }
        let config = gameConfig(Self.fixtures.config)
        let scoreTol: Float = 1e-3
        let tieEps: Float = 1e-4
        var maxScoreDiff: Float = 0
        var checkedCases = 0
        var checkedMoves = 0
        var bestMoveMismatches = 0
        var firstMismatch = ""

        for c in Self.fixtures.move_cases {
            guard let pyScores = c.scores, let pyBest = c.best_index, !c.moves.isEmpty else { continue }
            let board = makeBoard(c.points, config: config)
            let color = parseColor(c.color)
            let dice = Dice(numberOfSides: config.dieSides)
            dice.set(c.dice[0], c.dice[1])
            let swiftMoves = PossibleMoves(board: board, color: color, dice: dice).findMoves()
            guard !swiftMoves.isEmpty else {
                XCTFail("Swift produced no moves where Python had \(c.moves.count) (dice \(c.dice))")
                continue
            }
            let swiftScores = try Self.agent.evaluateMoves(board, swiftMoves, color: color)

            // Python score by move signature (a move's afterstate, hence score, is
            // order-independent, so signature is a sound key).
            var pyScoreBySig = [String: Float]()
            for (i, m) in c.moves.enumerated() { pyScoreBySig[normalizeMove(m)] = pyScores[i] }

            for (i, m) in swiftMoves.enumerated() {
                let sig = normalizeMove(swiftMovePairs([m])[0])
                guard let py = pyScoreBySig[sig] else {
                    XCTFail("no Python score for Swift move \(sig)")
                    continue
                }
                maxScoreDiff = max(maxScoreDiff, abs(swiftScores[i] - py))
                checkedMoves += 1
            }

            // Best move: compare chosen signatures; tolerate a genuine numeric tie.
            var swiftBest = 0
            for i in 1..<swiftScores.count where swiftScores[i] > swiftScores[swiftBest] { swiftBest = i }
            let swiftBestSig = normalizeMove(swiftMovePairs([swiftMoves[swiftBest]])[0])
            let pyBestSig = normalizeMove(c.moves[pyBest])
            if swiftBestSig != pyBestSig {
                let a = pyScoreBySig[swiftBestSig] ?? -1
                let b = pyScoreBySig[pyBestSig] ?? -1
                if abs(a - b) > tieEps {
                    bestMoveMismatches += 1
                    if firstMismatch.isEmpty {
                        firstMismatch = "dice=\(c.dice) color=\(c.color): swift picked \(swiftBestSig) (py=\(a)) vs python \(pyBestSig) (py=\(b))"
                    }
                }
            }
            checkedCases += 1
        }

        print("AgentParity: \(checkedCases) cases, \(checkedMoves) moves, maxScoreDiff=\(maxScoreDiff)")
        XCTAssertLessThanOrEqual(maxScoreDiff, scoreTol, "1-ply score diff exceeds tolerance")
        XCTAssertEqual(bestMoveMismatches, 0, "best-move mismatches (non-tie). First: \(firstMismatch)")
    }
}
