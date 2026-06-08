import Foundation
import Combine

/// One completed human-vs-AI game. The iPad analogue of a line in the CLI's
/// `training_runs/human_game_history.log` (issue #64): results are pooled, so we
/// keep only the timestamp and outcome — no per-opponent / per-model breakdown.
public struct HumanGameRecord: Codable, Equatable, Sendable {
    public let date: Date
    public let humanWon: Bool

    public init(date: Date, humanWon: Bool) {
        self.date = date
        self.humanWon = humanWon
    }
}

/// A summary of the human's record against the AI, derived purely from a list of
/// `HumanGameRecord`s. Mirrors the CLI `_print_human_record` (`main.py`): overall
/// W/L + win rate, a last-20 sparkline (oldest→newest), and the current streak.
public struct HumanGameStats: Equatable, Sendable {
    public let total: Int
    public let wins: Int
    public let losses: Int
    /// Win fraction in [0, 1]; 0 when no games have been played.
    public let winRate: Double
    /// Up to the last 20 outcomes, oldest first (`true` = win) — for the sparkline.
    public let recent: [Bool]
    /// Length of the current run of identical outcomes counting back from the
    /// most recent game (0 when no games have been played).
    public let streakCount: Int
    /// Whether the current streak is a winning streak. `false` when there are no
    /// games (read alongside `streakCount == 0`).
    public let streakIsWin: Bool

    public init(records: [HumanGameRecord]) {
        let total = records.count
        let wins = records.reduce(0) { $0 + ($1.humanWon ? 1 : 0) }
        self.total = total
        self.wins = wins
        self.losses = total - wins
        self.winRate = total == 0 ? 0 : Double(wins) / Double(total)
        self.recent = records.suffix(20).map(\.humanWon)

        guard let last = records.last else {
            self.streakCount = 0
            self.streakIsWin = false
            return
        }
        var count = 0
        for r in records.reversed() {
            if r.humanWon == last.humanWon { count += 1 } else { break }
        }
        self.streakCount = count
        self.streakIsWin = last.humanWon
    }

    /// Convenience for an empty history (no games played yet).
    public static let empty = HumanGameStats(records: [])
}

/// The persisted human game log: a schema-versioned, append-only list of completed
/// game outcomes. The iPad analogue of the CLI's `human_game_history.log`. This is
/// **not** part of the `GameSave`/`SaveStore` game-storage standard on purpose — it
/// records outcomes, not resumable games — but it deliberately follows the same
/// file-backed, schema-versioned conventions (`currentSchemaVersion`, skip on an
/// unrecognized version) so all on-disk data reads the same way.
public struct HumanGameLog: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var games: [HumanGameRecord]

    public init(schemaVersion: Int = HumanGameLog.currentSchemaVersion,
                games: [HumanGameRecord] = []) {
        self.schemaVersion = schemaVersion
        self.games = games
    }
}

/// File-backed store for the `HumanGameLog`, a single JSON file (the app uses
/// `Documents/HumanGameLog.json`). Mirrors `SaveStore`'s conventions: `.iso8601`
/// dates, pretty-printed + sorted-keys encoding, atomic writes, directory created
/// on demand, and an unrecognized `schemaVersion` skipped (read as empty) rather
/// than surfaced — the same way `SaveStore.list()` skips incompatible files.
public final class HumanGameLogStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A store rooted at `Documents/HumanGameLog.json`.
    public static func `default`() -> HumanGameLogStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return HumanGameLogStore(fileURL: docs.appendingPathComponent("HumanGameLog.json"))
    }

    /// The recorded games, or `[]` when the file is missing, unreadable, or written
    /// under a `schemaVersion` this build does not recognize.
    public func load() -> [HumanGameRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let log = try? Self.decoder.decode(HumanGameLog.self, from: data),
              log.schemaVersion == HumanGameLog.currentSchemaVersion else {
            return []
        }
        return log.games
    }

    /// Overwrite the log with `records` (atomically), creating the directory if needed.
    public func save(_ records: [HumanGameRecord]) {
        let log = HumanGameLog(games: records)
        guard let data = try? Self.encoder.encode(log) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
    }

    // ── Codable config (shared so reads and writes agree; mirrors SaveStore) ──
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

/// Observable owner of the human game history. Loads on init, appends on each
/// completed game (persisting immediately), and republishes so SwiftUI panels
/// re-derive `stats`. `@MainActor` because it backs SwiftUI views and is appended
/// to from `GameSession`'s (`@MainActor`) game-over callback.
@MainActor
public final class HumanStatsStore: ObservableObject {
    @Published public private(set) var records: [HumanGameRecord]
    private let store: HumanGameLogStore

    public init(store: HumanGameLogStore = .default()) {
        self.store = store
        self.records = store.load()
    }

    public var stats: HumanGameStats { HumanGameStats(records: records) }

    /// Record the outcome of one completed game and persist it.
    public func record(humanWon: Bool, date: Date = Date()) {
        records.append(HumanGameRecord(date: date, humanWon: humanWon))
        store.save(records)
    }
}
