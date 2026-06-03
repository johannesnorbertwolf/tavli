import Foundation

/// One finished turn: the dice rolled and the half-moves applied, as `[from, to]`
/// board-index pairs. An empty `halfMoves` is a forced pass. Replaying these pairs
/// in order from the initial position reproduces the exact board — no board state
/// is stored (the same replay-based approach as the Python CLI saves).
public struct PlyRecord: Codable, Equatable {
    public let die1: Int
    public let die2: Int
    public let halfMoves: [[Int]]

    public init(die1: Int, die2: Int, halfMoves: [[Int]]) {
        self.die1 = die1
        self.die2 = die2
        self.halfMoves = halfMoves
    }
}

/// A serialized, resumable game. Stores only the move history (not the board), so
/// a save loads correctly even after a different value model is bundled — the
/// network only ever chose the *recorded* moves; replaying them is model-agnostic.
///
/// Bumping `currentSchemaVersion` is intentionally breaking: `SaveStore` skips
/// files whose version it does not recognize rather than migrating them.
public struct GameSave: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Human-facing title (manual name, or a timestamp for auto/quick saves).
    public var name: String
    public var savedAt: Date
    /// The side that moved first, raw `Color` value ("W"/"B").
    public var startingPlayer: String
    /// The side the AI played, raw `Color` value, or `nil` for human-vs-human.
    public var aiColor: String?
    public var history: [PlyRecord]

    public init(schemaVersion: Int = GameSave.currentSchemaVersion,
                name: String,
                savedAt: Date,
                startingPlayer: String,
                aiColor: String?,
                history: [PlyRecord]) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.savedAt = savedAt
        self.startingPlayer = startingPlayer
        self.aiColor = aiColor
        self.history = history
    }
}

public extension GameSession {
    /// Capture the current game as a `GameSave` for persistence.
    func snapshot(name: String, savedAt: Date = Date()) -> GameSave {
        GameSave(
            name: name,
            savedAt: savedAt,
            startingPlayer: startingPlayer.rawValue,
            aiColor: aiColor?.rawValue,
            history: history
        )
    }
}
