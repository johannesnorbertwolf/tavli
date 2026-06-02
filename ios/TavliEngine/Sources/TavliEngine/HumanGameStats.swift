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

/// Where the human game history is persisted. Abstracted so tests can swap in an
/// in-memory backing without touching `UserDefaults`.
public protocol HumanStatsStorage: AnyObject {
    func load() -> [HumanGameRecord]
    func save(_ records: [HumanGameRecord])
}

/// Default persistence: a JSON-encoded array of records in `UserDefaults`, which
/// survives app restarts (the iPad app is offline and sandboxed, so it can't share
/// the CLI's log file — this is the on-device equivalent).
public final class UserDefaultsStatsStorage: HumanStatsStorage {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "humanGameHistory.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [HumanGameRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([HumanGameRecord].self, from: data) else {
            return []
        }
        return records
    }

    public func save(_ records: [HumanGameRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Observable owner of the human game history. Loads on init, appends on each
/// completed game (persisting immediately), and republishes so SwiftUI panels
/// re-derive `stats`. `@MainActor` because it backs SwiftUI views and is appended
/// to from `GameSession`'s (`@MainActor`) game-over callback.
@MainActor
public final class HumanStatsStore: ObservableObject {
    @Published public private(set) var records: [HumanGameRecord]
    private let storage: HumanStatsStorage

    public init(storage: HumanStatsStorage = UserDefaultsStatsStorage()) {
        self.storage = storage
        self.records = storage.load()
    }

    public var stats: HumanGameStats { HumanGameStats(records: records) }

    /// Record the outcome of one completed game and persist it.
    public func record(humanWon: Bool, date: Date = Date()) {
        records.append(HumanGameRecord(date: date, humanWon: humanWon))
        storage.save(records)
    }
}
