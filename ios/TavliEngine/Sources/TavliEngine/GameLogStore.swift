import Foundation

/// Lightweight description of a logged game, for listing the history without fully
/// decoding every entry. Mirrors `SaveMetadata` but adds the per-game fields the log
/// keeps (#104): the outcome, the AI opponent, and whether analysis has been saved.
public struct GameLogMetadata: Equatable, Identifiable {
    public var id: UUID { gameId }
    public let gameId: UUID
    public let filename: String
    public let name: String
    public let playedAt: Date
    /// The winner's raw `Color` value ("W"/"B"), or `nil` if the game was logged
    /// without a decided outcome.
    public let outcome: String?
    /// The side the AI played, raw `Color` value, or `nil` for human-vs-human.
    public let aiColor: String?
    public let plyCount: Int
    /// Whether post-game analysis has already been written back for this game.
    public let hasAnalysis: Bool
}

/// Append-only log of **every** finished game (#104), one JSON file per game under
/// `directory` (the app uses `Documents/GameLog`). Distinct from the `SaveStore`
/// autosave slot — that keeps only the last in-progress game for resume, whereas the
/// log keeps every completed game and is never pruned by default. Reuses `GameSave`
/// as the wire format, so a logged game is itself replayable; post-game analysis is
/// patched back in via `attachAnalysis` and read back on a later review/drill so it
/// never recomputes.
///
/// All IO is synchronous, matching `SaveStore` (the end-of-game append must complete
/// before the app suspends).
public final class GameLogStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// A store rooted at `Documents/GameLog`.
    public static func `default`() -> GameLogStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return GameLogStore(directory: docs.appendingPathComponent("GameLog", isDirectory: true))
    }

    /// The per-game filename for a stable game id. One file per game id, so a re-log
    /// of the same game (e.g. analysis write-back) overwrites in place rather than
    /// duplicating.
    public static func filename(for gameId: UUID) -> String {
        "game-\(gameId.uuidString).json"
    }

    // ── Writing ────────────────────────────────────────────────────────────────

    /// Append (or overwrite by game id) a finished game. Called from the end-of-game
    /// hook for every game, regardless of outcome or manual save. The `gameId` must be
    /// set on the record (it always is for a live session); a `save` lacking one is
    /// given a fresh id so the write still lands somewhere addressable.
    @discardableResult
    public func append(_ save: GameSave) throws -> UUID {
        let id = save.gameId ?? UUID()
        var stamped = save
        stamped.gameId = id
        try write(stamped, gameId: id)
        return id
    }

    private func write(_ save: GameSave, gameId: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(save)
        try data.write(to: directory.appendingPathComponent(Self.filename(for: gameId)),
                       options: .atomic)
    }

    /// Patch the analysis of a logged game in place (#104), bumping it to schema v2.
    /// No-op-safe: if no entry exists for `gameId` (e.g. the log was cleared), nothing
    /// is written. Returns whether a matching entry was found and updated.
    @discardableResult
    public func attachAnalysis(_ analysis: [AnalysisEntry], forGameId gameId: UUID) throws -> Bool {
        let url = directory.appendingPathComponent(Self.filename(for: gameId))
        guard var save = try? read(url) else { return false }
        save.analysis = analysis
        try write(save, gameId: gameId)
        return true
    }

    // ── Reading ────────────────────────────────────────────────────────────────

    /// Every logged game, newest first. Unreadable or incompatible files are skipped
    /// (same policy as `SaveStore.list()`).
    public func list() -> [GameLogMetadata] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> GameLogMetadata? in
                guard let save = try? read(url), let id = save.gameId else { return nil }
                return GameLogMetadata(
                    gameId: id,
                    filename: url.lastPathComponent,
                    name: save.name,
                    playedAt: save.savedAt,
                    outcome: save.outcome,
                    aiColor: save.aiColor,
                    plyCount: save.history.count,
                    hasAnalysis: save.analysis != nil
                )
            }
            .sorted { $0.playedAt > $1.playedAt }
    }

    /// Load a logged game by id, or `nil` if absent/unreadable.
    public func load(gameId: UUID) -> GameSave? {
        try? read(directory.appendingPathComponent(Self.filename(for: gameId)))
    }

    /// The saved analysis for a game (#104), or `nil` if the game isn't logged or
    /// carries no analysis yet — so a review/drill knows whether it can skip
    /// re-analysis and reuse the cached result.
    public func analysis(forGameId gameId: UUID) -> [AnalysisEntry]? {
        load(gameId: gameId)?.analysis
    }

    public func delete(gameId: UUID) throws {
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(Self.filename(for: gameId)))
    }

    private func read(_ url: URL) throws -> GameSave {
        let data = try Data(contentsOf: url)
        let save = try Self.decoder.decode(GameSave.self, from: data)
        guard save.schemaVersion <= GameSave.currentSchemaVersion else {
            throw SaveStoreError.incompatibleSchema(save.schemaVersion)
        }
        return save
    }

    // ── Codable config (shared so reads and writes agree, matching SaveStore) ─────

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
