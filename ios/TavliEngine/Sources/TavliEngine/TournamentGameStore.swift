import Foundation

/// A persisted in-app tournament game vs the AI (TavTav): the move history needed
/// to resume it, plus the metadata the Setup list shows — who played, which colour,
/// what kind of game, and the outcome once decided. One file per game, rewritten
/// after every move so an interrupted game is never lost. Like `GameSave`, only the
/// move history is stored (no board state), so a save survives a bundled-model swap.
///
/// Local-only: unlike the `Tournament` itself, these per-game saves are **not**
/// synced between iPads (each device keeps the games it actually played).
public struct SavedTournamentGame: Codable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    /// What the game counts for. A `match`/`finale` records its outcome onto the
    /// tournament when it ends; `practice` is unscored.
    public enum Kind: String, Codable, Equatable {
        case match, finale, practice
    }

    public var schemaVersion: Int
    public let id: UUID
    public var kind: Kind

    /// The originating round-robin match (for `.match`), so a *resumed* game can
    /// still write its result back onto the right match.
    public var matchID: UUID?
    /// The tournament player ids, so a resumed game can map its winner back onto the
    /// tournament. `nil` for an anonymous practice game.
    public var humanPlayerID: UUID?
    public var aiPlayerID: UUID?

    /// Display names captured at play time. `humanName` is `nil` for practice.
    public var humanName: String?
    public var aiName: String

    /// The side the human played, raw `Color` value ("W"/"B"). The AI is the opponent.
    public var humanColorRaw: String
    /// The side that moved first, raw `Color` value.
    public var startingPlayerRaw: String
    /// Whether the game was played on the real board (dice keyed in by hand). Restored
    /// on resume so a real-board game doesn't suddenly auto-roll on the iPad.
    public var manualDiceEntry: Bool

    /// Ordered plies, replayed from the initial position to reconstruct the board.
    public var history: [PlyRecord]
    /// The winner once the game is over, raw `Color` value; `nil` while in progress.
    public var outcomeRaw: String?
    /// `true` if the player gave up (conceded the match) on the way out: recorded as a
    /// loss in the standings, but the game is kept in progress and resumable, so the
    /// list shows it as "Aufgegeben" rather than "Läuft". Cleared once the game is
    /// actively played again or finished. Absent (`nil`) on older saves = not conceded.
    public var conceded: Bool?

    public var startedAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                schemaVersion: Int = SavedTournamentGame.currentSchemaVersion,
                kind: Kind,
                matchID: UUID? = nil,
                humanPlayerID: UUID? = nil,
                aiPlayerID: UUID? = nil,
                humanName: String?,
                aiName: String,
                humanColor: Color,
                startingPlayer: Color,
                manualDiceEntry: Bool = false,
                history: [PlyRecord] = [],
                outcome: Color? = nil,
                conceded: Bool? = nil,
                startedAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.matchID = matchID
        self.humanPlayerID = humanPlayerID
        self.aiPlayerID = aiPlayerID
        self.humanName = humanName
        self.aiName = aiName
        self.humanColorRaw = humanColor.rawValue
        self.startingPlayerRaw = startingPlayer.rawValue
        self.manualDiceEntry = manualDiceEntry
        self.history = history
        self.outcomeRaw = outcome?.rawValue
        self.conceded = conceded
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public extension SavedTournamentGame {
    var humanColor: Color { Color(rawValue: humanColorRaw) ?? .white }
    var aiColor: Color { humanColor.opponent }
    var startingPlayer: Color { Color(rawValue: startingPlayerRaw) ?? .black }
    var outcome: Color? { outcomeRaw.flatMap { Color(rawValue: $0) } }

    /// `true` once the game has a recorded winner.
    var isFinished: Bool { outcome != nil }
    /// `true` if the game was left via "give up" and is still resumable (not finished).
    var isConceded: Bool { conceded == true && !isFinished }
    /// `true`/`false` once finished (did the human win?), `nil` while in progress.
    var humanWon: Bool? { outcome.map { $0 == humanColor } }
    var plyCount: Int { history.count }

    /// A `GameSave` view onto this record, for `GameSession.resume(from:)`.
    var gameSave: GameSave {
        GameSave(name: humanName ?? aiName,
                 savedAt: updatedAt,
                 startingPlayer: startingPlayerRaw,
                 aiColor: aiColor.rawValue,
                 history: history)
    }
}

/// File-backed store for `SavedTournamentGame`s, one JSON file per game under
/// `directory` (the app uses `Documents/Tournament/Games`). Synchronous IO so a
/// save completes before the app suspends; modeled on `SaveStore` / `TournamentStore`.
/// Unreadable or incompatible-schema files are skipped rather than surfaced.
public final class TournamentGameStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// A store rooted at `Documents/Tournament/Games`.
    public static func `default`() -> TournamentGameStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return TournamentGameStore(directory: docs.appendingPathComponent("Tournament/Games", isDirectory: true))
    }

    /// Every readable game, newest (`updatedAt`) first. Unreadable or incompatible
    /// files are skipped.
    public func list() -> [SavedTournamentGame] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? read($0) }
            .filter { $0.schemaVersion == SavedTournamentGame.currentSchemaVersion }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func load(id: UUID) -> SavedTournamentGame? {
        try? read(fileURL(for: id))
    }

    /// Persist `game` atomically under its id, creating the directory if needed.
    public func save(_ game: SavedTournamentGame) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(game) else { return }
        try? data.write(to: fileURL(for: game.id), options: .atomic)
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("game-\(id.uuidString).json")
    }

    private func read(_ url: URL) throws -> SavedTournamentGame {
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(SavedTournamentGame.self, from: data)
    }

    // ── Codable config (shared so reads and writes agree) ─────────────────────────

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
