import Foundation
import Combine

// ── The turn-based service seam ─────────────────────────────────────────────────
//
// Everything the online match logic needs from Game Center, expressed as plain values
// so the logic can live (and be tested) in the engine. The app's `GameKitCoordinator`
// adapts `GKTurnBasedMatch` to this; tests use an in-memory fake that simulates two
// devices sharing one server.

/// A participant's state in a turn-based match (mirrors `GKTurnBasedParticipant.Status`).
public enum OnlineParticipantStatus: Equatable, Sendable {
    case invited, declined, matching, active, done, unknown
}

/// A participant's result (mirrors `GKTurnBasedMatch.Outcome`; `.none` = still playing).
public enum OnlineMatchOutcome: Equatable, Sendable {
    case none, quit, won, lost, tied, timeExpired, other
}

public struct OnlineParticipant: Equatable, Sendable {
    /// `gamePlayerID`, or `nil` while the seat is unfilled (auto-match, or an invite
    /// Game Center hasn't resolved to a player yet).
    public var playerID: String?
    public var displayName: String?
    public var status: OnlineParticipantStatus
    public var outcome: OnlineMatchOutcome

    public init(playerID: String?, displayName: String? = nil,
                status: OnlineParticipantStatus = .active, outcome: OnlineMatchOutcome = .none) {
        self.playerID = playerID
        self.displayName = displayName
        self.status = status
        self.outcome = outcome
    }
}

/// A by-value snapshot of a turn-based match as the service last reported it.
public struct OnlineMatchSnapshot: Equatable, Sendable {
    public var matchID: String
    public var data: Data?
    public var participants: [OnlineParticipant]
    /// `gamePlayerID` of the participant whose turn it is (`nil` when ended or unfilled).
    public var currentPlayerID: String?
    public var isEnded: Bool

    public init(matchID: String, data: Data?, participants: [OnlineParticipant],
                currentPlayerID: String?, isEnded: Bool = false) {
        self.matchID = matchID
        self.data = data
        self.participants = participants
        self.currentPlayerID = currentPlayerID
        self.isEnded = isEnded
    }

    public var payload: OnlineMatchPayload? {
        guard let data, !data.isEmpty else { return nil }
        return try? OnlineMatchPayload.decoded(from: data)
    }
}

public typealias OnlineCompletion = @MainActor (Error?) -> Void
public typealias OnlineSnapshotCompletion = @MainActor (OnlineMatchSnapshot?, Error?) -> Void

/// The operations the controller performs on a match. Every call names the match by
/// id; the turn always passes to the other participant(s).
@MainActor
public protocol OnlineMatchService: AnyObject {
    var localPlayerID: String { get }
    /// Write `data` and hand the turn to the opponent.
    func endTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion)
    /// Write `data` and keep the turn.
    func saveTurn(matchID: String, data: Data, completion: @escaping OnlineCompletion)
    /// End the match in turn: the local player's outcome is won/lost, every other
    /// participant's the opposite (a participant who already quit keeps `.quit`).
    func endMatch(matchID: String, data: Data, localWon: Bool, completion: @escaping OnlineCompletion)
    /// Forfeit: quit in turn (handing the turn on with `data`) or out of turn.
    func quit(matchID: String, data: Data, inTurn: Bool, completion: @escaping OnlineCompletion)
    /// Accept a pending invitation to the match.
    func acceptInvite(matchID: String, completion: @escaping OnlineSnapshotCompletion)
    /// Reload the match's current state from the server.
    func load(matchID: String, completion: @escaping OnlineSnapshotCompletion)
}

/// What the online chrome should tell the player. The app maps each case to localized
/// copy; `nil` means nothing to say.
public enum OnlineMatchStatus: Equatable, Sendable {
    /// Joined a match whose creator hasn't written the opening state yet.
    case waitingForOpponentToStart
    /// The opponent forfeited; the local player won the match.
    case opponentLeft
    /// The match is over (shown when it ended without a final move to replay).
    case matchEnded
    /// The local turn couldn't be sent; it's kept and retried automatically.
    case sendFailed
    /// It's the local player's turn in another match (name of that opponent).
    case yourTurnElsewhere(String)
    /// Any other service error, as the service described it.
    case error(String)
}

// ── The controller ──────────────────────────────────────────────────────────────

