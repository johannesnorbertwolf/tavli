import Foundation
import Combine
import GameKit
import UIKit
import TavliEngine

/// The Game Center side of online play (#134, #145): sign-in, the matchmaker, the
/// lobby's match list, and the turn-event listener. All match logic lives in the
/// engine's `OnlineMatchController` (unit-tested against a simulated two-device Game
/// Center); this class only adapts `GKTurnBasedMatch` to its `OnlineMatchService` seam
/// and routes events to it.
///
/// **Event routing.**
/// - An event for the open match is applied to it (moves, match end, opponent quitting).
/// - A match this device just created through the matchmaker is opened.
/// - A match the user opened from a notification (`didBecomeActive`) is opened and the
///   online screen requested.
/// - Anything else only refreshes the lobby list (and notes "your turn" elsewhere) —
///   it never replaces the game on screen.
///
/// Sign-in starts at launch without UI (`authenticate(presentUI: false)`) so the
/// listener is registered before a notification is tapped; the Game Center sign-in
/// sheet is shown only when the player opens Play Online. Returning to the foreground
/// reloads the lobby list and the open match.
@MainActor
final class GameKitCoordinator: NSObject, ObservableObject {

    // ── Published view state ────────────────────────────────────────────────────

    @Published private(set) var isAuthenticated = false
    @Published private(set) var authError: String?
    /// The player's matches for the lobby (ended ones included, shown as finished).
    @Published private(set) var matches: [GKTurnBasedMatch] = []
    /// Set when a notification opened a match: the app should show the online screen.
    @Published var showOnlineRequested = false

    /// The match logic (session, colours, score, status). Views observe it directly.
    private(set) var controller: OnlineMatchController!

    // ── Private state ───────────────────────────────────────────────────────────

    /// Live `GKTurnBasedMatch` objects by id, for the service calls.
    private var liveMatches: [String: GKTurnBasedMatch] = [:]
    /// Match length + variant chosen in the lobby while the matchmaker is up; the next
    /// new match the listener reports is this device's creation.
    private var pendingNewMatch: (targetWins: Int, variantID: String)?
    private weak var matchmaker: UIViewController?
    /// Game Center's sign-in sheet, held until the player opens Play Online.
    private var pendingSignInController: UIViewController?
    private var foregroundObserver: NSObjectProtocol?

