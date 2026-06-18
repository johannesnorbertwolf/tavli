import Foundation

/// Round-robin tournament model for the **Weltsensation** super-app (throwaway
/// tournament branch). Pure, `Codable` value types plus the standings / pairing
/// logic — SwiftUI-free, so `swift test` covers it. The app wraps this in a
/// `TournamentModel` (`ObservableObject`) and a `TournamentStore` (file IO).
///
/// The AI ("TavTav") is a **regular ranked player** (`isAI`): matches against it
/// are played in-app and recorded automatically; human-vs-human matches are
/// entered by hand. Both are just a `winner` on a `TournamentMatch`, so every
/// result is freely overwritable.
///
/// ## Multi-iPad sync (≤3 devices, same WiFi, serverless)
/// Every mutating method takes an optional `by device:` and stamps the entity it
/// touches with a `Stamp` (a Lamport-style counter + device tiebreak). Two
/// tournaments are reconciled with `merged(with:)`, an **entity-level
/// last-writer-wins merge**: concurrent edits to *different* matches both survive;
/// concurrent edits to the *same* entity resolve deterministically by stamp. The
/// default roster uses **fixed seed IDs** so every freshly-launched device starts
/// from an identical base and merging two pristine devices is a no-op. The app's
/// `TournamentModel` broadcasts the whole `Tournament` (it's tiny) through a
/// `SyncTransport` after every change and merges whatever it receives.

// ── Sync stamp ──────────────────────────────────────────────────────────────────

/// A logical timestamp for last-writer-wins merges. `counter` is a Lamport clock
/// (each device advances it past the highest counter it has seen, so a later edit
/// always outranks an earlier one across devices); `device` is the per-iPad id used
/// only to break exact-counter ties deterministically. Ordering: counter, then
/// device-uuid string — total and identical on every peer.
public struct Stamp: Codable, Hashable, Sendable, Comparable {
    public var counter: UInt64
    public var device: UUID

    public init(counter: UInt64, device: UUID) {
        self.counter = counter
        self.device = device
    }

    /// The base stamp carried by never-edited (seed / reconcile-created) entities.
    /// Any real edit produces a counter ≥ 1, so it always outranks `.zero`.
    public static let zero = Stamp(counter: 0,
                                   device: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))

    public static func < (lhs: Stamp, rhs: Stamp) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.device.uuidString < rhs.device.uuidString
    }
}

// ── Value types ───────────────────────────────────────────────────────────────

/// One tournament participant. `isAI` marks the single Core ML opponent (TavTav);
/// it is otherwise an ordinary player and can be renamed or removed like any other.
/// `stamp` is the sync clock for this record (bumped on add / rename).
public struct TournamentPlayer: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var isAI: Bool
    public var stamp: Stamp

    public init(id: UUID = UUID(), name: String, isAI: Bool = false, stamp: Stamp = .zero) {
        self.id = id
        self.name = name
        self.isAI = isAI
        self.stamp = stamp
    }
}

/// One round-robin pairing. `winner` is `nil` until played; setting it back to
/// `nil` clears the result. `viaApp` records whether an AI game produced it
/// (vs. a hand-entered result) — purely informational. `stamp` is the sync clock
/// for the *result* (bumped on set / clear); `.zero` means "never touched", so a
/// real result always outranks a freshly-reconciled empty match on merge.
public struct TournamentMatch: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var a: UUID
    public var b: UUID
    public var winner: UUID?
    public var playedAt: Date?
    public var viaApp: Bool
    public var stamp: Stamp

    public init(id: UUID = UUID(),
                a: UUID,
                b: UUID,
                winner: UUID? = nil,
                playedAt: Date? = nil,
                viaApp: Bool = false,
                stamp: Stamp = .zero) {
        self.id = id
        self.a = a
        self.b = b
        self.winner = winner
        self.playedAt = playedAt
        self.viaApp = viaApp
        self.stamp = stamp
    }

    public var isPlayed: Bool { winner != nil }

    public func contains(_ playerID: UUID) -> Bool { a == playerID || b == playerID }

    /// The other player in this pairing, or `nil` if `playerID` isn't in it.
    public func opponent(of playerID: UUID) -> UUID? {
        if a == playerID { return b }
        if b == playerID { return a }
        return nil
    }

    /// Cross-device identity: the unordered player pair (the per-device `id` is not
    /// stable, so matches are reconciled by who's playing, not by their id).
    var pairKey: [String] { [a.uuidString, b.uuidString].sorted() }
}

