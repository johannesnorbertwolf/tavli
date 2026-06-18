import Foundation
import Combine
import UIKit
import TavliEngine

/// The app's single source of truth for the tournament: wraps the pure
/// `Tournament` value type and a `TournamentStore`, publishes changes for the
/// views, and **persists after every mutation**. All edits funnel through
/// `mutate(_:)`, which also **broadcasts** the new state to the multi-iPad sync
/// mesh; incoming peer state is merged in `receive(_:)`.
///
/// ## Sync (≤3 iPads, same WiFi, serverless)
/// Every edit is stamped with this device's id (`deviceID`) and broadcast through
/// a `SyncTransport` (the real radio is `MultipeerTransport`; tests/dev can inject
/// a `LoopbackTransport`). Received state is reconciled with the entity-level
/// last-writer-wins `Tournament.merged(with:)` and re-broadcast only when it
/// actually changed, so the gossip converges and goes quiet. See
/// `Tournament` (engine) for the merge semantics.
@MainActor
final class TournamentModel: ObservableObject {
    @Published private(set) var tournament: Tournament

    /// Display names of the currently-connected peers (for the Setup indicator).
    @Published private(set) var peerNames: [String] = []

    /// In-app AI games saved on this device (newest first), shown in the Setup list.
    /// Local-only — never synced. Refreshed from disk via `reloadSavedGames()` at the
    /// moments it's displayed (Setup appears, a game closes); the per-move autosave
    /// during a game writes straight to `gamesStore` without republishing this.
    @Published private(set) var savedGames: [SavedTournamentGame] = []

    /// Stable per-install id: the last-writer-wins tiebreak and the sync identity.
    let deviceID: UUID

    private let store: TournamentStore
    private let gamesStore: TournamentGameStore
    private let sync: SyncTransport?

    init(store: TournamentStore = .default(),
         gamesStore: TournamentGameStore = .default(),
         sync: SyncTransport? = nil) {
        self.store = store
        self.gamesStore = gamesStore
        self.deviceID = TournamentModel.loadDeviceID()
        if let loaded = store.load() {
            self.tournament = loaded
        } else {
            let fresh = Tournament.makeDefault()   // seeds the AI player (TavTav)
            self.tournament = fresh
            store.save(fresh)
        }

        // Default to the real radio; injectable for tests / a loopback dev build.
        self.sync = sync ?? MultipeerTransport(
            deviceName: "\(UIDevice.current.name) · \(deviceID.uuidString.prefix(4))",
            deviceID: deviceID)
        self.savedGames = gamesStore.list()
        configureSync()
    }

    // ── Sync ───────────────────────────────────────────────────────────────────

    private func configureSync() {
        sync?.onReceive = { [weak self] incoming in
            Task { @MainActor in self?.receive(incoming) }
        }
        sync?.onPeersChanged = { [weak self] names in
            Task { @MainActor in self?.peersChanged(names) }
        }
        sync?.start()
    }

    /// Merge a peer's state in; persist + gossip onward only if it changed anything
    /// (an unchanged merge means the peer echoed what we already knew — stop, so the
    /// network settles instead of looping).
    private func receive(_ incoming: Tournament) {
        let (merged, changed) = tournament.mergingForSync(incoming)
        guard changed else { return }
        tournament = merged
        store.save(merged)
        sync?.broadcast(merged)
    }

    /// A peer connected or dropped. Refresh the indicator and, when someone is
    /// connected, push our current state so a fresh joiner catches up.
    private func peersChanged(_ names: [String]) {
        peerNames = names
        if !names.isEmpty { sync?.broadcast(tournament) }
    }

    // ── Derived reads ────────────────────────────────────────────────────────────

    var players: [TournamentPlayer] { tournament.players }
    var matches: [TournamentMatch] { tournament.matches }
    var standings: [TournamentStanding] { tournament.standings() }
    var finale: Finale? { tournament.finale }
    var champion: TournamentPlayer? { tournament.champion }
    var aiPlayer: TournamentPlayer? { tournament.aiPlayer }
    var hasAI: Bool { tournament.hasAI }
    var isRoundRobinComplete: Bool { tournament.isRoundRobinComplete }
    var openMatchCount: Int { tournament.openMatchCount }

    func player(_ id: UUID?) -> TournamentPlayer? { id.flatMap { tournament.player($0) } }
    func name(_ id: UUID?) -> String { player(id)?.name ?? "—" }

    /// The two participants of a match as resolved player objects (in stored order).
    func participants(of match: TournamentMatch) -> (TournamentPlayer?, TournamentPlayer?) {
        (player(match.a), player(match.b))
    }

    /// The (human, AI) split of a match that involves the AI, or `nil` if it
    /// doesn't (a human-vs-human pairing).
    func humanAndAI(in match: TournamentMatch) -> (human: TournamentPlayer, ai: TournamentPlayer)? {
        let (a, b) = participants(of: match)
        guard let a, let b else { return nil }
        if a.isAI, !b.isAI { return (b, a) }
        if b.isAI, !a.isAI { return (a, b) }
        return nil
    }

