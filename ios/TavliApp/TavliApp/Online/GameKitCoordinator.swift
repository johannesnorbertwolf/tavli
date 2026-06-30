import Foundation
import Combine
import GameKit
import UIKit
import TavliEngine

/// Bridges a Game Center **turn-based** match to a local `GameSession` (#134), and
/// sequences the games of a best-of-three match within that one Game Center match (#145).
///
/// The engine stays oblivious to the network: each game is a pure human-vs-human
/// `GameSession` (`aiColor == nil`), and a remote move is fed in via
/// `GameSession.applyRemoteMove` — structurally the AI move the session already knows
/// how to animate, only sourced from the wire. This object owns all the `GameKit`
/// plumbing and is the single place that touches `GKTurnBasedMatch`.
///
/// **State model.** The whole match lives in the match's `matchData` as an
/// `OnlineMatchPayload`: the list of each game's ply log plus that game's winner.
/// Sync, resume, and reconnection are therefore "decode + replay": there is never any
/// board state to reconcile. Each completed local turn is pushed with `endTurn`; each
/// incoming turn event decodes the payload and applies whatever this device has not yet
/// seen — which may finish the current game and continue into the next.
///
/// **Match flow.** When a game ends, its winner is appended to the score. If the match
/// is decided the Game Center match ends; otherwise a fresh game is started locally
/// (the starter alternates, so no opening-roll ceremony) and the turn is handed to that
/// starter. A `pendingGameResult` drives the between-games overlay while the session has
/// already advanced behind it.
///
/// **Untested by `swift test`.** GameKit needs a signed build, two devices, and sandbox
/// Game Center accounts, so the flows below are verified manually (see the PR checklist).
/// The match-agnostic core they call — `applyRemoteMove`, the codec, `MatchState`, the
/// payload diff — is covered headlessly.
@MainActor
final class GameKitCoordinator: NSObject, ObservableObject {

    // ── Published view state ────────────────────────────────────────────────────

    /// Whether the local player is signed in to Game Center.
    @Published private(set) var isAuthenticated = false
    /// A human-readable problem to surface in the lobby (auth/match errors).
    @Published private(set) var authError: String?
    /// The current game's session, or `nil` when in the lobby / between matches.
    @Published private(set) var session: GameSession?
    /// The colour the local player holds in the active match.
    @Published private(set) var localColor: TavliEngine.Color = .white
    /// The opponent's Game Center display name, for the turn indicator / scoreboard.
    @Published private(set) var opponentName: String = String(localized: "Opponent")
    /// A transient status line (e.g. "Waiting for opponent to start…",
    /// "Opponent left the match"). `nil` when there is nothing to say.
    @Published var statusBanner: String?
    /// The player's in-progress / their-turn matches, for the lobby list.
    @Published private(set) var matches: [GKTurnBasedMatch] = []
    /// The running best-of-three score (#145).
    @Published private(set) var matchState = MatchState.single(baseStartingPlayer: .white)
    /// Set to the just-finished game's winner while the between-games / match-over
    /// overlay should show; the session has already advanced to the next game behind it.
    /// Cleared when the player taps "Next game". `nil` during normal play.
    @Published var pendingGameResult: TavliEngine.Color?

    // ── Private match state ─────────────────────────────────────────────────────

