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
public struct GameRecord: Equatable, Sendable {
    /// Stable identity for the game, generated once when the game starts. Lets the
    /// automatic game log (#104) name a per-game file and lets post-game analysis
    /// find and patch the matching entry. Two `GameRecord`s differing only by id are
    /// still considered different games.
    public var gameId: UUID
    public var startingPlayer: Color
    public var aiColor: Color?
    public var plies: [PlyRecord]
    /// The winner once the game is over, else `nil` while it is in progress.
    public var outcome: Color?

    public init(startingPlayer: Color,
                aiColor: Color? = nil,
                plies: [PlyRecord] = [],
                outcome: Color? = nil,
                gameId: UUID = UUID()) {
        self.gameId = gameId
        self.startingPlayer = startingPlayer
        self.aiColor = aiColor
        self.plies = plies
        self.outcome = outcome
    }
}
public struct PlyRecord: Codable, Equatable, Sendable {
    public let die1: Int
    public let die2: Int
    public let halfMoves: [[Int]]

    public init(die1: Int, die2: Int, halfMoves: [[Int]]) {
        self.die1 = die1
        self.die2 = die2
        self.halfMoves = halfMoves
    }
}

/// One re-evaluated ply, persisted alongside a game so post-game analysis (review /
/// drill) never has to recompute (#104). The on-disk analogue of `PlyEvaluation`,
/// trimmed to the durable fields — the large pre-move `boardStacks` are intentionally
/// excluded (they reconstruct from the move replay). Scores are stored as `Double`
/// (JSON has no `Float`); `depth` is the deepest look-ahead reached for this ply
/// (#103's progressive 1→2→3-ply). The field names match the Python `analysis`
/// schema exactly so the two platforms stay interchangeable.
public struct AnalysisEntry: Codable, Equatable, Sendable {
    /// 1-based index of this ply within the game's plies.
    public let plyNumber: Int
    /// The move actually played, as `[from, to]` half-move pairs.
    public let playedMove: [[Int]]
    /// Win probability for the mover of the played move.
    public let playedScore: Double
    /// The AI's best legal move at this position, as `[from, to]` pairs.
    public let bestMove: [[Int]]
    /// Win probability for the mover of the best move.
    public let bestScore: Double
    /// Deepest look-ahead depth this evaluation reached (1/2/3 under progressive
    /// analysis, #103).
    public let depth: Int

    public init(plyNumber: Int, playedMove: [[Int]], playedScore: Double,
                bestMove: [[Int]], bestScore: Double, depth: Int) {
        self.plyNumber = plyNumber
        self.playedMove = playedMove
        self.playedScore = playedScore
        self.bestMove = bestMove
        self.bestScore = bestScore
        self.depth = depth
    }
}

/// A serialized game. Stores only the move history (not the board), so it loads
/// correctly even after a different value model is bundled — the network only ever
/// chose the *recorded* moves; replaying them is model-agnostic.
///
/// **Schema versions (#104).** `schemaVersion: 1` is the original resume save
/// (no `analysis`). `schemaVersion: 2` additionally carries an optional `analysis`
/// array of per-ply evaluations; a v2 file *without* analysis is byte-compatible
/// with a v1 reader (the extra `gameId`/`outcome`/`analysis` keys are simply
/// ignored), and a file gains the version-2 marker only when an `analysis` block is
/// actually written. Decoding tolerates both versions: a v1 file reads as a game
/// with empty analysis; the unknown-version skip in `SaveStore` only triggers above
/// `currentSchemaVersion`.
public struct GameSave: Codable, Equatable {
    /// The newest schema this build writes. v1 files still decode (analysis empty).
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    /// Stable per-game identity (#104). Optional for back-compat: pre-#104 saves have
    /// no id, so resume/list still work; only the game log relies on it.
    public var gameId: UUID?
    /// Human-facing title (manual name, or a timestamp for auto/quick saves).
    public var name: String
    public var savedAt: Date
    /// The side that moved first, raw `Color` value ("W"/"B").
    public var startingPlayer: String
    /// The side the AI played, raw `Color` value, or `nil` for human-vs-human.
    public var aiColor: String?
    /// The winner's raw `Color` value once the game is over, else `nil`. Persisted
    /// for the game log (#104) — resume saves left this `nil` (only in-progress games
    /// were saved), and a v1 file without it reads back as `nil`.
    public var outcome: String?
    public var history: [PlyRecord]
    /// Per-ply post-game analysis (#104), or `nil` when none has been computed. When
    /// present the file is written at `schemaVersion: 2`; when `nil` it is omitted and
    /// the file stays v1-reader-compatible.
    public var analysis: [AnalysisEntry]?

