import Foundation
import XCTest
@testable import TavliEngine

final class ParityTests: XCTestCase {
    private static var fixtures: Fixtures!

    override class func setUp() {
        super.setUp()
        fixtures = try! FixtureLoader.load()
    }

    private var fx: Fixtures { Self.fixtures }

    func testInputSizeMatches() {
        let encoder = BoardEncoder(config: gameConfig(fx.config))
        XCTAssertEqual(encoder.inputSize, fx.input_size)
        XCTAssertEqual(fx.input_size, 486)
        XCTAssertEqual(fx.encoder_version, "unary_v3")
    }

    func testEncodingParity() {
        let config = gameConfig(fx.config)
        let encoder = BoardEncoder(config: config)
        let tol: Float = 1e-5
        var maxDiff: Float = 0
        var worst = -1
        for (idx, c) in fx.encoding_cases.enumerated() {
            let board = makeBoard(c.points, config: config)
            let enc = encoder.encode(board, isWhitesTurn: c.is_whites_turn)
            XCTAssertEqual(enc.count, c.encoding.count, "case \(idx) length mismatch")
            for k in 0..<min(enc.count, c.encoding.count) {
                let d = abs(enc[k] - c.encoding[k])
                if d > maxDiff { maxDiff = d; worst = idx }
            }
        }
        XCTAssertLessThanOrEqual(maxDiff, tol,
            "max encoding abs-diff \(maxDiff) at case \(worst) exceeds \(tol)")
    }

    func testLegalMoveParity() {
        let config = gameConfig(fx.config)
        var mismatches = 0
        var firstMismatch = ""
        for c in fx.move_cases {
            let board = makeBoard(c.points, config: config)
            let dice = Dice(numberOfSides: config.dieSides)
            dice.set(c.dice[0], c.dice[1])
            let moves = PossibleMoves(board: board, color: parseColor(c.color), dice: dice).findMoves()
            let got = normalizeMoves(swiftMovePairs(moves))
            let want = normalizeMoves(c.moves)
            if got != want {
                mismatches += 1
                if firstMismatch.isEmpty {
                    firstMismatch = "dice=\(c.dice) color=\(c.color) want \(want.count) moves, got \(got.count)"
                        + "\n  missing: \(Set(want).subtracting(got).sorted().prefix(5))"
                        + "\n  extra:   \(Set(got).subtracting(want).sorted().prefix(5))"
                }
            }
        }
        XCTAssertEqual(mismatches, 0,
            "\(mismatches)/\(fx.move_cases.count) move-gen mismatches. First: \(firstMismatch)")
    }
}
