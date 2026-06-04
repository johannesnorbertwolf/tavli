import Foundation

/// One finished turn: the dice rolled and the half-moves applied, as `[from, to]`
/// board-index pairs. An empty `halfMoves` is a forced pass. Replaying these pairs
/// in order from the initial position reproduces the exact board — no board state
/// is stored (the same replay-based approach as the Python CLI saves).
/// The canonical in-memory record of a game: who moved first, which side (if any)
/// the AI plays, the ordered plies, and the outcome once decided. This is the single
/// source of truth a live `GameSession` holds and every history-consuming feature
/// reads. Reconstruction is always by replaying `plies` from the initial position —
/// no board state is stored (see `GameSession.resume`).
public struct GameRecord: Equatable {
    public var startingPlayer: Color
    public var aiColor: Color?
    public var plies: [PlyRecord]
    /// The winner once the game is over, else `nil` while it is in progress.
    public var outcome: Color?

    public init(startingPlayer: Color,
                aiColor: Color? = nil,
                plies: [PlyRecord] = [],
                outcome: Color? = nil) {
        self.startingPlayer = startingPlayer
        self.aiColor = aiColor
        self.plies = plies
        self.outcome = outcome
    }
}

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

public extension GameSave {
    /// Build a save from a `GameRecord`. The on-disk format stays flat strings, so
    /// the wire format is unchanged. `outcome` is not persisted: only in-progress
    /// games are saved today (terminal games clear the autosave).
    init(record: GameRecord, name: String, savedAt: Date = Date()) {
        self.init(name: name,
                  savedAt: savedAt,
                  startingPlayer: record.startingPlayer.rawValue,
                  aiColor: record.aiColor?.rawValue,
                  history: record.plies)
    }

    /// The save reinterpreted as a `GameRecord`. `outcome` is `nil` — the on-disk
    /// format does not carry it (only in-progress games are persisted today).
    var record: GameRecord {
        GameRecord(
            startingPlayer: Color(rawValue: startingPlayer) ?? .black,
            aiColor: aiColor.flatMap { Color(rawValue: $0) },
            plies: history
        )
    }
}

public extension GameSession {
    /// Capture the current game as a `GameSave` for persistence.
    func snapshot(name: String, savedAt: Date = Date()) -> GameSave {
        GameSave(record: record, name: name, savedAt: savedAt)
    }
}
