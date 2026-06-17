import Foundation

/// File-backed store for the single `Tournament`, one JSON file under `directory`
/// (the app uses `Documents/Tournament`). Synchronous IO so a save completes
/// before the app suspends; schema-versioned (an unreadable or incompatible file
/// reads as `nil`, so the app falls back to a fresh default). Modeled on
/// `SaveStore`.
public final class TournamentStore {
    public let directory: URL

    public static let filename = "tournament.json"

    public init(directory: URL) {
        self.directory = directory
    }

    /// A store rooted at `Documents/Tournament`.
    public static func `default`() -> TournamentStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return TournamentStore(directory: docs.appendingPathComponent("Tournament", isDirectory: true))
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.filename) }

    /// The saved tournament, or `nil` if none has been written (or it's unreadable
    /// / from an incompatible schema).
    public func load() -> Tournament? {
        guard let data = try? Data(contentsOf: fileURL),
              let tournament = try? Self.decoder.decode(Tournament.self, from: data),
              tournament.schemaVersion == Tournament.currentSchemaVersion else {
            return nil
        }
        return tournament
    }

    /// Persist `tournament` atomically, creating the directory if needed. Failures
    /// are swallowed (a dropped tournament save is recoverable on the next change).
    public func save(_ tournament: Tournament) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? Self.encoder.encode(tournament) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
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
