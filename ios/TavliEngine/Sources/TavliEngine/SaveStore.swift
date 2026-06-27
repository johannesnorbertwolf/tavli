import Foundation

/// Lightweight description of a save on disk, for listing without fully loading
/// every game. Decoded from the file header alongside a `plyCount` derived from
/// the history length.
public struct SaveMetadata: Equatable, Identifiable {
    public var id: String { filename }
    public let filename: String
    public let name: String
    public let savedAt: Date
    public let plyCount: Int
    public let isAutosave: Bool
}

public enum SaveStoreError: Error {
    /// The file decoded but its `schemaVersion` is not understood by this build.
    case incompatibleSchema(Int)
}

/// File-backed store for `GameSave`s, one JSON file per game under `directory`
/// (the app uses `Documents/SavedGames`). Holds a single reserved **autosave**
/// slot plus any number of named manual saves. All IO is synchronous so the
/// autosave completes before the app suspends.
public final class SaveStore {
    public let directory: URL

    /// The reserved filename for the background auto-save. Listed and loadable
    /// like any other save, but overwritten on every backgrounding.
    public static let autosaveFilename = "autosave.json"

    public init(directory: URL) {
        self.directory = directory
    }

    /// A store rooted at `Documents/SavedGames`.
    public static func `default`() -> SaveStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return SaveStore(directory: docs.appendingPathComponent("SavedGames", isDirectory: true))
    }

    // ── Reading ──────────────────────────────────────────────────────────────

    /// Every readable save, newest first. Unreadable or incompatible files are
    /// skipped rather than surfaced as errors.
    public func list() -> [SaveMetadata] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SaveMetadata? in
                guard let save = try? read(url) else { return nil }
                return SaveMetadata(
                    filename: url.lastPathComponent,
                    name: save.name,
                    savedAt: save.savedAt,
                    plyCount: save.history.count,
                    isAutosave: url.lastPathComponent == Self.autosaveFilename
                )
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    public func load(filename: String) throws -> GameSave {
        try read(directory.appendingPathComponent(filename))
    }

    /// The auto-save game, or `nil` if none has been written (or it is unreadable).
    public func loadAutosave() -> GameSave? {
        try? load(filename: Self.autosaveFilename)
    }

    private func read(_ url: URL) throws -> GameSave {
        let data = try Data(contentsOf: url)
        let save = try Self.decoder.decode(GameSave.self, from: data)
        // Accept every schema up to the newest this build writes (#104): a v1 file
        // (no analysis) and a v2 file (with analysis) both decode — `GameSave`'s
        // tolerant decoder treats the missing v1 keys as absent. Only a *newer*
        // version than we understand is skipped, so a forward-incompatible file from
        // a future build can't be silently misread.
        guard save.schemaVersion <= GameSave.currentSchemaVersion else {
            throw SaveStoreError.incompatibleSchema(save.schemaVersion)
        }
        return save
    }

    // ── Writing ──────────────────────────────────────────────────────────────

    /// Write `save` to `filename` (atomically), creating the directory if needed.
    public func write(_ save: GameSave, filename: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder.encode(save)
        try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }

    /// Persist `save` to the reserved auto-save slot.
    public func writeAutosave(_ save: GameSave) throws {
        try write(save, filename: Self.autosaveFilename)
    }

    /// Write a manual save under a fresh, collision-free filename and return it.
    /// The display name is taken from `save.name`; the filename is independent so
    /// repeated names never clobber each other.
    @discardableResult
    public func writeManual(_ save: GameSave) throws -> String {
        let filename = "save-\(UUID().uuidString.prefix(8)).json"
        try write(save, filename: filename)
        return filename
    }

    public func delete(filename: String) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }

    public func clearAutosave() {
        try? delete(filename: Self.autosaveFilename)
    }

    // ── Codable config (shared so reads and writes agree) ─────────────────────

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
