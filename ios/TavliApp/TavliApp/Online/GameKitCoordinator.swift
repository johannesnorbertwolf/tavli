import Foundation
import Combine
import GameKit
import UIKit
import TavliEngine

/// Bridges a Game Center **turn-based** match to a local `GameSession` (#134).
///
/// The engine stays oblivious to the network: an online game is a pure
/// human-vs-human `GameSession` (`aiColor == nil`), and a remote move is fed in via
/// `GameSession.applyRemoteMove` — structurally the AI move the session already
/// knows how to animate, only sourced from the wire. This object owns all the
/// `GameKit` plumbing and is the single place that touches `GKTurnBasedMatch`.
///
/// **State model.** The whole game lives in the match's `matchData` as an
/// `OnlineMatchPayload` (the ply log + colour assignment). Sync, resume, and
/// reconnection are therefore "decode + replay": there is never any board state to
/// reconcile. Each completed local turn is pushed with `endTurn`; each incoming turn
/// event decodes the payload and applies only the plies this device has not seen.
///
/// **Untested by `swift test`.** GameKit needs a signed build, two devices, and
/// sandbox Game Center accounts, so the flows below are verified manually (see the
/// PR checklist). The match-agnostic core they call — `applyRemoteMove`, the codec —
/// is covered headlessly.
@MainActor
final class GameKitCoordinator: NSObject, ObservableObject {

    // ── Published view state ────────────────────────────────────────────────────

    /// Whether the local player is signed in to Game Center.
    @Published private(set) var isAuthenticated = false
    /// A human-readable problem to surface in the lobby (auth/match errors).
    @Published private(set) var authError: String?
    /// The live match's session, or `nil` when in the lobby / between matches.
    @Published private(set) var session: GameSession?
    /// The colour the local player holds in the active match.
    @Published private(set) var localColor: TavliEngine.Color = .white
    /// The opponent's Game Center display name, for the turn indicator.
    @Published private(set) var opponentName: String = String(localized: "Opponent")
    /// A transient status line (e.g. "Waiting for opponent to start…",
    /// "Opponent left the match"). `nil` when there is nothing to say.
    @Published var statusBanner: String?
    /// The player's in-progress / their-turn matches, for the lobby list.
    @Published private(set) var matches: [GKTurnBasedMatch] = []

    // ── Private match state ─────────────────────────────────────────────────────

    /// The active match, or `nil` in the lobby.
    private var match: GKTurnBasedMatch?
    /// Maps each participant's `gamePlayerID` to the colour they play, carried in the
    /// payload so each device computes its own side independent of turn order.
    private var colorByPlayerID: [String: TavliEngine.Color] = [:]
    /// Plies already reflected in the match data (sent or received) — the high-water
    /// mark used to avoid echoing a ply back out and to diff incoming updates.
    private var syncedPlyCount = 0
    /// Observes the session's ply log so a completed *local* turn is pushed to GC.
    private var recordCancellable: AnyCancellable?

    private var localPlayerID: String { GKLocalPlayer.local.gamePlayerID }

    // ── Authentication ──────────────────────────────────────────────────────────

