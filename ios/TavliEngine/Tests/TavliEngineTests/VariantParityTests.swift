import Foundation
import XCTest
import CoreML
@testable import TavliEngine

/// Agent-level parity against Python's `ai/agent.py` with a seeded random-init value
/// net (no trained model exists for these variants yet): the generator scores every
/// move case at 1-ply and a sample at 2-ply (`_evaluate_moves_nply`, standard beam
/// settings) and exports the same net as `<Model>Value.mlpackage`.
enum VariantAgentParity {
    static func agent(for variant: any GameVariant) throws -> Agent {
        let name = variant.modelResourceName
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "mlpackage", subdirectory: "Fixtures")
                ?? bundle.url(forResource: name, withExtension: "mlpackage") else {
            throw NSError(domain: "Fixtures", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\(name).mlpackage not found — run ios/scripts/generate_test_fixtures.py --variant \(variant.id)"])
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuOnly   // match Python CPU inference
        let model = try MLModel(contentsOf: try MLModel.compileModel(at: url), configuration: cfg)
        return Agent(model: model, config: GameConfig(variant: variant))
    }

    static func check1Ply(_ fx: VariantFixtures, _ variant: any GameVariant) throws {
        guard fx.has_scores else { throw XCTSkip("fixtures generated with --no-model") }
        let agent = try agent(for: variant)
        var maxDiff: Float = 0, moves = 0, cases = 0, bestMismatch = 0
        for c in fx.move_cases {
            guard let py = c.scores, !c.moves.isEmpty else { continue }
            let board = makeVariantBoard(c.position, variant: variant)
            let dice = Dice()
            dice.set(c.dice[0], c.dice[1])
            let color = parseColor(c.color)
            let legal = variant.legalMoves(on: board, color: color, dice: dice)
            XCTAssertEqual(swiftMovePairs(legal), c.moves)
            let before = variantKey(board)
            let sw = try agent.evaluateMoves(board, legal, color: color)
            XCTAssertEqual(variantKey(board), before, "scoring left the board mutated")
            for i in sw.indices { maxDiff = max(maxDiff, abs(sw[i] - py[i])) }
            let sb = Agent.argmax(sw), pb = Agent.argmax(py)
            if sb != pb && abs(py[sb] - py[pb]) > 1e-5 { bestMismatch += 1 }
            moves += sw.count
            cases += 1
        }
        print("\(fx.variant) agent 1-ply parity: \(cases) cases, \(moves) moves, maxScoreDiff=\(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 1e-4)
        XCTAssertEqual(bestMismatch, 0, "1-ply best-move mismatches")
    }

    static func check2Ply(_ fx: VariantFixtures, _ variant: any GameVariant) throws {
        guard fx.has_scores, !fx.nply_cases.isEmpty else { throw XCTSkip("fixtures generated with --no-model") }
        let agent = try agent(for: variant)
        var maxDiff: Float = 0, bestMismatch = 0
        for c in fx.nply_cases {
            let board = makeVariantBoard(c.position, variant: variant)
            let dice = Dice()
            dice.set(c.dice[0], c.dice[1])
            let color = parseColor(c.color)
            let legal = variant.legalMoves(on: board, color: color, dice: dice)
            XCTAssertEqual(swiftMovePairs(legal), c.moves)
            let sw = try agent.evaluateMovesNply(
                board, legal, color: color, depth: 2,
                beamThreshold: fx.nply.beam_threshold, relativeCutoff: fx.nply.relative_cutoff,
                maxBranch: fx.nply.max_branch, deadline: nil)
            for i in sw.indices { maxDiff = max(maxDiff, abs(sw[i] - c.scores[i])) }
            let sb = Agent.argmax(sw), pb = Agent.argmax(c.scores)
            if sb != pb && abs(c.scores[sb] - c.scores[pb]) > 1e-4 { bestMismatch += 1 }
        }
        print("\(fx.variant) agent 2-ply parity: \(fx.nply_cases.count) cases, maxScoreDiff=\(maxDiff)")
        XCTAssertLessThanOrEqual(maxDiff, 1e-3)
        XCTAssertEqual(bestMismatch, 0, "2-ply best-move mismatches")
    }
}

/// One fixture load per variant for the whole test run.
private var fixtureCache: [String: VariantFixtures] = [:]
func variantFixtures(_ v: any GameVariant) throws -> VariantFixtures {
    if let f = fixtureCache[v.id] { return f }
    let f = try VariantFixtures.load(v.id)
    fixtureCache[v.id] = f
    return f
}

final class StandardPlakotoParityTests: XCTestCase {
    private let v: any GameVariant = GameVariants.plakotoStandard
    func testMetadata() throws { VariantParity.checkMetadata(try variantFixtures(v), v) }
    func testEncodingParity() throws { VariantParity.checkEncodings(try variantFixtures(v), v) }
    func testLegalMoveAndApplyUndoParity() throws { VariantParity.checkMoves(try variantFixtures(v), v) }
    func testOutcomeParity() throws { VariantParity.checkOutcomes(try variantFixtures(v), v) }
    func testAgent1PlyParity() throws { try VariantAgentParity.check1Ply(try variantFixtures(v), v) }
    func testAgent2PlyParity() throws { try VariantAgentParity.check2Ply(try variantFixtures(v), v) }
}