    public init(schemaVersion: Int = GameSave.currentSchemaVersion,
                gameId: UUID? = nil,
                name: String,
                savedAt: Date,
                startingPlayer: String,
                aiColor: String?,
                outcome: String? = nil,
                history: [PlyRecord],
                analysis: [AnalysisEntry]? = nil) {
        self.schemaVersion = schemaVersion
        self.gameId = gameId
        self.name = name
        self.savedAt = savedAt
        self.startingPlayer = startingPlayer
        self.aiColor = aiColor
        self.outcome = outcome
        self.history = history
        self.analysis = analysis
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, gameId, name, savedAt, startingPlayer, aiColor, outcome, history, analysis
    }

    /// Decode tolerantly: a v1 file has no `gameId`/`outcome`/`analysis`, so those are
    /// optional. Everything else is required exactly as before.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        gameId = try c.decodeIfPresent(UUID.self, forKey: .gameId)
        name = try c.decode(String.self, forKey: .name)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        startingPlayer = try c.decode(String.self, forKey: .startingPlayer)
        aiColor = try c.decodeIfPresent(String.self, forKey: .aiColor)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        history = try c.decode([PlyRecord].self, forKey: .history)
        analysis = try c.decodeIfPresent([AnalysisEntry].self, forKey: .analysis)
    }

    /// Encode the version the on-disk shape actually warrants: `2` only when an
    /// `analysis` block is present, else `1` so the file round-trips through a v1
    /// reader. `nil` optionals (aiColor/outcome/analysis) are omitted entirely.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let effectiveVersion = analysis == nil ? 1 : 2
        try c.encode(effectiveVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(gameId, forKey: .gameId)
        try c.encode(name, forKey: .name)
        try c.encode(savedAt, forKey: .savedAt)
        try c.encode(startingPlayer, forKey: .startingPlayer)
        try c.encodeIfPresent(aiColor, forKey: .aiColor)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encode(history, forKey: .history)
        try c.encodeIfPresent(analysis, forKey: .analysis)
    }
}

public extension GameSave {
    /// Build a save from a `GameRecord`. Carries the record's `gameId` (#104, for the
    /// game log) and its `outcome` (so a logged terminal game records who won). For a
    /// resume autosave the game is mid-play, so `outcome` is naturally `nil` and the
    /// file stays v1-shaped (no analysis); the game log instead saves finished games.
    init(record: GameRecord, name: String, savedAt: Date = Date(),
         analysis: [AnalysisEntry]? = nil) {
        self.init(gameId: record.gameId,
                  name: name,
                  savedAt: savedAt,
                  startingPlayer: record.startingPlayer.rawValue,
                  aiColor: record.aiColor?.rawValue,
                  outcome: record.outcome?.rawValue,
                  history: record.plies,
                  analysis: analysis)
    }

    /// The save reinterpreted as a `GameRecord`, restoring its `gameId` (a fresh one
    /// for pre-#104 saves that lack it) and `outcome`.
    var record: GameRecord {
        GameRecord(
            startingPlayer: Color(rawValue: startingPlayer) ?? .black,
            aiColor: aiColor.flatMap { Color(rawValue: $0) },
            plies: history,
            outcome: outcome.flatMap { Color(rawValue: $0) },
            gameId: gameId ?? UUID()
        )
    }
}

public extension Array where Element == AnalysisEntry {
    /// Project a finished `GameReviewResult` to the durable `analysis` schema (#104):
    /// one entry per evaluated ply, dropping the bulky `boardStacks` and narrowing the
    /// scores to `Double`. Each entry keeps the deepest `depth` the progressive pass
    /// reached for that ply. The result is what gets written back into the game log.
    init(reviewResult: GameReviewResult) {
        self = reviewResult.evaluations.map { e in
            AnalysisEntry(plyNumber: e.plyNumber,
                          playedMove: e.playedMove,
                          playedScore: Double(e.playedScore),
                          bestMove: e.bestMove,
                          bestScore: Double(e.bestScore),
                          depth: e.depth)
        }
    }
}

public extension GameSession {
    /// Capture the current game as a `GameSave` for persistence.
    func snapshot(name: String, savedAt: Date = Date()) -> GameSave {
        GameSave(record: record, name: name, savedAt: savedAt)
    }
}
