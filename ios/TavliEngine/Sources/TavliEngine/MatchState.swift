import Foundation

/// Best-of-N match score (#145). A pure value type shared by the offline (vs-AI) and
/// online (Game Center) surfaces: it tracks how many games each side has won and
/// derives who starts the current game. A match runs a *sequence* of ordinary
/// `GameSession`s; this only carries the score between them — no board state.
///
/// `Codable` so the online wire format (`OnlineMatchPayload`) can carry the score.
/// Winners are stored as raw `Color` values ("W"/"B"), matching the convention in
/// `GameSave`/`OnlineMatchPayload` (`Color` itself is not `Codable`).
public struct MatchState: Codable, Equatable, Sendable {
    /// Games a side must win to take the match (best-of-three → 2; a single game → 1).
    public let targetWins: Int
    /// The side that starts game 1; subsequent games alternate from this.
    public let baseStartingPlayer: Color
    /// Winner of each completed game, in play order.
    public private(set) var gameWinners: [Color]

    public init(targetWins: Int, baseStartingPlayer: Color, gameWinners: [Color] = []) {
        self.targetWins = max(1, targetWins)
        self.baseStartingPlayer = baseStartingPlayer
        self.gameWinners = gameWinners
    }

    /// Best-of-three: first to two games.
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

    // ── Codable (winners as raw "W"/"B"; Color is not itself Codable) ─────────────

    private enum CodingKeys: String, CodingKey {
        case targetWins, baseStartingPlayer, gameWinners
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetWins = max(1, try c.decode(Int.self, forKey: .targetWins))
        baseStartingPlayer = Color(rawValue: try c.decode(String.self, forKey: .baseStartingPlayer)) ?? .black
        gameWinners = try c.decode([String].self, forKey: .gameWinners).compactMap(Color.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(targetWins, forKey: .targetWins)
        try c.encode(baseStartingPlayer.rawValue, forKey: .baseStartingPlayer)
        try c.encode(gameWinners.map(\.rawValue), forKey: .gameWinners)
    }

    // ── Derived status ───────────────────────────────────────────────────────────

    public func wins(for color: Color) -> Int { gameWinners.filter { $0 == color }.count }

    public var completedGames: Int { gameWinners.count }

    /// 1-based number of the game currently being played (or about to be).
    public var currentGameNumber: Int { completedGames + 1 }

    /// The most games the match could span (best-of-three → 3).
    public var maxGames: Int { targetWins * 2 - 1 }

    /// The match winner once a side reaches `targetWins`, else `nil`.
    public var matchWinner: Color? {
        if wins(for: .white) >= targetWins { return .white }
        if wins(for: .black) >= targetWins { return .black }
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

    /// Record a finished game's winner. No-op once the match is already decided, so a
    /// stray extra game can never overturn a settled result.
    public mutating func recordGame(winner: Color) {
        guard !isComplete else { return }
        gameWinners.append(winner)
    }
}
