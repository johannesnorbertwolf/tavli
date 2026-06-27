import Foundation

/// Errors decoding an online match payload.
public enum OnlineMatchError: Error, Equatable {
    /// The payload was written by a newer build than this one understands.
    case unsupportedSchemaVersion(Int)
}

/// The wire payload stored in a Game Center turn-based match's `matchData` (#134).
///
/// The authoritative state of an online game is simply its **ply log** — replaying
/// `plies` from the initial position reproduces the exact board, model-independent,
/// exactly as a `GameSave` does (`GameSession.replay`). Game Center persists, syncs,
/// and reloads this blob, so sync, resume, and reconnection all reduce to
/// "decode + replay": there is no board state to reconcile.
///
/// Colour assignment is carried explicitly (`colorByPlayerID`) rather than inferred
/// from turn order, so each device computes its own side from its Game Center
/// `gamePlayerID` no matter who created the match or who is currently active.
public struct OnlineMatchPayload: Codable, Equatable, Sendable {
    /// Bump when the wire shape changes; decoding rejects anything newer than this.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Raw `Color` value ("W"/"B") of the side that moves first, resolved once by the
    /// match creator's opening roll. Stored raw to match `GameSave`'s wire convention.
    public var startingPlayer: String
    /// Maps each participant's Game Center `gamePlayerID` to the raw `Color` value
    /// ("W"/"B") they play.
    public var colorByPlayerID: [String: String]
    /// The ordered plies played so far — the entire game state.
    public var plies: [PlyRecord]

    public init(schemaVersion: Int = OnlineMatchPayload.currentSchemaVersion,
                startingPlayer: Color,
                colorByPlayerID: [String: Color],
                plies: [PlyRecord] = []) {
        self.schemaVersion = schemaVersion
        self.startingPlayer = startingPlayer.rawValue
        self.colorByPlayerID = colorByPlayerID.mapValues(\.rawValue)
        self.plies = plies
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

    /// The plies a device with `localCount` already-applied plies has not yet seen
    /// (used to apply only the opponent's newest turn during live play).
    func newPlies(since localCount: Int) -> ArraySlice<PlyRecord> {
        guard localCount < plies.count else { return [] }
        return plies[localCount...]
    }

    /// The side that moves first, as a `Color` (defaults to `.black` if malformed).
    var startingColor: Color { Color(rawValue: startingPlayer) ?? .black }

    /// The colour a given Game Center player plays, if assigned.
    func color(forPlayerID id: String) -> Color? {
        colorByPlayerID[id].flatMap(Color.init(rawValue:))
    }

    /// A `GameSave` view of this payload (human-vs-human, no AI side), so a device
    /// can rebuild a session from the authoritative log via `GameSession.resume` —
    /// the catch-up / reconnection path.
    func gameSave(name: String = "Online match") -> GameSave {
        GameSave(name: name,
                 savedAt: Date(),
                 startingPlayer: startingPlayer,
                 aiColor: nil,
                 history: plies)
    }
}