    /// The active match, or `nil` in the lobby.
    private var match: GKTurnBasedMatch?
    /// Maps each participant's `gamePlayerID` to the colour they play, carried in the
    /// payload so each device computes its own side independent of turn order.
    private var colorByPlayerID: [String: TavliEngine.Color] = [:]
    /// Full ply logs + winners for the match's finished games, in order — the history
    /// re-sent in every payload so reconnection stays exact.
    private var completedGameLogs: [GameLog] = []
    /// 0-based index of the current game (the one `session` is playing).
    private var syncedGameIndex = 0
    /// Plies of the current game already reflected locally (sent or received) — the
    /// high-water mark used to avoid echoing a ply back out and to diff incoming updates.
    private var syncedPlyCount = 0
    /// The match length chosen in the lobby for a match this device creates.
    private var pendingMatchTargetWins = MatchLengthSetting.bestOfThree.targetWins
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
    /// so there is no completion handler here — `handleMatchUpdate` picks it up. The
    /// chosen match length (#145) is remembered for when we initialise the new match.
    func presentInvite(targetWins: Int) {
        pendingMatchTargetWins = max(1, targetWins)
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

    /// Advance from the between-games overlay to the next game (#145). The session has
    /// already advanced; this just dismisses the overlay.
    func continueToNextGame() {
        pendingGameResult = nil
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
        completedGameLogs = []
        syncedGameIndex = 0
        syncedPlyCount = 0
        matchState = .single(baseStartingPlayer: .white)
        pendingGameResult = nil
        statusBanner = nil
        refreshMatches()
    }

    // ── Incoming: a match was created / updated / became our turn ────────────────

    /// The funnel for every match event. Decodes the payload and either opens the
    /// match fresh (rebuild from the log) or applies the opponent's newest update; an
    /// as-yet-uninitialised match is set up here by whichever side holds the opening
    /// turn (the creator).
    private func handleMatchUpdate(_ match: GKTurnBasedMatch) {
        guard let data = match.matchData, !data.isEmpty,
              let payload = try? OnlineMatchPayload.decoded(from: data) else {
            // No payload yet: the creator (the player holding the turn) initialises
            // it; the joiner waits for the creator to write the opening state.
            if isLocalTurn(in: match) {
                initializeNewMatch(match, targetWins: pendingMatchTargetWins)
            } else {
                self.match = match
                self.session = nil
                self.statusBanner = String(localized: "Waiting for opponent to start…")
            }
            return
        }

        let isSameMatch = (self.match?.matchID == match.matchID) && session != nil
        if isSameMatch {
            applyIncoming(payload, for: match)
        } else {
            openFresh(match, payload)
        }
    }

    /// Apply everything in `payload` this device has not yet seen, game by game. A
    /// finished current game (with the match still going) advances to the next game and
    /// raises the between-games result; a decided match raises the match-over result.
    /// Any inconsistency falls back to an exact rebuild from the authoritative log.
    private func applyIncoming(_ payload: OnlineMatchPayload, for match: GKTurnBasedMatch) {
        self.match = match
        matchState = payload.matchState
        completedGameLogs = payload.games.filter(\.isComplete)

        while let session = self.session {
            let plies = payload.games.indices.contains(syncedGameIndex)
                ? payload.games[syncedGameIndex].plies : []
            while syncedPlyCount < plies.count {
                let ply = plies[syncedPlyCount]
                guard session.applyRemoteMove(ply) else { openFresh(match, payload); return }
                syncedPlyCount += 1
            }
            let hasNextGame = payload.games.count > syncedGameIndex + 1
            if session.isTerminal && hasNextGame && !payload.matchState.isComplete {
                pendingGameResult = session.record.outcome
                advanceToGame(syncedGameIndex + 1, payload: payload)
                continue   // apply any plies already present in the new current game
            }
            break
        }

        if payload.matchState.isComplete, let session, session.isTerminal {
            pendingGameResult = session.record.outcome
        }
        statusBanner = nil
    }

    /// Rebuild the local session exactly from the authoritative log (the reconnection /
    /// first-open path): set the colours, the score, and the current game, then start
    /// observing local turns. A decided match is shown at its last game.
    private func openFresh(_ match: GKTurnBasedMatch, _ payload: OnlineMatchPayload) {
        colorByPlayerID = payload.colorByPlayerID.compactMapValues(TavliEngine.Color.init(rawValue:))
        localColor = payload.color(forPlayerID: localPlayerID) ?? .white
        opponentName = match.participants
            .first { $0.player?.gamePlayerID != localPlayerID }?
            .player?.displayName ?? String(localized: "Opponent")

        matchState = payload.matchState
        completedGameLogs = payload.games.filter(\.isComplete)
        self.match = match
        statusBanner = nil

        let index = payload.currentGameIndex
        let rebuilt = GameSession.resume(from: payload.gameSave(forGameIndex: index),
                                         animationTimings: .standard)
        self.session = rebuilt
        syncedGameIndex = index
        syncedPlyCount = rebuilt.record.plies.count
        rebuilt.start()

        if matchState.isComplete {
            // Reconnecting to a finished match: surface the match-over overlay; no need
            // to observe local turns (there are none left).
            recordCancellable = nil
            pendingGameResult = rebuilt.record.outcome
        } else {
            pendingGameResult = nil
            observeLocalTurns(of: rebuilt)
        }
    }

    /// First-time setup by the match creator: assign colours (creator = White and moves
    /// first), persist the opening payload so the joiner can read its colour and the
    /// match length, and open the local session. A randomized starting player / colour
    /// swap is a later refinement.
    private func initializeNewMatch(_ match: GKTurnBasedMatch, targetWins: Int) {
        let opponentID = match.participants
            .first { $0.player?.gamePlayerID != localPlayerID }?
            .player?.gamePlayerID

        var colors: [String: TavliEngine.Color] = [localPlayerID: .white]
        if let opponentID { colors[opponentID] = .black }

        let payload = OnlineMatchPayload(targetWins: targetWins,
                                         startingPlayer: .white,
                                         colorByPlayerID: colors,
                                         games: [GameLog()])
        guard let data = try? payload.encoded() else { return }
        // Persist the colours WITHOUT ending the turn — we move first.
        match.saveCurrentTurn(withMatch: data) { _ in }
        openFresh(match, payload)
    }

    /// Advance the local session to game `index`, rebuilding it from the payload (which
    /// also replays any plies already present there, so the diff stays consistent).
    private func advanceToGame(_ index: Int, payload: OnlineMatchPayload) {
        let next = GameSession.resume(from: payload.gameSave(forGameIndex: index),
                                      animationTimings: .standard)
        self.session = next
        syncedGameIndex = index
        syncedPlyCount = next.record.plies.count
        next.start()
        observeLocalTurns(of: next)
    }

    /// Start a fresh (empty) local game `index` with the given starter — the local-win
    /// advance path, where the next game's log is created empty.
    private func startEmptyGame(index: Int, starter: TavliEngine.Color) {
        let save = GameSave(name: "Online match", savedAt: Date(),
                            startingPlayer: starter.rawValue, aiColor: nil, history: [])
        let next = GameSession.resume(from: save, animationTimings: .standard)
        self.session = next
        syncedGameIndex = index
        syncedPlyCount = 0
        next.start()
        observeLocalTurns(of: next)
    }

    // ── Outgoing: push a completed local turn ───────────────────────────────────

    /// Watch the session's ply log; when a new ply is a *local* move (or pass), push it
    /// to Game Center. Remote plies (applied via `applyRemoteMove`) are already in the
    /// match data, so they only advance the high-water mark.
    private func observeLocalTurns(of session: GameSession) {
        recordCancellable = session.$record
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleRecordChange() }
    }