/// Drives one online (Game Center turn-based) match at a time on top of an
/// `OnlineMatchService` (#134, #145, #143). The engine stays network-agnostic: each game
/// is a human-vs-human `GameSession`; the opponent's plies are fed in through
/// `GameSession.applyRemoteMove`, the local player's are pushed when the session's ply
/// log grows by a local move.
///
/// **State model.** The match's entire state is its `OnlineMatchPayload` (each game's
/// ply log + result). Opening, resuming, catching up and recovering are all "decode +
/// replay", never board reconciliation.
///
/// **Robustness rules** (each covered by `OnlineMatchControllerTests`):
/// - A player missing from the colour map takes the colour nobody holds, so a match
///   created before the opponent's seat was filled (auto-match, unresolved invite)
///   still gets one White and one Black. The resolved map is written back with the
///   next turn.
/// - An invitation is accepted before the match is opened.
/// - Events for a match other than the active one never replace the active game.
/// - A finished match (ended with a final move, or by the opponent quitting) is
///   applied and locked; an opponent who quits is detected and the match closed as a
///   local win.
/// - A turn that fails to send is kept: the board is not rolled back, and a stale
///   server snapshot never overwrites it; `refresh()` / the retry resends it.
@MainActor
public final class OnlineMatchController: ObservableObject {

    // ── Published view state ────────────────────────────────────────────────────

    /// The current game's session, or `nil` when no match is open.
    @Published public private(set) var session: GameSession?
    /// Id of the open match, or `nil` in the lobby.
    @Published public private(set) var activeMatchID: String?
    @Published public private(set) var localColor: Color = .white
    /// The opponent's display name, or `nil` while unknown (the app shows "Opponent").
    @Published public private(set) var opponentName: String?
    @Published public var status: OnlineMatchStatus?
    @Published public private(set) var matchState = MatchState.single(baseStartingPlayer: .white)
    /// The just-finished game's result while the between-games / match-over overlay
    /// should show. Cleared by `continueToNextGame()`.
    @Published public var pendingGameResult: MatchGameResult?
    /// The match is over (decided, or someone quit): the board is read-only.
    @Published public private(set) var isMatchOver = false
    /// A local turn is written locally but not yet confirmed by the service.
    @Published public private(set) var hasUnsentTurn = false

    /// Whether the local player may act on the board right now.
    public var isLocalTurn: Bool {
        guard let session, !isMatchOver else { return false }
        return session.currentPlayer == localColor && !session.isTerminal
    }

    // ── Private match state ─────────────────────────────────────────────────────

    private let service: OnlineMatchService
    private let animationTimings: AnimationTimings
    /// Seconds before a failed send is retried automatically (`nil` = only on
    /// `refresh()`); doubles per consecutive failure, capped at 5 minutes.
    private let retryDelay: TimeInterval?
    private var retryTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var colorByPlayerID: [String: Color] = [:]
    private var variantID = GameVariants.defaultID
    private var completedGameLogs: [GameLog] = []
    private var syncedGameIndex = 0
    private var syncedPlyCount = 0
    private var recordCancellable: AnyCancellable?
    private var pendingOp: PendingOp?
    private var currentPlayerID: String?

    private enum PendingOp {
        case endTurn(Data), saveTurn(Data), endMatch(Data, localWon: Bool)
    }

    private var localPlayerID: String { service.localPlayerID }

    public init(service: OnlineMatchService, animationTimings: AnimationTimings = .standard,
                retryDelay: TimeInterval? = 10) {
        self.service = service
        self.animationTimings = animationTimings
        self.retryDelay = retryDelay
    }

    // ── Entry points ────────────────────────────────────────────────────────────

    /// Open a match the player chose (lobby row, notification, or a match the local
    /// player just created). Accepts a pending invitation first. `newMatchTargetWins` /
    /// `newMatchVariantID` are used only if the match has no state yet and it's the
    /// local player's turn — i.e. this device created it.
    public func open(_ snapshot: OnlineMatchSnapshot,
                     newMatchTargetWins: Int = 1,
                     newMatchVariantID: String = GameVariants.defaultID) {
        if let me = participant(localPlayerID, in: snapshot), me.status == .invited {
            service.acceptInvite(matchID: snapshot.matchID) { [weak self] accepted, error in
                guard let self else { return }
                if let error { self.status = .error(error.localizedDescription); return }
                self.open(accepted ?? snapshot, newMatchTargetWins: newMatchTargetWins,
                          newMatchVariantID: newMatchVariantID)
            }
            return
        }
        if activeMatchID != snapshot.matchID { resetMatchState() }
        activeMatchID = snapshot.matchID
        apply(snapshot, newMatchTargetWins: newMatchTargetWins, newMatchVariantID: newMatchVariantID)
    }