    func humanAndAI(in finale: Finale) -> (human: TournamentPlayer, ai: TournamentPlayer)? {
        guard let a = player(finale.a), let b = player(finale.b) else { return nil }
        if a.isAI, !b.isAI { return (b, a) }
        if b.isAI, !a.isAI { return (a, b) }
        return nil
    }

    // ── Mutations (each persists + broadcasts) ─────────────────────────────────────

    private func mutate(_ block: (inout Tournament) -> Void) {
        var t = tournament
        block(&t)
        tournament = t
        store.save(t)
        sync?.broadcast(t)
    }

    func addPlayer(name: String) { mutate { $0.addPlayer(name: name, by: self.deviceID) } }
    func addAIPlayer() { mutate { $0.addAIPlayer(by: self.deviceID) } }
    func renamePlayer(_ id: UUID, to name: String) { mutate { $0.renamePlayer(id, to: name, by: self.deviceID) } }
    func removePlayer(_ id: UUID) { mutate { $0.removePlayer(id, by: self.deviceID) } }

    func setResult(matchID: UUID, winner: UUID?, viaApp: Bool = false) {
        mutate { $0.setResult(matchID: matchID, winner: winner, viaApp: viaApp, by: self.deviceID) }
    }
    func clearResult(matchID: UUID) { mutate { $0.clearResult(matchID: matchID, by: self.deviceID) } }
    func resetResults() { mutate { $0.resetResults(by: self.deviceID) } }

    func startFinale() { mutate { $0.startFinale(by: self.deviceID) } }
    func setFinaleWinner(_ id: UUID?) { mutate { $0.setFinaleWinner(id, by: self.deviceID) } }
    func clearFinale() { mutate { $0.clearFinale(by: self.deviceID) } }

    // ── In-app AI game results ───────────────────────────────────────────────────

    /// Record the outcome of an in-app AI game onto its round-robin match: map the
    /// winning checker color back to the human or the AI and store it.
    func recordAIMatch(matchID: UUID, human: TournamentPlayer, ai: TournamentPlayer,
                       humanColor: Color, winner: Color) {
        let w = Tournament.aiGameWinner(humanID: human.id, aiID: ai.id,
                                        humanColor: humanColor, winner: winner)
        setResult(matchID: matchID, winner: w, viaApp: true)
    }

    /// Record the outcome of an in-app AI finale onto the finale.
    func recordFinaleGame(human: TournamentPlayer, ai: TournamentPlayer,
                          humanColor: Color, winner: Color) {
        let w = Tournament.aiGameWinner(humanID: human.id, aiID: ai.id,
                                        humanColor: humanColor, winner: winner)
        setFinaleWinner(w)
    }

    /// Map a finished saved game's winner back onto the tournament. Works for a
    /// freshly-played *and* a resumed game (it carries its own match/player ids), so
    /// a match interrupted and finished later still counts. Practice games, and games
    /// whose match/players no longer exist, record nothing.
    func recordOutcome(for saved: SavedTournamentGame, winner: Color) {
        guard let human = player(saved.humanPlayerID),
              let ai = player(saved.aiPlayerID) else { return }
        switch saved.kind {
        case .match:
            guard let matchID = saved.matchID,
                  matches.contains(where: { $0.id == matchID }) else { return }
            recordAIMatch(matchID: matchID, human: human, ai: ai,
                          humanColor: saved.humanColor, winner: winner)
        case .finale:
            recordFinaleGame(human: human, ai: ai, humanColor: saved.humanColor, winner: winner)
        case .practice:
            break
        }
    }

    // ── Saved in-app games (local-only, never synced) ──────────────────────────────

    /// Write `game` to its per-game file (every move, on game over, and on the way
    /// out). Does not republish `savedGames` — that's refreshed when the list is next
    /// shown — so the autosave never churns the views behind the live game.
    func persistGame(_ game: SavedTournamentGame) { gamesStore.save(game) }

    func deleteSavedGame(id: UUID) {
        gamesStore.delete(id: id)
        reloadSavedGames()
    }

    /// Re-read the saved games from disk and republish. Called when the Setup list
    /// appears and after a game closes.
    func reloadSavedGames() { savedGames = gamesStore.list() }

    // ── Device identity ──────────────────────────────────────────────────────────

    private static let deviceIDKey = "weltsensation.deviceID"

    /// A stable id for this install, created once and persisted. Used as the sync
    /// identity and the last-writer-wins tiebreak.
    private static func loadDeviceID() -> UUID {
        let defaults = UserDefaults.standard
        if let s = defaults.string(forKey: deviceIDKey), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: deviceIDKey)
        return id
    }
}
