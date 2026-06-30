import Foundation

/// Errors decoding an online match payload.
public enum OnlineMatchError: Error, Equatable {
    /// The payload was written by a newer build than this one understands.
    case unsupportedSchemaVersion(Int)
}

/// One game within an online match (#145): its ordered ply log and, once the game is
/// over, the winner. Storing the winner explicitly lets every device read the match
/// score without re-running the engine; the plies stay so the opponent can replay and
/// animate the game (including its final, winning move) and so reconnection is exact.
public struct GameLog: Codable, Equatable, Sendable {
    public var plies: [PlyRecord]
    /// Raw `Color` value ("W"/"B") of the winner once the game is over, else `nil`.
    public var winnerRaw: String?

    public init(plies: [PlyRecord] = [], winner: Color? = nil) {
        self.plies = plies
        self.winnerRaw = winner?.rawValue
    }

    public var winner: Color? { winnerRaw.flatMap(Color.init(rawValue:)) }
    public var isComplete: Bool { winner != nil }
}

/// The wire payload stored in a Game Center turn-based match's `matchData` (#134, #145).
///
/// The authoritative state of an online match is simply the **list of its games'
/// ply logs** (plus each finished game's winner): replaying a game's `plies` from the
/// initial position reproduces its exact board, model-independent, exactly as a
/// `GameSave` does (`GameSession.replay`). Game Center persists, syncs, and reloads
/// this blob, so sync, resume, and reconnection all reduce to "decode + replay": there
/// is no board state to reconcile.
///
/// A single game is just a match with `targetWins == 1` and one `GameLog`, so both the
/// single-game (#134) and best-of-three (#145) paths share one shape. The last element
/// of `games` is the current (in-progress or just-finished) game; every earlier game
/// is complete (has a `winner`). The match score derives from the games' winners.
///
/// Colour assignment is carried explicitly (`colorByPlayerID`) rather than inferred
/// from turn order, so each device computes its own side from its Game Center
/// `gamePlayerID` no matter who created the match or who is currently active. The
/// per-game starting player alternates from `startingPlayer` (the game-1 starter), so
/// both devices agree without an opening-roll ceremony for games 2+.
public struct OnlineMatchPayload: Codable, Equatable, Sendable {
    /// Bump when the wire shape changes; decoding rejects anything newer than this.
    /// v2 (#145) replaced the single `plies` field with `games` + `targetWins`; a v1
    /// payload still decodes (its `plies` map to a single game, `targetWins` 1).
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    /// Games a side must win to take the match (1 = single game, 2 = best-of-three).
    public var targetWins: Int
    /// Raw `Color` value ("W"/"B") of the side that starts game 1, resolved once by the
    /// match creator. Stored raw to match `GameSave`'s wire convention. Later games
    /// alternate from this.
    public var startingPlayer: String
    /// Maps each participant's Game Center `gamePlayerID` to the raw `Color` value
    /// ("W"/"B") they play for the whole match.
    public var colorByPlayerID: [String: String]
    /// The match's games in order; the last is the current/just-finished game.
    public var games: [GameLog]

    public init(schemaVersion: Int = OnlineMatchPayload.currentSchemaVersion,
                targetWins: Int = 1,
                startingPlayer: Color,
                colorByPlayerID: [String: Color],
                games: [GameLog] = [GameLog()]) {
        self.schemaVersion = schemaVersion
        self.targetWins = max(1, targetWins)
        self.startingPlayer = startingPlayer.rawValue
        self.colorByPlayerID = colorByPlayerID.mapValues(\.rawValue)
        self.games = games.isEmpty ? [GameLog()] : games
    }

    /// Convenience for a single game expressed as a flat ply list (the #134 shape).
    public init(startingPlayer: Color,
                colorByPlayerID: [String: Color],
                plies: [PlyRecord]) {
        self.init(targetWins: 1,
                  startingPlayer: startingPlayer,
                  colorByPlayerID: colorByPlayerID,
                  games: [GameLog(plies: plies)])
    }