    /// A service event (turn taken, match ended, …) for any match. Applies it when it's
    /// the open match and returns `true`; otherwise leaves the open game alone, notes
    /// when it's now the local player's turn there, and returns `false`.
    @discardableResult
    public func receive(_ snapshot: OnlineMatchSnapshot) -> Bool {
        guard snapshot.matchID == activeMatchID else {
            if activeMatchID != nil, !snapshot.isEnded, snapshot.currentPlayerID == localPlayerID {
                status = .yourTurnElsewhere(
                    opponent(in: snapshot)?.displayName ?? "")
            }
            return false
        }
        apply(snapshot)
        return true
    }

    /// Reload the open match from the service (app returned to the foreground, or a
    /// send failed) and apply it — resending an unsent local turn if still needed.
    public func refresh() {
        guard let id = activeMatchID else { return }
        service.load(matchID: id) { [weak self] snapshot, error in
            guard let self, self.activeMatchID == id else { return }
            if let snapshot { self.apply(snapshot) }
            else if let error { self.status = .error(error.localizedDescription) }
        }
    }

    /// Back to the lobby **without** forfeiting: the match stays open on the service.
    public func close() {
        resetMatchState()
    }

    /// Forfeit the open match (the opponent wins), then close it.
    public func forfeit() {
        guard let id = activeMatchID else { return }
        if !isMatchOver {
            let data = (try? currentPayload()?.encoded()) ?? Data()
            service.quit(matchID: id, data: data, inTurn: currentPlayerID == localPlayerID) { _ in }
        }
        resetMatchState()
    }

    /// Dismiss the between-games overlay (the session already advanced behind it).
    public func continueToNextGame() {
        pendingGameResult = nil
    }

    // ── Applying a snapshot ─────────────────────────────────────────────────────

    private func apply(_ snapshot: OnlineMatchSnapshot,
                       newMatchTargetWins: Int = 1,
                       newMatchVariantID: String = GameVariants.defaultID) {
        currentPlayerID = snapshot.currentPlayerID
        if let name = opponent(in: snapshot)?.displayName { opponentName = name }

        guard let payload = snapshot.payload else {
            // No state yet: the creator (holding the opening turn) writes it; anyone
            // else waits for it.
            if snapshot.currentPlayerID == localPlayerID, !snapshot.isEnded {
                initializeNewMatch(snapshot, targetWins: newMatchTargetWins, variantID: newMatchVariantID)
            } else {
                session = nil
                status = snapshot.isEnded ? .matchEnded : .waitingForOpponentToStart
                isMatchOver = snapshot.isEnded
            }
            return
        }

        // The local log is ahead of this snapshot: an unsent local turn (resend it) or
        // a late, stale update (ignore it). The board never goes backwards.
        if session != nil, !snapshot.isEnded, progress(of: payload) < localProgress() {
            if pendingOp != nil { resendPending() }
            return
        }
        if pendingOp != nil, progress(of: payload) >= localProgress() {
            // The service has it after all (the "failure" was only the reply).
            pendingOp = nil
            hasUnsentTurn = false
        }

        resolveColors(payload)
        if session != nil, syncedGameIndex <= payload.currentGameIndex {
            applyIncoming(payload)
        } else {
            rebuild(from: payload)
        }

        handleEnd(of: snapshot)
        if status == .waitingForOpponentToStart || status == .sendFailed, pendingOp == nil {
            status = nil
        }
    }

    /// Apply everything in `payload` not yet seen, game by game; a finished game with
    /// the match still going advances to the next one behind the result overlay. Any
    /// inconsistency falls back to an exact rebuild from the log.
    private func applyIncoming(_ payload: OnlineMatchPayload) {
        matchState = payload.matchState
        completedGameLogs = payload.games.filter(\.isComplete)

        while let session {
            let plies = payload.games.indices.contains(syncedGameIndex)
                ? payload.games[syncedGameIndex].plies : []
            if plies.count < syncedPlyCount { rebuild(from: payload); return }
            while syncedPlyCount < plies.count {
                guard session.applyRemoteMove(plies[syncedPlyCount]) else {
                    rebuild(from: payload); return
                }
                syncedPlyCount += 1
            }
            let hasNextGame = payload.games.count > syncedGameIndex + 1
            if hasNextGame {
                guard session.isTerminal || payload.games[syncedGameIndex].isComplete else {
                    rebuild(from: payload); return
                }
                pendingGameResult = payload.games[syncedGameIndex].result ?? session.record.result
                startGame(syncedGameIndex + 1, from: payload)
                continue
            }
            break
        }
        if payload.matchState.isComplete {
            pendingGameResult = payload.games.last?.result ?? session?.record.result
            isMatchOver = true
            recordCancellable = nil
        }
    }