    override init() {
        super.init()
        controller = OnlineMatchController(service: self)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.appDidBecomeActive() }
        }
    }

    // ── Authentication ──────────────────────────────────────────────────────────

    /// Begin (or resume) Game Center sign-in. At launch call with `presentUI: false`:
    /// a needed sign-in sheet is kept until the lobby asks for it. Safe to call again.
    func authenticate(presentUI: Bool = true) {
        if presentUI, let vc = pendingSignInController {
            pendingSignInController = nil
            present(vc)
            return
        }
        guard GKLocalPlayer.local.authenticateHandler == nil || presentUI else { return }
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor in
                guard let self else { return }
                if let viewController {
                    if presentUI { self.present(viewController) }
                    else { self.pendingSignInController = viewController }
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

    /// Show Game Center's matchmaker to invite a friend (or auto-match). The created
    /// match arrives through the listener and is opened there.
    func presentInvite(targetWins: Int, variantID: String = GameVariants.defaultID) {
        guard isAuthenticated else { authenticate(presentUI: true); return }
        pendingNewMatch = (max(1, targetWins), variantID)
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        let vc = GKTurnBasedMatchmakerViewController(matchRequest: request)
        vc.turnBasedMatchmakerDelegate = self
        vc.showExistingMatches = false
        matchmaker = vc
        present(vc)
    }

    func refreshMatches() {
        GKTurnBasedMatch.loadMatches { [weak self] matches, _ in
            Task { @MainActor in
                guard let self else { return }
                for m in matches ?? [] { self.liveMatches[m.matchID] = m }
                self.matches = (matches ?? []).sorted(by: Self.lobbyOrder)
            }
        }
    }

    /// Open a match from the lobby list.
    func open(_ match: GKTurnBasedMatch) {
        liveMatches[match.matchID] = match
        controller.open(snapshot(of: match))
    }

    /// Back to the lobby, keeping the match.
    func closeMatch() {
        controller.close()
        refreshMatches()
    }

    /// Forfeit the open match.
    func forfeitMatch() {
        controller.forfeit()
        refreshMatches()
    }

    /// Remove a finished match from the player's list.
    func remove(_ match: GKTurnBasedMatch) {
        match.remove { [weak self] _ in
            Task { @MainActor in self?.refreshMatches() }
        }
    }

    private func appDidBecomeActive() {
        guard isAuthenticated else { return }
        refreshMatches()
        controller.refresh()
    }

    /// Your turn first, then their turn, then finished; most recent first within each.
    private static func lobbyOrder(_ a: GKTurnBasedMatch, _ b: GKTurnBasedMatch) -> Bool {
        func rank(_ m: GKTurnBasedMatch) -> Int {
            if m.status == .ended { return 2 }
            return m.currentParticipant?.player?.gamePlayerID == GKLocalPlayer.local.gamePlayerID ? 0 : 1
        }
        let (ra, rb) = (rank(a), rank(b))
        if ra != rb { return ra < rb }
        return (a.currentParticipant?.lastTurnDate ?? .distantPast)
             > (b.currentParticipant?.lastTurnDate ?? .distantPast)
    }

    // ── Incoming events ─────────────────────────────────────────────────────────

    private func handleEvent(_ match: GKTurnBasedMatch, didBecomeActive: Bool) {
        liveMatches[match.matchID] = match
        let snap = snapshot(of: match)
        defer { refreshMatches() }

        if controller.receive(snap) { return }

        // A match this device just created through the matchmaker.
        if let new = pendingNewMatch, match.matchData?.isEmpty ?? true,
           snap.currentPlayerID == GKLocalPlayer.local.gamePlayerID {
            pendingNewMatch = nil
            matchmaker?.dismiss(animated: true)
            controller.open(snap, newMatchTargetWins: new.targetWins, newMatchVariantID: new.variantID)
            return
        }
        // The player tapped a notification for this match.
        if didBecomeActive {
            controller.open(snap)
            showOnlineRequested = true
        }
    }

    // ── Snapshots ───────────────────────────────────────────────────────────────

    private func snapshot(of match: GKTurnBasedMatch) -> OnlineMatchSnapshot {
        OnlineMatchSnapshot(
            matchID: match.matchID,
            data: match.matchData,
            participants: match.participants.map { p in
                OnlineParticipant(playerID: p.player?.gamePlayerID,
                                  displayName: p.player?.displayName,
                                  status: Self.status(p.status),
                                  outcome: Self.outcome(p.matchOutcome))
            },
            currentPlayerID: match.currentParticipant?.player?.gamePlayerID,
            isEnded: match.status == .ended)
    }

    private static func status(_ s: GKTurnBasedParticipant.Status) -> OnlineParticipantStatus {
        switch s {
        case .invited: return .invited
        case .declined: return .declined
        case .matching: return .matching
        case .active: return .active
        case .done: return .done
        default: return .unknown
        }
    }

    private static func outcome(_ o: GKTurnBasedMatch.Outcome) -> OnlineMatchOutcome {
        switch o {
        case .none: return .none
        case .quit: return .quit
        case .won: return .won
        case .lost: return .lost
        case .tied: return .tied
        case .timeExpired: return .timeExpired
        default: return .other
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    private func opponents(of match: GKTurnBasedMatch) -> [GKTurnBasedParticipant] {
        match.participants.filter { $0.player?.gamePlayerID != GKLocalPlayer.local.gamePlayerID }
    }

    /// Present a UIKit view controller (sign-in or matchmaker) from the top-most one.
    private func present(_ vc: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(vc, animated: true)
    }

    private func liveMatch(_ id: String, _ fail: OnlineCompletion) -> GKTurnBasedMatch? {
        if let m = liveMatches[id] { return m }
        fail(GKError(.unknown))
        return nil
    }
}

// ── OnlineMatchService: the controller's operations, on GKTurnBasedMatch ─────────

extension GameKitCoordinator: OnlineMatchService {
    var localPlayerID: String { GKLocalPlayer.local.gamePlayerID }

    func endTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        match.endTurn(withNextParticipants: opponents(of: match),
                      turnTimeout: GKTurnTimeoutDefault, match: data) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func saveTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        match.saveCurrentTurn(withMatch: data) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func endMatch(matchID: String, data: Data, localWon: Bool, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        for p in match.participants where p.matchOutcome != .quit {
            let isLocal = p.player?.gamePlayerID == localPlayerID
            p.matchOutcome = (isLocal == localWon) ? .won : .lost
        }
        match.endMatchInTurn(withMatch: data) { error in
            Task { @MainActor in completion(error) }
        }
    }

    func quit(matchID: String, data: Data, inTurn: Bool, completion: @escaping OnlineCompletion) {
        guard let match = liveMatch(matchID, completion) else { return }
        if inTurn {
            match.participantQuitInTurn(with: .quit, nextParticipants: opponents(of: match),
                                        turnTimeout: GKTurnTimeoutDefault, match: data) { error in
                Task { @MainActor in completion(error) }
            }
        } else {
            match.participantQuitOutOfTurn(with: .quit) { error in
                Task { @MainActor in completion(error) }
            }
        }
    }

    func acceptInvite(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        guard let match = liveMatches[matchID] else { completion(nil, GKError(.unknown)); return }
        match.acceptInvite { [weak self] accepted, error in
            Task { @MainActor in
                guard let self else { return }
                if let accepted { self.liveMatches[accepted.matchID] = accepted }
                completion(accepted.map { self.snapshot(of: $0) }, error)
            }
        }
    }

    func load(matchID: String, completion: @escaping OnlineSnapshotCompletion) {
        GKTurnBasedMatch.load(withID: matchID) { [weak self] match, error in
            Task { @MainActor in
                guard let self else { return }
                if let match { self.liveMatches[match.matchID] = match }
                completion(match.map { self.snapshot(of: $0) }, error)
            }
        }
    }
}

// ── Turn-based event listener ───────────────────────────────────────────────────

// GameKit calls these off the main thread; hop to the main actor.
extension GameKitCoordinator: GKLocalPlayerListener {
    /// A turn was taken, an invite accepted, a match created, or the player opened the
    /// app from a turn notification (`didBecomeActive`).
    nonisolated func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch,
                            didBecomeActive: Bool) {
        Task { @MainActor in self.handleEvent(match, didBecomeActive: didBecomeActive) }
    }

    /// The match ended. Routed like a turn event so the open match applies the final
    /// move (or the opponent's forfeit) instead of freezing a move early.
    nonisolated func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        Task { @MainActor in self.handleEvent(match, didBecomeActive: false) }
    }

    /// The **local** player quit this match from Game Center's own interface while it
    /// was their turn: GameKit expects the app to forfeit it in turn.
    nonisolated func player(_ player: GKPlayer, wantsToQuitMatch match: GKTurnBasedMatch) {
        Task { @MainActor in
            self.liveMatches[match.matchID] = match
            if self.controller.activeMatchID == match.matchID {
                self.controller.forfeit()
            } else {
                self.quit(matchID: match.matchID, data: match.matchData ?? Data(), inTurn: true) { _ in }
            }
            self.refreshMatches()
        }
    }
}

// ── Matchmaker delegate ─────────────────────────────────────────────────────────

extension GameKitCoordinator: GKTurnBasedMatchmakerViewControllerDelegate {
    nonisolated func turnBasedMatchmakerViewControllerWasCancelled(_ viewController: GKTurnBasedMatchmakerViewController) {
        Task { @MainActor in
            self.pendingNewMatch = nil
            viewController.dismiss(animated: true)
        }
    }

    nonisolated func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController,
                                                       didFailWithError error: Error) {
        Task { @MainActor in
            self.pendingNewMatch = nil
            viewController.dismiss(animated: true)
            self.authError = error.localizedDescription
        }
    }
}