/// The head-to-head finale between the two strongest players. Snapshotted from
/// the standings once the round robin is complete, so a late edit to the table
/// doesn't silently swap finalists. The whole finale is one LWW register on the
/// tournament's `finaleStamp`.
public struct Finale: Codable, Hashable, Sendable {
    public var a: UUID
    public var b: UUID
    public var winner: UUID?

    public init(a: UUID, b: UUID, winner: UUID? = nil) {
        self.a = a
        self.b = b
        self.winner = winner
    }

    public func contains(_ id: UUID) -> Bool { a == id || b == id }

    public func opponent(of id: UUID) -> UUID? {
        if a == id { return b }
        if b == id { return a }
        return nil
    }
}

/// One row of the computed standings table.
public struct TournamentStanding: Identifiable, Hashable, Sendable {
    public let player: TournamentPlayer
    public let rank: Int
    public let played: Int
    public let wins: Int
    public let losses: Int

    public var id: UUID { player.id }

    public init(player: TournamentPlayer, rank: Int, played: Int, wins: Int, losses: Int) {
        self.player = player
        self.rank = rank
        self.played = played
        self.wins = wins
        self.losses = losses
    }
}

// ── Aggregate ─────────────────────────────────────────────────────────────────

/// The whole tournament: players, the reconciled round-robin match set, and the
/// optional finale. The single source of truth — every mutation funnels through
/// the methods here (the app's `TournamentModel` just forwards + persists), which
/// is also where multi-iPad sync hooks in (`merged(with:)`).
public struct Tournament: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var players: [TournamentPlayer]
    public var matches: [TournamentMatch]
    public var finale: Finale?

    /// Tombstones for removed players (LWW-element-set): a player is present iff its
    /// active `stamp` outranks its removal stamp here. Kept so a removal isn't
    /// resurrected by a stale peer that still has the player.
    public var removedPlayers: [UUID: Stamp]

    /// LWW clock for the finale register (advances on start / set-winner / clear),
    /// so "the finale was cleared" can win over a stale "finale exists".
    public var finaleStamp: Stamp

    /// Bumped to 2 when sync stamps/tombstones were added (a v1 file reads as `nil`
    /// and the app falls back to a fresh default — fine on this throwaway branch).
    public static let currentSchemaVersion = 2

    /// Device id used when a mutation is made without an explicit `by:` (single-
    /// device callers and tests). Real devices pass their persisted id.
    public static let defaultDevice = Stamp.zero.device

    public init(players: [TournamentPlayer] = [],
                matches: [TournamentMatch] = [],
                finale: Finale? = nil,
                removedPlayers: [UUID: Stamp] = [:],
                finaleStamp: Stamp = .zero,
                schemaVersion: Int = Tournament.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.players = players
        self.matches = matches
        self.finale = finale
        self.removedPlayers = removedPlayers
        self.finaleStamp = finaleStamp
    }

    /// The default roster with **fixed ids**. Every device seeds these identical
    /// ids, so two freshly-launched iPads start from the same base and merging them
    /// is a no-op; only later add/rename/remove edits (carrying real stamps) move
    /// state between devices. Throwaway branch — these are the actual guests; edit
    /// freely in Setup.
    public static let seedRoster: [(name: String, id: UUID, isAI: Bool)] = [
        ("Norbert",  UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, false),
        ("Gisela",   UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, false),
        ("Johannes", UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, false),
        ("Theo",     UUID(uuidString: "00000000-0000-4000-8000-000000000004")!, false),
        ("Janne",    UUID(uuidString: "00000000-0000-4000-8000-000000000005")!, false),
        ("Albert",   UUID(uuidString: "00000000-0000-4000-8000-000000000006")!, false),
        ("Caspar",   UUID(uuidString: "00000000-0000-4000-8000-000000000007")!, false),
        ("Frida",    UUID(uuidString: "00000000-0000-4000-8000-000000000008")!, false),
        ("TavTav",   UUID(uuidString: "00000000-0000-4000-8000-000000000009")!, true),
    ]

    /// Fixed id for the AI player, reused by `addAIPlayer` so re-adding TavTav
    /// merges with other devices' TavTav rather than forking a new identity.
    public static let seedAIPlayerID = seedRoster.first { $0.isAI }!.id

    /// The human seed names (used by tests / display).
    public static var defaultPlayerNames: [String] {
        seedRoster.filter { !$0.isAI }.map(\.name)
    }

    /// A fresh tournament seeded with the default group (the eight guests) plus the
    /// AI player (TavTav), all on their fixed seed ids. Used on first launch.
    public static func makeDefault() -> Tournament {
        let players = seedRoster.map { TournamentPlayer(id: $0.id, name: $0.name, isAI: $0.isAI) }
        var t = Tournament(players: players)
        t.reconcileMatches()
        return t
    }

    // ── Sync clock ──────────────────────────────────────────────────────────────

    /// The highest stamp counter anywhere in the document (players, tombstones,
    /// matches, finale). The next local edit uses `counter + 1`, so it outranks
    /// everything currently known — the Lamport advance.
    public var maxStampCounter: UInt64 {
        var m: UInt64 = 0
        for p in players { m = max(m, p.stamp.counter) }
        for s in removedPlayers.values { m = max(m, s.counter) }
        for mt in matches { m = max(m, mt.stamp.counter) }
        m = max(m, finaleStamp.counter)
        return m
    }

    /// The stamp a fresh edit by `device` should carry.
    public func nextStamp(by device: UUID) -> Stamp {
        Stamp(counter: maxStampCounter + 1, device: device)
    }

    // ── Lookups ───────────────────────────────────────────────────────────────

    public func player(_ id: UUID) -> TournamentPlayer? { players.first { $0.id == id } }

    public func name(_ id: UUID?) -> String? { id.flatMap { player($0)?.name } }

    public var aiPlayer: TournamentPlayer? { players.first(where: \.isAI) }

    public var hasAI: Bool { players.contains(where: \.isAI) }

    public func match(_ id: UUID) -> TournamentMatch? { matches.first { $0.id == id } }

    // ── Player edits (each reconciles the match set) ────────────────────────────

    /// Add a player (ignoring blank names) and regenerate the missing pairings.
    @discardableResult
    public mutating func addPlayer(name: String,
                                   isAI: Bool = false,
                                   by device: UUID = Tournament.defaultDevice) -> TournamentPlayer? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let player = TournamentPlayer(name: trimmed, isAI: isAI, stamp: nextStamp(by: device))
        players.append(player)
        removedPlayers[player.id] = nil
        reconcileMatches()
        return player
    }

    /// Re-add the AI player (TavTav) if it was removed, reusing the fixed seed id so
    /// it reunites with other devices' TavTav. No-op when one exists.
    @discardableResult
    public mutating func addAIPlayer(name: String = "TavTav",
                                     by device: UUID = Tournament.defaultDevice) -> TournamentPlayer? {
        guard !hasAI else { return nil }
        let player = TournamentPlayer(id: Tournament.seedAIPlayerID, name: name,
                                      isAI: true, stamp: nextStamp(by: device))
        players.append(player)
        removedPlayers[player.id] = nil
        reconcileMatches()
        return player
    }

    public mutating func renamePlayer(_ id: UUID, to name: String,
                                      by device: UUID = Tournament.defaultDevice) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = players.firstIndex(where: { $0.id == id }) else { return }
        players[idx].name = trimmed
        players[idx].stamp = nextStamp(by: device)
    }

    /// Remove a player (any player, including the AI) and drop their matches. Leaves
    /// a tombstone so the removal survives merges with peers that still have them.
    public mutating func removePlayer(_ id: UUID,
                                      by device: UUID = Tournament.defaultDevice) {
        guard players.contains(where: { $0.id == id }) else { return }
        removedPlayers[id] = nextStamp(by: device)
        players.removeAll { $0.id == id }
        reconcileMatches()
    }

    // ── Round-robin reconciliation ──────────────────────────────────────────────

    /// Bring the match set in line with the current players: drop matches that
    /// reference a removed player, add a match for every still-missing pairing
    /// (a freshly-created pairing carries `.zero` — never-touched — so a real result
    /// always beats it on merge), and **keep every existing match (id + result)
    /// intact** — so adding or removing players never loses already-entered results.
    /// A finale that references a missing player is discarded.
    public mutating func reconcileMatches() {
        let ids = Set(players.map(\.id))

        matches.removeAll { !ids.contains($0.a) || !ids.contains($0.b) || $0.a == $0.b }

        var existing = Set<Set<UUID>>()
        for m in matches { existing.insert([m.a, m.b]) }

        for i in players.indices {
            for j in (i + 1)..<players.count {
                let key: Set<UUID> = [players[i].id, players[j].id]
                guard !existing.contains(key) else { continue }
                matches.append(TournamentMatch(a: players[i].id, b: players[j].id))
                existing.insert(key)
            }
        }

        if let f = finale, !ids.contains(f.a) || !ids.contains(f.b) {
            finale = nil
        }
    }

    // ── Results ─────────────────────────────────────────────────────────────────

    /// Set (or clear, with `winner == nil`) a match result. Ignores a winner that
    /// isn't one of the two participants. Always overwritable. Bumps the match's
    /// sync stamp so the latest set/clear wins on merge.
    public mutating func setResult(matchID: UUID, winner: UUID?, viaApp: Bool = false,
                                   by device: UUID = Tournament.defaultDevice) {
        guard let idx = matches.firstIndex(where: { $0.id == matchID }) else { return }
        if let w = winner, !matches[idx].contains(w) { return }
        matches[idx].winner = winner
        matches[idx].playedAt = winner == nil ? nil : Date()
        matches[idx].viaApp = winner == nil ? false : viaApp
        matches[idx].stamp = nextStamp(by: device)
    }

    public mutating func clearResult(matchID: UUID, by device: UUID = Tournament.defaultDevice) {
        setResult(matchID: matchID, winner: nil, by: device)
    }

    /// Clear every result (round robin + finale), keeping the players.
    public mutating func resetResults(by device: UUID = Tournament.defaultDevice) {
        let s = nextStamp(by: device)
        for i in matches.indices {
            matches[i].winner = nil
            matches[i].playedAt = nil
            matches[i].viaApp = false
            matches[i].stamp = s
        }
        finale = nil
        finaleStamp = s
    }

    // ── Standings ────────────────────────────────────────────────────────────────

    public func wins(for id: UUID) -> Int {
        matches.reduce(0) { $0 + ($1.winner == id ? 1 : 0) }
    }

    public func played(for id: UUID) -> Int {
        matches.reduce(0) { $0 + ($1.isPlayed && $1.contains(id) ? 1 : 0) }
    }

    public func losses(for id: UUID) -> Int {
        matches.reduce(0) { $0 + ($1.isPlayed && $1.contains(id) && $1.winner != id ? 1 : 0) }
    }

    /// Wins inside the sub-round-robin among everyone sharing `id`'s overall win
    /// total: count only matches `id` won where **both** participants are tied on
    /// wins. `0` when `id` has no one to be tied with.
    private func subTableWins(_ id: UUID, overall: [UUID: Int]) -> Int {
        guard let w = overall[id] else { return 0 }
        let tied = Set(players.filter { overall[$0.id] == w }.map(\.id))
        guard tied.count > 1 else { return 0 }
        return matches.reduce(0) { acc, m in
            (m.winner == id && tied.contains(m.a) && tied.contains(m.b)) ? acc + 1 : acc
        }
    }

    /// Ranked table. Primary order is total wins (descending). Players tied on wins
    /// are then separated by a **sub-table** — a mini round-robin counting only the
    /// games among those tied players (more sub-table wins ranks higher). Players
    /// still level after that **share the same rank** (standard competition ranking:
    /// the next distinct group resumes at its positional index, so a shared rank
    /// skips the positions it occupies). Name (ascending) is only a stable display
    /// order within a shared rank — it never splits the rank itself.
    public func standings() -> [TournamentStanding] {
        let overall = Dictionary(uniqueKeysWithValues: players.map { ($0.id, wins(for: $0.id)) })
        let sub = Dictionary(uniqueKeysWithValues:
            players.map { ($0.id, subTableWins($0.id, overall: overall)) })

        let ordered = players.sorted { lhs, rhs in
            let lw = overall[lhs.id]!, rw = overall[rhs.id]!
            if lw != rw { return lw > rw }
            let ls = sub[lhs.id]!, rs = sub[rhs.id]!
            if ls != rs { return ls > rs }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        var rank = 0
        return ordered.enumerated().map { idx, p in
            let tiedWithPrev = idx > 0
                && overall[p.id]! == overall[ordered[idx - 1].id]!
                && sub[p.id]! == sub[ordered[idx - 1].id]!
            if !tiedWithPrev { rank = idx + 1 }   // standard competition ranking
            return TournamentStanding(player: p,
                                      rank: rank,
                                      played: played(for: p.id),
                                      wins: wins(for: p.id),
                                      losses: losses(for: p.id))
        }
    }

    // ── Finale ────────────────────────────────────────────────────────────────────

    public var openMatchCount: Int { matches.reduce(0) { $0 + ($1.isPlayed ? 0 : 1) } }

    /// True once every round-robin pairing has a result (and there's a real table).
    public var isRoundRobinComplete: Bool {
        players.count >= 2 && !matches.isEmpty && openMatchCount == 0
    }

    /// The two strongest players (standings rank 1 & 2), if there are at least two.
    public func topTwo() -> (TournamentPlayer, TournamentPlayer)? {
        let s = standings()
        guard s.count >= 2 else { return nil }
        return (s[0].player, s[1].player)
    }

    /// Snapshot the current top two into the finale. No-op unless the round robin
    /// is complete and there are two finalists. Idempotent re-snapshot allowed.
    @discardableResult
    public mutating func startFinale(by device: UUID = Tournament.defaultDevice) -> Bool {
        guard isRoundRobinComplete, let (a, b) = topTwo() else { return false }
        finale = Finale(a: a.id, b: b.id)
        finaleStamp = nextStamp(by: device)
        return true
    }

    public mutating func setFinaleWinner(_ id: UUID?, by device: UUID = Tournament.defaultDevice) {
        guard var f = finale else { return }
        if let id, !f.contains(id) { return }
        f.winner = id
        finale = f
        finaleStamp = nextStamp(by: device)
    }

    public mutating func clearFinale(by device: UUID = Tournament.defaultDevice) {
        finale = nil
        finaleStamp = nextStamp(by: device)
    }

    /// The tournament champion (finale winner), once decided.
    public var champion: TournamentPlayer? {
        finale?.winner.flatMap { player($0) }
    }

    // ── AI game result mapping ─────────────────────────────────────────────────────

    /// Map an in-app AI game outcome to the winning player id: the human wins the
    /// match iff the game's winning color is the color the human played.
    public static func aiGameWinner(humanID: UUID,
                                    aiID: UUID,
                                    humanColor: Color,
                                    winner: Color) -> UUID {
        winner == humanColor ? humanID : aiID
    }

    // ── Sync merge (entity-level last-writer-wins) ──────────────────────────────────

    /// Merge another device's tournament into this one, field by field, keeping the
    /// newest stamp for each entity. Pure, **commutative, associative and
    /// idempotent**: every peer that sees the same set of edits converges on the same
    /// result regardless of order. Concurrent edits to *different* matches both
    /// survive; concurrent edits to the *same* entity resolve by stamp (counter, then
    /// device) — deterministically and identically on all peers.
    public func merged(with other: Tournament) -> Tournament {
        // 1. Players — LWW-element-set: present iff the newest add/rename outranks the
        //    newest removal; the surviving record is the higher-stamped one.
        let ids = Set(players.map(\.id))
            .union(other.players.map(\.id))
            .union(removedPlayers.keys)
            .union(other.removedPlayers.keys)

        var activeByID: [UUID: TournamentPlayer] = [:]
        var tombstones: [UUID: Stamp] = [:]
        for id in ids {
            let adds = [players.first { $0.id == id }, other.players.first { $0.id == id }]
                .compactMap { $0 }
            let bestAdd = adds.max { $0.stamp < $1.stamp }
            let bestRemove = [removedPlayers[id], other.removedPlayers[id]].compactMap { $0 }.max()

            if let add = bestAdd, bestRemove == nil || add.stamp > bestRemove! {
                activeByID[id] = add
            } else if let rem = bestRemove {
                tombstones[id] = rem
            }
        }
        let activeIDs = Set(activeByID.keys)

        // 2. Matches — keyed by player pair (the per-device id isn't stable). Among
        //    pairs of still-active players, keep the higher-stamped result; when both
        //    sides have the pair, keep the local id for UI stability and adopt the
        //    remote result only if its stamp wins.
        func byPair(_ list: [TournamentMatch]) -> [[String]: TournamentMatch] {
            var d: [[String]: TournamentMatch] = [:]
            for m in list where activeIDs.contains(m.a) && activeIDs.contains(m.b) {
                d[m.pairKey] = m
            }
            return d
        }
        let localByPair = byPair(matches)
        let remoteByPair = byPair(other.matches)

        var mergedMatches: [TournamentMatch] = []
        for key in Set(localByPair.keys).union(remoteByPair.keys) {
            switch (localByPair[key], remoteByPair[key]) {
            case let (l?, r?):
                if r.stamp > l.stamp {
                    var m = l
                    m.winner = r.winner; m.playedAt = r.playedAt; m.viaApp = r.viaApp; m.stamp = r.stamp
                    mergedMatches.append(m)
                } else {
                    mergedMatches.append(l)
                }
            case let (l?, nil):  mergedMatches.append(l)
            case let (nil, r?):  mergedMatches.append(r)
            case (nil, nil):     break
            }
        }

        // 3. Finale — one LWW register on `finaleStamp`.
        let (finaleVal, finaleStmp) = finaleStamp >= other.finaleStamp
            ? (finale, finaleStamp)
            : (other.finale, other.finaleStamp)

        var result = Tournament(
            players: activeByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            matches: mergedMatches,
            finale: finaleVal,
            removedPlayers: tombstones,
            finaleStamp: finaleStmp,
            schemaVersion: Tournament.currentSchemaVersion)
        result.reconcileMatches()   // add genuinely-missing pairings; validate the finale
        return result
    }

    /// Sync helper: merge `incoming` and report whether anything changed. The app's
    /// model rebroadcasts only when `changed` is true, so an unchanged merge (a peer
    /// echoing what we already know) doesn't trigger a broadcast storm — the gossip
    /// converges and goes quiet.
    public func mergingForSync(_ incoming: Tournament) -> (result: Tournament, changed: Bool) {
        let m = merged(with: incoming)
        return (m, m != self)
    }

    /// Content equality, **order-insensitive** (players / matches are compared as
    /// sets/maps, not arrays). This is the notion sync needs: `x.merged(x) == x`
    /// (idempotent), and a re-merge that only reordered the arrays counts as *no*
    /// change — so the gossip settles instead of churning on array order.
    public static func == (lhs: Tournament, rhs: Tournament) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.finale == rhs.finale
            && lhs.finaleStamp == rhs.finaleStamp
            && lhs.removedPlayers == rhs.removedPlayers
            && Set(lhs.players) == Set(rhs.players)
            && Dictionary(uniqueKeysWithValues: lhs.matches.map { ($0.id, $0) })
             == Dictionary(uniqueKeysWithValues: rhs.matches.map { ($0.id, $0) })
    }
}