    /// Rebuild the current game exactly from the log (first open / reconnection /
    /// recovery). A decided match is shown at its last game, locked.
    private func rebuild(from payload: OnlineMatchPayload) {
        variantID = payload.variant
        matchState = payload.matchState
        completedGameLogs = payload.games.filter(\.isComplete)
        startGame(payload.currentGameIndex, from: payload)
        if matchState.isComplete {
            recordCancellable = nil
            isMatchOver = true
            pendingGameResult = payload.games.last?.result
        } else {
            pendingGameResult = nil
        }
    }

    private func startGame(_ index: Int, from payload: OnlineMatchPayload) {
        let next = GameSession.resume(from: payload.gameSave(forGameIndex: index),
                                      animationTimings: animationTimings)
        session = next
        syncedGameIndex = index
        syncedPlyCount = next.record.plies.count
        next.start()
        observeLocalTurns(of: next)
    }

    /// Resolve every colour, filling in a player missing from the map (the opponent's
    /// seat wasn't filled when the match was created) with the free colour.
    private func resolveColors(_ payload: OnlineMatchPayload) {
        variantID = payload.variant
        var map = colorByPlayerID
        for (id, raw) in payload.colorByPlayerID {
            if let c = Color(rawValue: raw) { map[id] = c }
        }
        if map[localPlayerID] == nil {
            let taken = Set(map.values)
            map[localPlayerID] = taken.contains(.white) ? .black : .white
        }
        colorByPlayerID = map
        localColor = map[localPlayerID] ?? .white
    }

    /// React to a finished match or a quitting opponent.
    private func handleEnd(of snapshot: OnlineMatchSnapshot) {
        let opponentQuit = snapshot.participants.contains {
            $0.playerID != localPlayerID && $0.outcome == .quit
        }
        if snapshot.isEnded {
            isMatchOver = true
            recordCancellable = nil
            if opponentQuit { status = .opponentLeft }
            else if pendingGameResult == nil { status = .matchEnded }
            return
        }
        guard opponentQuit, !isMatchOver else { return }
        // The opponent forfeited: it's now our turn, so close the match as our win.
        isMatchOver = true
        recordCancellable = nil
        status = .opponentLeft
        if snapshot.currentPlayerID == localPlayerID, let id = activeMatchID {
            let data = (try? currentPayload()?.encoded()) ?? Data()
            send(.endMatch(data, localWon: true), matchID: id)
        }
    }

    // ── Creating a match ────────────────────────────────────────────────────────

    /// First-time setup by the creator: creator = White; game 1's starter per the
    /// variant; persist the opening state (keeping the turn if we start, else handing
    /// it over) and open the local session.
    private func initializeNewMatch(_ snapshot: OnlineMatchSnapshot, targetWins: Int, variantID: String) {
        self.variantID = variantID
        let starter = GameConfig(variantID: variantID).variant.startingPlayer(default: .white)
        var colors: [String: Color] = [localPlayerID: .white]
        if let opponentID = opponent(in: snapshot)?.playerID { colors[opponentID] = .black }
        colorByPlayerID = colors
        localColor = .white

        let payload = OnlineMatchPayload(targetWins: targetWins, startingPlayer: starter,
                                         colorByPlayerID: colors, games: [GameLog()],
                                         variant: variantID)
        rebuild(from: payload)
        guard let data = try? payload.encoded() else { return }
        send(starter == localColor ? .saveTurn(data) : .endTurn(data), matchID: snapshot.matchID)
        if starter != localColor { currentPlayerID = opponent(in: snapshot)?.playerID }
    }

    // ── Outgoing: push a completed local turn ───────────────────────────────────