    /// Begin Game Center sign-in. If GC needs to present a sign-in screen we surface
    /// it; on success we register as the turn-event listener so invites and the
    /// opponent's moves flow in. Idempotent — safe to call each time the lobby opens.
    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    self.present(viewController)
                } else if GKLocalPlayer.local.isAuthenticated {
                    self.isAuthenticated = true
                    self.authError = nil
                    GKLocalPlayer.local.unregisterAllListeners()
                    GKLocalPlayer.local.register(self)
                    self.refreshMatches()
                } else {
                    self.isAuthenticated = false
                    self.authError = error?.localizedDescription
                        ?? String(localized: "Sign in to Game Center to play online.")
                }
            }
        }
    }

    // ── Lobby actions ───────────────────────────────────────────────────────────

    /// Present Game Center's matchmaker so the host can invite a friend. The created
    /// match is delivered back through the turn-event listener (`receivedTurnEventFor`),
    /// so there is no completion handler here — `handleMatchUpdate` picks it up.
    func presentInvite() {
        guard isAuthenticated else { authenticate(); return }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        let vc = GKTurnBasedMatchmakerViewController(matchRequest: request)
        vc.turnBasedMatchmakerDelegate = self
        present(vc)
    }

    /// Reload the player's matches for the lobby list (their-turn first by recency).
    func refreshMatches() {
        GKTurnBasedMatch.loadMatches { [weak self] matches, _ in
            Task { @MainActor in self?.matches = matches ?? [] }
        }
    }

    /// Open an existing match (tapped in the lobby list, or resumed on launch).
    func open(_ match: GKTurnBasedMatch) {
        handleMatchUpdate(match)
    }

    /// Leave the active match: forfeit it on Game Center, then return to the lobby.
    func leaveMatch() {
        guard let match else { clearMatch(); return }
        let data = (try? currentPayload()?.encoded()) ?? Data()
        if isLocalTurn(in: match) {
            match.participantQuitInTurn(with: .quit,
                                        nextParticipants: opponents(of: match),
                                        turnTimeout: GKTurnTimeoutDefault,
                                        match: data) { _ in }
        } else {
            match.participantQuitOutOfTurn(with: .quit) { _ in }
        }
        clearMatch()
    }

    private func clearMatch() {
        recordCancellable = nil
        session = nil
        match = nil
        colorByPlayerID = [:]
        syncedPlyCount = 0
        statusBanner = nil
        refreshMatches()
    }

    // ── Incoming: a match was created / updated / became our turn ────────────────

    /// The funnel for every match event. Decodes the payload and either opens the
    /// match fresh (rebuild from the log) or applies the opponent's newest ply(ies);
    /// an as-yet-uninitialised match is set up here by whichever side holds the
    /// opening turn (the creator).
    private func handleMatchUpdate(_ match: GKTurnBasedMatch) {
        guard let data = match.matchData, !data.isEmpty,
              let payload = try? OnlineMatchPayload.decoded(from: data) else {
            // No payload yet: the creator (the player holding the turn) initialises
            // it; the joiner waits for the creator to write the opening state.
            if isLocalTurn(in: match) {
                initializeNewMatch(match)
            } else {
                self.match = match
                self.session = nil
                self.statusBanner = String(localized: "Waiting for opponent to start…")
            }
            return
        }

        let isSameMatch = (self.match?.matchID == match.matchID) && session != nil
        if isSameMatch, let session {
            // Live update to the open match: animate the opponent's new ply(ies).
            let newOnes = payload.newPlies(since: session.record.plies.count)
            for ply in newOnes where !session.applyRemoteMove(ply) {
                // Desync — fall back to an exact rebuild from the authoritative log.
                openFresh(match, payload)
                return
            }
            self.match = match
            syncedPlyCount = payload.plies.count
            statusBanner = nil
        } else {
            openFresh(match, payload)
        }
    }

    /// Rebuild the local session exactly from the authoritative ply log (the
    /// reconnection / first-open path), then start observing local turns.
    private func openFresh(_ match: GKTurnBasedMatch, _ payload: OnlineMatchPayload) {
        colorByPlayerID = payload.colorByPlayerID.compactMapValues(TavliEngine.Color.init(rawValue:))
        localColor = payload.color(forPlayerID: localPlayerID) ?? .white
        opponentName = match.participants
            .first { $0.player?.gamePlayerID != localPlayerID }?
            .player?.displayName ?? String(localized: "Opponent")

        let rebuilt = GameSession.resume(from: payload.gameSave(),
                                         animationTimings: .standard)
        self.match = match
        self.session = rebuilt
        syncedPlyCount = payload.plies.count
        statusBanner = nil
        rebuilt.start()
        observeLocalTurns(of: rebuilt)
    }

    /// First-time setup by the match creator: assign colours (creator = White and
    /// moves first), persist the opening payload so the joiner can read its colour,
    /// and open the local session. Kept deliberately simple for v1 — a randomized
    /// starting player / colour swap is a later refinement.
    private func initializeNewMatch(_ match: GKTurnBasedMatch) {
        let opponentID = match.participants
            .first { $0.player?.gamePlayerID != localPlayerID }?
            .player?.gamePlayerID

        var colors: [String: TavliEngine.Color] = [localPlayerID: .white]
        if let opponentID { colors[opponentID] = .black }

        let payload = OnlineMatchPayload(startingPlayer: .white,
                                         colorByPlayerID: colors,
                                         plies: [])
        guard let data = try? payload.encoded() else { return }
        // Persist the colours WITHOUT ending the turn — we move first.
        match.saveCurrentTurn(withMatch: data) { _ in }
        openFresh(match, payload)
    }

    // ── Outgoing: push a completed local turn ───────────────────────────────────

    /// Watch the session's ply log; when a new ply is a *local* move (or pass), push
    /// it to Game Center. Remote plies (applied via `applyRemoteMove`) are already in
    /// the match data, so they only advance the high-water mark.
    private func observeLocalTurns(of session: GameSession) {
        recordCancellable = session.$record
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleRecordChange() }
    }

    private func handleRecordChange() {
        guard let session else { return }
        let count = session.record.plies.count
        guard count > syncedPlyCount else { return }
        // The mover alternates every ply, starting from `startingPlayer`.
        let mover = (count - 1) % 2 == 0 ? session.startingPlayer
                                         : session.startingPlayer.opponent
        syncedPlyCount = count
        if mover == localColor { pushLocalTurn() }
    }

    /// Send the current ply log to Game Center, ending our turn (or the match, when
    /// the local move just won).
    private func pushLocalTurn() {
        guard let session, let match, let data = try? currentPayload()?.encoded() else { return }

        if session.isTerminal, let winner = session.record.outcome {
            for participant in match.participants {
                let isLocal = participant.player?.gamePlayerID == localPlayerID
                let localWon = winner == localColor
                participant.matchOutcome = (isLocal == localWon) ? .won : .lost
            }
            match.endMatchInTurn(withMatch: data) { [weak self] error in
                Task { @MainActor in self?.reportIfError(error) }
            }
        } else {
            match.endTurn(withNextParticipants: opponents(of: match),
                          turnTimeout: GKTurnTimeoutDefault,
                          match: data) { [weak self] error in
                Task { @MainActor in self?.reportIfError(error) }
            }
        }
    }

    private func currentPayload() -> OnlineMatchPayload? {
        guard let session else { return nil }
        return OnlineMatchPayload(startingPlayer: session.startingPlayer,
                                  colorByPlayerID: colorByPlayerID,
                                  plies: session.record.plies)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    private func opponents(of match: GKTurnBasedMatch) -> [GKTurnBasedParticipant] {
        match.participants.filter { $0.player?.gamePlayerID != localPlayerID }
    }

    private func isLocalTurn(in match: GKTurnBasedMatch) -> Bool {
        match.currentParticipant?.player?.gamePlayerID == localPlayerID
    }

    private func reportIfError(_ error: Error?) {
        if let error { statusBanner = error.localizedDescription }
    }

    /// Present a UIKit view controller (auth or matchmaker) from the top-most
    /// controller — SwiftUI has no first-class GameKit presentation.
    private func present(_ vc: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }
}