    // ── Codable (back-compatible with the v1 flat-`plies` shape) ──────────────────

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, targetWins, startingPlayer, colorByPlayerID, games, plies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        startingPlayer = try c.decode(String.self, forKey: .startingPlayer)
        colorByPlayerID = try c.decode([String: String].self, forKey: .colorByPlayerID)
        if let games = try c.decodeIfPresent([GameLog].self, forKey: .games) {
            self.games = games.isEmpty ? [GameLog()] : games
            self.targetWins = max(1, try c.decodeIfPresent(Int.self, forKey: .targetWins) ?? 1)
        } else {
            // v1: a flat ply log is a single game.
            let plies = try c.decodeIfPresent([PlyRecord].self, forKey: .plies) ?? []
            self.games = [GameLog(plies: plies)]
            self.targetWins = 1
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(targetWins, forKey: .targetWins)
        try c.encode(startingPlayer, forKey: .startingPlayer)
        try c.encode(colorByPlayerID, forKey: .colorByPlayerID)
        try c.encode(games, forKey: .games)
    }
}

public extension OnlineMatchPayload {
    /// Encode for storage in `GKTurnBasedMatch.matchData`.
    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    /// Decode from `matchData`, rejecting payloads from a newer schema so a stale
    /// build fails loudly instead of silently mishandling unknown fields.
    static func decoded(from data: Data) throws -> OnlineMatchPayload {
        let payload = try JSONDecoder().decode(OnlineMatchPayload.self, from: data)
        guard payload.schemaVersion <= currentSchemaVersion else {
            throw OnlineMatchError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload
    }

    /// The side that starts game 1, as a `Color` (defaults to `.black` if malformed).
    var startingColor: Color { Color(rawValue: startingPlayer) ?? .black }

    /// The colour a given Game Center player plays, if assigned.
    func color(forPlayerID id: String) -> Color? {
        colorByPlayerID[id].flatMap(Color.init(rawValue:))
    }

    /// Winners of the completed games, in order — the match score.
    var completedGameWinners: [Color] { games.compactMap(\.winner) }

    /// The match score as a `MatchState`.
    var matchState: MatchState {
        MatchState(targetWins: targetWins,
                   baseStartingPlayer: startingColor,
                   gameWinners: completedGameWinners)
    }

    /// 0-based index of the current (in-progress or last) game.
    var currentGameIndex: Int { max(0, games.count - 1) }

    /// The starting player for game `index`, alternating from the game-1 starter.
    func startingPlayer(forGameIndex index: Int) -> Color {
        index % 2 == 0 ? startingColor : startingColor.opponent
    }

    /// A `GameSave` view of one game's plies (human-vs-human, no AI side), so a device
    /// can rebuild that game's session from the authoritative log via `GameSession.resume`.
    func gameSave(forGameIndex index: Int, name: String = "Online match") -> GameSave {
        let plies = games.indices.contains(index) ? games[index].plies : []
        return GameSave(name: name,
                        savedAt: Date(),
                        startingPlayer: startingPlayer(forGameIndex: index).rawValue,
                        aiColor: nil,
                        history: plies)
    }

    /// A `GameSave` view of the current game — the reconnection / first-open path.
    func gameSave(name: String = "Online match") -> GameSave {
        gameSave(forGameIndex: currentGameIndex, name: name)
    }

    /// Ordered `(gameIndex, ply)` updates a device that has applied `plyCount` plies of
    /// game `gameIndex` has not yet seen. Crossing into a later game means the earlier
    /// game finished; this lets a receiver apply the opponent's newest turn even when it
    /// finishes the current game and continues into the next one.
    func pendingPlies(fromGameIndex gameIndex: Int,
                      plyCount: Int) -> [(gameIndex: Int, ply: PlyRecord)] {
        var out: [(gameIndex: Int, ply: PlyRecord)] = []
        guard gameIndex < games.count else { return out }
        for gi in gameIndex..<games.count {
            let plies = games[gi].plies
            let start = (gi == gameIndex) ? max(0, plyCount) : 0
            guard start < plies.count else { continue }
            for ply in plies[start...] { out.append((gameIndex: gi, ply: ply)) }
        }
        return out
    }
}