    /// Watch the ply log; a new ply by the local colour is pushed. Handled on the next
    /// main-queue turn: `@Published` fires before the change lands, and a game-ending
    /// move appends its ply *before* the session records the result, so reading the
    /// record afterwards sees the finished game.
    private func observeLocalTurns(of session: GameSession) {
        recordCancellable = session.$record
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] _ in
                guard let self, let session, session === self.session else { return }
                self.handleRecordChange(session.record)
            }
    }

    private func handleRecordChange(_ record: GameRecord) {
        let count = record.plies.count
        guard count > syncedPlyCount else { return }
        let mover = (count - 1) % 2 == 0 ? record.startingPlayer : record.startingPlayer.opponent
        syncedPlyCount = count
        if mover == localColor { pushLocalTurn(record) }
    }

    private func pushLocalTurn(_ record: GameRecord) {
        guard let id = activeMatchID else { return }

        if let result = record.result {
            // The local move finished the game (win of 1/2 points, or a draw, #143).
            completedGameLogs.append(GameLog(plies: record.plies, result: result))
            matchState.record(result)
            pendingGameResult = result
            if matchState.isComplete {
                isMatchOver = true
                recordCancellable = nil
                let data = (try? payload(games: completedGameLogs).encoded()) ?? Data()
                send(.endMatch(data, localWon: matchState.matchWinner == localColor), matchID: id)
            } else {
                // Start the next game locally; hand the turn to its starter.
                let nextIndex = completedGameLogs.count
                let starter = matchState.currentStartingPlayer
                let data = (try? payload(games: completedGameLogs + [GameLog()]).encoded()) ?? Data()
                startGame(nextIndex, from: payload(games: completedGameLogs + [GameLog()]))
                send(starter == localColor ? .saveTurn(data) : .endTurn(data), matchID: id)
            }
            return
        }

        let current = GameLog(plies: record.plies, result: nil)
        guard let data = try? payload(games: completedGameLogs + [current]).encoded() else { return }
        send(.endTurn(data), matchID: id)
    }

    private func send(_ op: PendingOp, matchID: String) {
        pendingOp = op
        hasUnsentTurn = true
        let done: OnlineCompletion = { [weak self] error in
            guard let self, self.activeMatchID == matchID else { return }
            if error != nil {
                self.status = .sendFailed
                self.scheduleRetry()
            } else {
                self.pendingOp = nil
                self.hasUnsentTurn = false
                self.consecutiveFailures = 0
                self.retryTask?.cancel()
                if self.status == .sendFailed { self.status = nil }
            }
        }
        switch op {
        case .endTurn(let data):
            currentPlayerID = nil
            service.endTurn(matchID: matchID, data: data, completion: done)
        case .saveTurn(let data):
            service.saveTurn(matchID: matchID, data: data, completion: done)
        case .endMatch(let data, let localWon):
            service.endMatch(matchID: matchID, data: data, localWon: localWon, completion: done)
        }
    }

    /// Retry a failed send after a growing delay by reloading the match: `apply` then
    /// resends if the service is still behind, or drops it if the turn arrived after all.
    private func scheduleRetry() {
        guard let base = retryDelay, let id = activeMatchID else { return }
        consecutiveFailures += 1
        let delay = min(300, base * pow(2, Double(consecutiveFailures - 1)))
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.activeMatchID == id, self.pendingOp != nil else { return }
            self.refresh()
        }
    }

    private func resendPending() {
        guard let op = pendingOp, let id = activeMatchID else { return }
        send(op, matchID: id)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    private func currentPayload() -> OnlineMatchPayload? {
        guard let session else { return nil }
        let current = GameLog(plies: session.record.plies, result: session.record.result)
        return payload(games: completedGameLogs + [current])
    }

    private func payload(games: [GameLog]) -> OnlineMatchPayload {
        OnlineMatchPayload(targetWins: matchState.targetWins,
                           startingPlayer: matchState.baseStartingPlayer,
                           colorByPlayerID: colorByPlayerID,
                           games: games,
                           variant: variantID)
    }

    /// (games, plies in the last game) — how far a log has got.
    private func progress(of payload: OnlineMatchPayload) -> Progress {
        Progress(games: payload.games.count, plies: payload.games.last?.plies.count ?? 0)
    }

    private func localProgress() -> Progress {
        if matchState.isComplete {
            return Progress(games: completedGameLogs.count, plies: completedGameLogs.last?.plies.count ?? 0)
        }
        return Progress(games: completedGameLogs.count + 1, plies: session?.record.plies.count ?? 0)
    }

    private struct Progress: Comparable {
        let games: Int, plies: Int
        static func < (a: Progress, b: Progress) -> Bool {
            (a.games, a.plies) < (b.games, b.plies)
        }
    }

    private func participant(_ id: String, in snapshot: OnlineMatchSnapshot) -> OnlineParticipant? {
        snapshot.participants.first { $0.playerID == id }
    }

    private func opponent(in snapshot: OnlineMatchSnapshot) -> OnlineParticipant? {
        snapshot.participants.first { $0.playerID != localPlayerID }
    }

    private func resetMatchState() {
        retryTask?.cancel()
        retryTask = nil
        consecutiveFailures = 0
        recordCancellable = nil
        session = nil
        activeMatchID = nil
        opponentName = nil
        colorByPlayerID = [:]
        variantID = GameVariants.defaultID
        completedGameLogs = []
        syncedGameIndex = 0
        syncedPlyCount = 0
        matchState = .single(baseStartingPlayer: .white)
        pendingGameResult = nil
        isMatchOver = false
        hasUnsentTurn = false
        pendingOp = nil
        currentPlayerID = nil
        status = nil
        localColor = .white
    }
}
