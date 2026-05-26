import Foundation
import XCTest
@testable import TavliEngine

struct Fixtures: Decodable {
    struct Config: Decodable {
        let board_size: Int
        let pieces_per_player: Int
        let home_size: Int
        let die_sides: Int
    }
    struct EncodingCase: Decodable {
        let points: [[String]]
        let is_whites_turn: Bool
        let encoding: [Float]
    }
    struct MoveCase: Decodable {
        let points: [[String]]
        let color: String
        let dice: [Int]
        let moves: [[[Int]]]
        let scores: [Float]?
        let best_index: Int?
    }
    let config: Config
    let encoder_version: String
    let input_size: Int
    let has_scores: Bool
    let encoding_cases: [EncodingCase]
    let move_cases: [MoveCase]
}

enum FixtureLoader {
    static func load() throws -> Fixtures {
        let bundle = Bundle.module
        let url = bundle.url(forResource: "fixtures", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "fixtures", withExtension: "json")
        guard let url else {
            throw NSError(domain: "Fixtures", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "fixtures.json not found in test bundle"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixtures.self, from: data)
    }
}

func parseColor(_ s: String) -> Color { s == "W" ? .white : .black }

func makeBoard(_ points: [[String]], config: GameConfig) -> GameBoard {
    let board = GameBoard(config: config)
    for (i, stack) in points.enumerated() {
        board.setPoint(i, pieces: stack.map(parseColor))
    }
    return board
}

func gameConfig(_ c: Fixtures.Config) -> GameConfig {
    GameConfig(boardSize: c.board_size, piecesPerPlayer: c.pieces_per_player,
               homeSize: c.home_size, dieSides: c.die_sides)
}

/// Normalize a move list into an order-independent, comparable signature:
/// each move's half-moves are sorted, then the move list is sorted. Two moves
/// with the same half-moves in different order are physically identical, so this
/// is the right equivalence for AI parity.
func normalizeMoves(_ moves: [[[Int]]]) -> [String] {
    moves.map { move in
        move.map { "\($0[0])->\($0[1])" }.sorted().joined(separator: ",")
    }.sorted()
}

func swiftMovePairs(_ moves: [Move]) -> [[[Int]]] {
    moves.map { move in move.halfMoves.map { [$0.from.position, $0.to.position] } }
}
