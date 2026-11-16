import Foundation

/// The result of one finished game of a match (#143): the winner (`nil` = draw) and
/// the points it is worth (1 single, 2 double; 0 for a draw).
public struct MatchGameResult: Codable, Equatable, Sendable {
    public let winner: Color?
    public let points: Int

    public init(winner: Color?, points: Int = 1) {
        self.winner = winner
        self.points = winner == nil ? 0 : max(1, points)
    }

    public static func win(_ winner: Color, points: Int = 1) -> MatchGameResult {
        MatchGameResult(winner: winner, points: points)
    }

    public static let draw = MatchGameResult(winner: nil, points: 0)

    public var isDraw: Bool { winner == nil }

    private enum CodingKeys: String, CodingKey { case winner, points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = try c.decodeIfPresent(String.self, forKey: .winner).flatMap(Color.init(rawValue:))
        self.init(winner: w, points: try c.decodeIfPresent(Int.self, forKey: .points) ?? 1)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(winner?.rawValue, forKey: .winner)
        try c.encode(points, forKey: .points)
    }
}

public extension GameRecord {
    /// The finished game's result (winner + points, or a draw), or `nil` while the
    /// game is still running. Points default to 1 for Plakoto (which records none).
    var result: MatchGameResult? {
        if isDraw { return .draw }
        guard let outcome else { return nil }
        return .win(outcome, points: points ?? 1)
    }
}

/// Best-of-N match score (#145). A pure value type shared by the offline (vs-AI) and
/// online (Game Center) surfaces: it tracks each finished game's result and derives
/// the score and who starts the current game. A match runs a *sequence* of ordinary
/// `GameSession`s; this only carries the score between them — no board state.
///
/// **Points and draws (#143).** The score is the sum of **points** won, so in a variant
/// with 2-point wins (`maxPoints > 1`) a double game counts 2 and can decide a
/// first-to-2 match on its own; Plakoto records every win as 1, i.e. games won. A drawn
/// game scores nothing and is replayed (it extends `maxGames`).
///
/// `Codable` so the online wire format can carry the score. Winners are stored as raw
/// `Color` values ("W"/"B"), matching `GameSave`/`OnlineMatchPayload` (`Color` itself
/// is not `Codable`); the legacy `gameWinners` key is still written for older readers.
public struct MatchState: Codable, Equatable, Sendable {
    /// Points a side must reach to take the match (best-of-three → 2; a single game → 1).
    public let targetWins: Int
    /// The side that starts game 1; subsequent games alternate from this.
    public let baseStartingPlayer: Color
    /// Result of each completed game, in play order (draws included).
    public private(set) var results: [MatchGameResult]

    public init(targetWins: Int, baseStartingPlayer: Color, results: [MatchGameResult]) {
        self.targetWins = max(1, targetWins)
        self.baseStartingPlayer = baseStartingPlayer
        self.results = results
    }

    /// Legacy form: every listed game a 1-point win.
    public init(targetWins: Int, baseStartingPlayer: Color, gameWinners: [Color] = []) {
        self.init(targetWins: targetWins, baseStartingPlayer: baseStartingPlayer,
                  results: gameWinners.map { .win($0) })
    }

    /// Best-of-three: first to two points (games, in Plakoto).
    public static func bestOfThree(baseStartingPlayer: Color,
                                   gameWinners: [Color] = []) -> MatchState {
        MatchState(targetWins: 2, baseStartingPlayer: baseStartingPlayer, gameWinners: gameWinners)
    }

    /// A single game (`targetWins` 1) — the non-match case, modelled uniformly so the
    /// online path can treat every match the same.
    public static func single(baseStartingPlayer: Color,
                              gameWinners: [Color] = []) -> MatchState {
        MatchState(targetWins: 1, baseStartingPlayer: baseStartingPlayer, gameWinners: gameWinners)
    }

    // ── Codable (raw "W"/"B"; `results` added by #143, `gameWinners` kept) ────────

    private enum CodingKeys: String, CodingKey {
        case targetWins, baseStartingPlayer, gameWinners, results
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetWins = max(1, try c.decode(Int.self, forKey: .targetWins))
        baseStartingPlayer = Color(rawValue: try c.decode(String.self, forKey: .baseStartingPlayer)) ?? .black
        if let results = try c.decodeIfPresent([MatchGameResult].self, forKey: .results) {
            self.results = results
        } else {
            results = (try c.decodeIfPresent([String].self, forKey: .gameWinners) ?? [])
                .compactMap(Color.init(rawValue:)).map { .win($0) }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(targetWins, forKey: .targetWins)
        try c.encode(baseStartingPlayer.rawValue, forKey: .baseStartingPlayer)
        try c.encode(gameWinners.map(\.rawValue), forKey: .gameWinners)
        try c.encode(results, forKey: .results)
    }

    // ── Derived status ───────────────────────────────────────────────────────────

    /// Winners of the decided (non-drawn) games, in order.
    public var gameWinners: [Color] { results.compactMap(\.winner) }

    /// Games `color` has won (any number of points each).
    public func wins(for color: Color) -> Int { gameWinners.filter { $0 == color }.count }

    /// `color`'s match score: the points of every game it won.
    public func score(for color: Color) -> Int {
        results.filter { $0.winner == color }.reduce(0) { $0 + $1.points }
    }

    /// Drawn games so far.
    public var draws: Int { results.filter(\.isDraw).count }

    public var completedGames: Int { results.count }

    /// 1-based number of the game currently being played (or about to be).
    public var currentGameNumber: Int { completedGames + 1 }

    /// The most games the match could span (best-of-three → 3), plus one per draw
    /// (a drawn game is replayed).
    public var maxGames: Int { targetWins * 2 - 1 + draws }

    /// The match winner once a side's score reaches `targetWins`, else `nil`.
    public var matchWinner: Color? {
        if score(for: .white) >= targetWins { return .white }
        if score(for: .black) >= targetWins { return .black }
        return nil
    }

    public var isComplete: Bool { matchWinner != nil }

    /// Whether this is a multi-game match (vs a single game), for UI gating.
    public var isMatch: Bool { targetWins > 1 }

    /// Who starts the current game: the base starter when an even number of games are
    /// complete, their opponent when odd — a deterministic alternation both online
    /// devices agree on without an opening-roll ceremony for games 2+.
    public var currentStartingPlayer: Color {
        completedGames % 2 == 0 ? baseStartingPlayer : baseStartingPlayer.opponent
    }

    /// Record a finished game. No-op once the match is already decided, so a stray
    /// extra game can never overturn a settled result.
    public mutating func record(_ result: MatchGameResult) {
        guard !isComplete else { return }
        results.append(result)
    }

    /// Record a 1-point win (Plakoto).
    public mutating func recordGame(winner: Color) {
        record(.win(winner))
    }

    /// Record a finished game: `winner == nil` is a draw (no points).
    public mutating func recordGame(winner: Color?, points: Int) {
        record(MatchGameResult(winner: winner, points: points))
    }
}