// ── Turn-based event listener ───────────────────────────────────────────────────

// GameKit invokes these callbacks off the main thread, so they are `nonisolated`
// and hop onto the main actor to touch the coordinator's state.
extension GameKitCoordinator: GKLocalPlayerListener {
    /// The opponent took a turn, accepted our invite, or we launched from a turn
    /// notification — open or advance the match.
    nonisolated func player(_ player: GKPlayer,
                            receivedTurnEventFor match: GKTurnBasedMatch,
                            didBecomeActive: Bool) {
        Task { @MainActor in
            self.handleMatchUpdate(match)
            self.refreshMatches()
        }
    }

    /// The match ended (a win, or the opponent forfeited).
    nonisolated func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        Task { @MainActor in
            if self.match?.matchID == match.matchID {
                self.statusBanner = String(localized: "Match ended.")
            }
            self.refreshMatches()
        }
    }

    /// The opponent asked to quit; record their forfeit and let the local player win.
    nonisolated func player(_ player: GKPlayer, wantsToQuitMatch match: GKTurnBasedMatch) {
        Task { @MainActor in
            if self.match?.matchID == match.matchID {
                self.statusBanner = String(localized: "Opponent left the match.")
            }
        }
    }
}

// ── Matchmaker delegate ─────────────────────────────────────────────────────────

extension GameKitCoordinator: GKTurnBasedMatchmakerViewControllerDelegate {
    nonisolated func turnBasedMatchmakerViewControllerWasCancelled(_ viewController: GKTurnBasedMatchmakerViewController) {
        Task { @MainActor in viewController.dismiss(animated: true) }
    }

    nonisolated func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController,
                                                       didFailWithError error: Error) {
        Task { @MainActor in
            viewController.dismiss(animated: true)
            self.statusBanner = error.localizedDescription
        }
    }
}