    private func handleRecordChange() {
        guard let session else { return }
        let count = session.record.plies.count
        guard count > syncedPlyCount else { return }
        // The mover alternates every ply within the current game, from its starter.
        let mover = (count - 1) % 2 == 0 ? session.startingPlayer
                                         : session.startingPlayer.opponent
        syncedPlyCount = count
        if mover == localColor { pushLocalTurn() }
    }

    /// Send the current state to Game Center after a local turn. An ordinary move ends
    /// our turn; a move that wins the current game either ends the match (if it decides
    /// it) or rolls the match on to the next game.
    private func pushLocalTurn() {
        guard let session, let match else { return }

        if session.isTerminal, let winner = session.record.outcome {
            completedGameLogs.append(GameLog(plies: session.record.plies, winner: winner))
            matchState.recordGame(winner: winner)
            if matchState.isComplete {
                endMatch(match, gameWinner: winner)
            } else {
                advanceMatchAfterLocalWin(match, gameWinner: winner)
            }
            return
        }

        guard let data = try? currentPayload()?.encoded() else { return }
        match.endTurn(withNextParticipants: opponents(of: match),
                      turnTimeout: GKTurnTimeoutDefault,
                      match: data) { [weak self] error in
            Task { @MainActor in self?.reportIfError(error) }
        }
    }

    /// End the whole Game Center match (the local move decided it): set each
    /// participant's outcome by the **match** winner and write the final log.
    private func endMatch(_ match: GKTurnBasedMatch, gameWinner: TavliEngine.Color) {
        let data = (try? payload(games: completedGameLogs).encoded()) ?? Data()
        let localWonMatch = matchState.matchWinner == localColor
        for participant in match.participants {
            let isLocal = participant.player?.gamePlayerID == localPlayerID
            participant.matchOutcome = (isLocal == localWonMatch) ? .won : .lost
        }
        match.endMatchInTurn(withMatch: data) { [weak self] error in
            Task { @MainActor in self?.reportIfError(error) }
        }
        pendingGameResult = gameWinner
    }

    /// The local move won a game but not the match: start the next game locally, raise
    /// the between-games result, and hand the turn to whoever starts that game (keeping
    /// the turn when that is us).
    private func advanceMatchAfterLocalWin(_ match: GKTurnBasedMatch, gameWinner: TavliEngine.Color) {
        let nextIndex = matchState.completedGames           // == completedGameLogs.count
        let nextStarter = matchState.currentStartingPlayer
        startEmptyGame(index: nextIndex, starter: nextStarter)
        pendingGameResult = gameWinner

        let data = (try? payload(games: completedGameLogs + [GameLog()]).encoded()) ?? Data()
        if nextStarter == localColor {
            // We start the next game too: keep the turn, just persist the new state.
            match.saveCurrentTurn(withMatch: data) { [weak self] error in
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

    /// The current payload for an ordinary move: the finished games plus the in-progress
    /// game's plies.
    private func currentPayload() -> OnlineMatchPayload? {
        guard let session else { return nil }
        let current = GameLog(plies: session.record.plies, winner: session.record.outcome)
        return payload(games: completedGameLogs + [current])
    }

    private func payload(games: [GameLog]) -> OnlineMatchPayload {
        OnlineMatchPayload(targetWins: matchState.targetWins,
                           startingPlayer: matchState.baseStartingPlayer,
                           colorByPlayerID: colorByPlayerID,
                           games: games)
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
