import SwiftUI
import BoardGeometry
import TavliEngine

private typealias SColor = SwiftUI.Color

/// T9 — Game chrome. Assembles the static `BoardView` with the non-board UI
/// (turn/phase indicator, borne-off counters, contextual Undo/Done, dice, win
/// overlay) into a responsive layout bound to a `GameSession`. No game logic
/// lives here — every sub-view binds to the session's published read-state and
/// calls its intents. Board interactivity (T4/T7) is a separate ticket, so the
/// board itself stays visually static.
struct GameView: View {
    @ObservedObject var session: GameSession

    /// The human's record, shown in the win overlay after each game (#64).
    /// Defaults to empty so `#Preview`s compile.
    var stats: HumanGameStats = .empty

    /// Which color the human is playing. When `.black`, the board flips 180°
    /// so Black's checkers start bottom-left (#67).
    var humanColor: TavliEngine.Color = .white

    /// Return to the mode picker. Defaults to a no-op so `#Preview`s compile.
    var onBack: () -> Void = {}
    /// Replace the finished session with a fresh one (same settings). Defaults to a no-op so `#Preview`s compile.
    var onNewGame: () -> Void = {}
    /// Persist the current game under the given name (#61). Defaults to a no-op so `#Preview`s compile.
    var onSave: (String) -> Void = { _ in }
    /// Auto-save the in-progress game after every move (#61). Defaults to a no-op so `#Preview`s compile.
    var onAutosave: () -> Void = {}
    /// Weltsensation tournament hook: when non-nil, the win overlay's primary action
    /// becomes "Zurück zum Turnier" (calling this) instead of "Play Again", and the
    /// game-over verdict switches to German. Leaves the normal app untouched when nil.
    var tournamentExit: (() -> Void)? = nil
    /// Weltsensation: the AI opponent's display name (the real, possibly-renamed
    /// player), used by the German loss verdict. Only consulted in tournament mode.
    var tournamentOpponentName: String? = nil
    /// Whether the chrome shows the Back affordance. The normal app keeps it (returns
    /// to the picker); the tournament hides it (#: the only way out of a game is to
    /// give up, which concedes the match but keeps the game resumable).
    var showsBackButton: Bool = true
    /// Override for the "give up" confirmation's final action. When set (tournament),
    /// the player concedes-and-leaves instead of the default in-place resignation:
    /// the handler records the loss, keeps the in-progress game saved, and exits.
    var onGiveUp: (() -> Void)? = nil

    /// Online-match presentation context (#134). Non-nil switches the chrome into
    /// online mode: the board locks on the opponent's turn, the turn status shows a
    /// waiting state, Save/Resign collapse to a single "Leave match", and the win
    /// overlay returns to the lobby instead of offering a rematch. The session itself
    /// is an ordinary human-vs-human `GameSession`; only the chrome changes.
    struct Online {
        var localColor: TavliEngine.Color
        var isLocalTurn: Bool
        var opponentName: String
        /// A transient status line (opponent left / match ended), or `nil`.
        var banner: String?
        /// Forfeit/leave the match and return to the lobby.
        var onLeave: () -> Void
    }
    var online: Online? = nil

    /// Best-of-three match context (#145). Non-nil switches the chrome into match mode:
    /// a scoreboard shows the running score during play, and the game-over overlay
    /// becomes a match transition (per-game result + score + "Next game", or the match
    /// verdict + "Rematch"/exit once decided). Works for both the offline (vs-AI) and
    /// online surfaces — the only difference is how the result overlay is triggered.
    struct Match {
        /// The score, including any game that has just finished.
        var state: MatchState
        /// The local player's colour (the human offline; the local side online).
        var localColor: TavliEngine.Color
        /// Display name for the opponent in the scoreboard ("Computer" offline, the Game
        /// Center display name online).
        var opponentName: String
        /// The just-finished game's result (winner + points, or a draw, #143). Online
        /// sets this (the session has already advanced to the next game); offline
        /// leaves it `nil` and the overlay reads it from `session.record`.
        var lastGameResult: MatchGameResult?
        /// Online drives the result overlay with this flag (its session has advanced
        /// behind the overlay); offline leaves it `false` and the overlay keys on
        /// `session.phase == .gameOver`.
        var showResultOverlay: Bool = false
        /// Advance to the next game (offline builds the next session; online clears the
        /// pending-result flag — the session already advanced).
        var onNextGame: () -> Void
        /// Start a brand-new match (offline only). Online returns to the lobby via `onExit`.
        var onRematch: (() -> Void)? = nil
        /// Leave the match entirely (back to the menu offline / the lobby online).
        var onExit: () -> Void
    }
    var match: Match? = nil

    /// Full Tavli context (#144). Non-nil adds the session scoreboard (running score +
    /// "Game 2 of 3 · Fevga") during play and swaps the win overlay for the leg overlay,
    /// whose "Continue" leads to the between-legs / final screen. Mutually exclusive with
    /// `match` (best-of-three).
    struct FullTavli {
        /// The session, including the leg on the board once it has finished.
        var state: FullTavliSession
        /// Go to the between-legs screen (or the final result after leg 3).
        var onContinue: () -> Void
        /// Leave the session for the menu (it stays resumable from the autosave).
        var onExit: () -> Void
    }
    var fullTavli: FullTavli? = nil

    /// Whether the board shows a finished game whose result card is up — the scoreboard
    /// then keeps that game's number instead of advancing to the next (#179).
    private var matchGameOver: Bool {
        session.isTerminal || match?.showResultOverlay == true
    }

    /// The leg on the board (0-based), by its variant.
    private var fullTavliLegIndex: Int {
        fullTavli?.state.legIndex(ofVariantID: session.game.variant.id) ?? 0
    }

    @State private var showingSaveDialog = false
    @State private var saveName = ""

    /// Drives the move-history sheet (#60).
    @State private var showHistory = false

    /// Whether the debug eval pane is open (#101). Owned here so each
    /// orientation can place the open pane where it fits.
    @State private var showDebugPane = false

    /// Drives the post-game review sheet (#62). The drill (#63) is reached from
    /// inside review (#130), so it has no separate trigger here.
    @State private var showReview = false

    /// Surrender flow (#74): one confirmation. `surrenderChanceLine` is the
    /// "you still have a 34% chance of winning" line captured when it opens — `nil`
    /// (no line) when the win chance is unknown or at/below the threshold.
    @State private var showSurrenderConfirm = false
    @State private var surrenderChanceLine: String? = nil

    /// Drives the settings sheet (#77).
    @State private var showSettings = false

    /// Live settings (#77), bound here so the chrome reacts immediately to changes.
    @AppStorage(SettingsKey.autoRoll) private var autoRoll = true
    @AppStorage(SettingsKey.showWinProbability) private var showWinProbability = false
    @AppStorage(SettingsKey.aiAnimation) private var aiAnimation = true
    @AppStorage(SettingsKey.inPlayAnalysis) private var inPlayAnalysis = false
    @AppStorage(SettingsKey.aiLevel) private var aiLevel = AILevel.max

    /// Above this human win probability, the resign confirmation also says how
    /// much chance is being given up (#74).
    private let surrenderWarningThreshold = 0.10

    private var flipped: Bool { humanColor == .black }

    /// Whether the local player may touch the board: always offline, only on the
    /// local player's turn online (#134).
    private var boardInteractive: Bool { online?.isLocalTurn ?? true }

    /// Whether the match transition / match-over overlay should show (#145). Online
    /// drives it via the context flag (its session has advanced behind the overlay);
    /// offline keys on the current game being over.
    private var showMatchOverlay: Bool {
        guard match != nil else { return false }
        if match?.showResultOverlay == true { return true }
        if case .gameOver = session.phase { return true }
        return false
    }

    /// The just-finished game's result (winner + points, or a draw), for the match
    /// overlay's per-game verdict.
    private var lastGameResult: MatchGameResult? {
        if let r = match?.lastGameResult { return r }
        return session.record.result
    }

    /// Turn/phase status — the normal indicator, or an online "waiting for opponent"
    /// state plus any transient banner (opponent left, match ended).
    @ViewBuilder private var turnStatus: some View {
        VStack(spacing: 6) {
            // Which game this is (#143) — always visible with the turn status.
            Text(GameVariantSetting(variant: session.game.variant).name)
                .font(ChromeType.caption.weight(.semibold))
                .foregroundStyle(ChromeKit.inkSecondary)
                .textCase(.uppercase)
                .accessibilityIdentifier("variantName")
            if let online, !online.isLocalTurn, !session.isTerminal {
                OnlineWaitingView(opponentName: online.opponentName)
            } else {
                TurnIndicatorView(session: session, naming: naming)
            }
            if let banner = online?.banner {
                Text(banner)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .multilineTextAlignment(.center)
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            let layout = ChromeLayout(proxy)
            ZStack {
                ChromeKit.pageColor.ignoresSafeArea()

                if layout.mode == .compactLandscape {
                    // iPhone landscape (#109): full-safe-height board on the leading
                    // edge, all chrome in a rail beside it.
                    compactLandscapeLayout(layout)
                } else if layout.mode == .compactPortrait {
                    // iPhone portrait (#109): full-safe-width board on the bottom,
                    // compact chrome stacked above it.
                    compactPortraitLayout(layout)
                } else if landscape {
                    // Board bound to the LEADING edge, filling the height; the chrome
                    // column takes a fixed strip on the trailing edge. The board owns
                    // the leftover width via `frame(maxWidth:)` (flanking it with
                    // `Spacer`s makes the two spacers and the equally-flexible aspect-fit
                    // board split the width three ways, shrinking it to a third) and the
                    // `.leading` alignment pins the square to the left edge, so any slack
                    // between the board and the panel sits on the right and the board
                    // never shifts as the panel chrome changes. All chrome — navigation,
                    // status, counters, actions, debug — lives in the panel (#101), so
                    // nothing floats over the board's frame.
                    HStack(spacing: 0) {
                        PlayableBoardView(session: session, flipped: flipped,
                                          interactive: boardInteractive)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        sidePanel
                            .frame(width: 280)
                            .padding(.vertical, 12)
                            .padding(.trailing, 12)
                    }
                } else {
                    // Board bound to the BOTTOM, the navigation/counter bar pinned to
                    // the TOP, and the unavoidable slack (a square can't fill a tall
                    // screen) pooled into the flexible `Spacer` between them. Anchoring
                    // the board to the bottom edge keeps it from shifting as the chrome
                    // changes. The turn status sits WITH the contextual controls just
                    // above the board (#101) — near where the player is looking — so
                    // the top holds exactly one organized bar. `layoutPriority(1)` lets
                    // the board claim its full-width square first, so the `Spacer` (not
                    // the board) absorbs the slack.
                    VStack(spacing: 12) {
                        portraitTopBar
                            .padding(.horizontal, 16)
                        Spacer(minLength: 0)
                        VStack(spacing: 12) {
                            turnStatus
                            if let match {
                                MatchScoreboardView(state: match.state,
                                                    localColor: match.localColor,
                                                    opponentName: match.opponentName,
                                    gameOver: matchGameOver)
                            }
                            if let fullTavli {
                                FullTavliScoreboardView(state: fullTavli.state,
                                                        legIndex: fullTavliLegIndex)
                            }
                            if online == nil && showWinProbability && !session.isTerminal {
                                WinProbabilityBar(session: session)
                            }
                            if !session.isTerminal && boardInteractive {
                                ControlsView(session: session)
                            }
                        }
                        .padding(.horizontal, 16)
                        PlayableBoardView(session: session, flipped: flipped,
                                          interactive: boardInteractive)
                            .padding(.horizontal, 8)
                            .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)

                    // The debug toggle (and its pane) sit in the top-left band.
                    VStack(alignment: .leading, spacing: 8) {
                        DebugToggleButton(isOn: $showDebugPane)
                        if showDebugPane {
                            DebugOverlay(session: session,
                                         onHistory: { showHistory = true })
                        }
                    }
                    .animation(.easeInOut(duration: 0.15), value: showDebugPane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
                    .padding(.top, 64)
                }

                if let fullTavli, case .gameOver = session.phase {
                    // Full Tavli (#144): the leg's result + running score, then
                    // "Continue" to the between-legs screen / the final result. Review
                    // only when the leg's model is bundled (it needs the agent).
                    SColor.black.opacity(0.65).ignoresSafeArea()
                    FullTavliLegOverlayView(
                        state: fullTavli.state,
                        legIndex: fullTavliLegIndex,
                        result: session.record.result,
                        variant: session.game.variant,
                        onContinue: fullTavli.onContinue,
                        onExit: fullTavli.onExit,
                        naming: naming,
                        onReview: ModelCatalog.main.isAvailable(session.game.variant) && hasReviewableMoves
                            ? { showReview = true } : nil,
                        onHistory: { showHistory = true })
                } else if let match, showMatchOverlay {
                    // Match mode (#145): the game-over overlay becomes a match
                    // transition (score + "Next game") or the match verdict once decided.
                    SColor.black.opacity(0.65).ignoresSafeArea()
                    MatchOverlayView(match: match,
                                     lastGameResult: lastGameResult,
                                     variant: session.game.variant,
                                     naming: naming,
                                     onReview: session.aiColor != nil && hasReviewableMoves
                                         ? { showReview = true } : nil,
                                     onHistory: { showHistory = true })
                } else if case .gameOver(let winner) = session.phase {
                    // The scrim is a direct ZStack child (like the page background)
                    // so it provably spans the whole screen in both orientations —
                    // hosted inside the overlay it sized itself to the board column
                    // in landscape, leaving the panel bright. `winner == nil` is a draw
                    // (standard Plakoto, #143).
                    SColor.black.opacity(0.65).ignoresSafeArea()
                    WinOverlayView(title: winner.map(verdict) ?? ResultCopy.drawTitle,
                                   subtitle: winner == nil
                                       ? ResultCopy.drawSubtitle
                                       : ResultCopy.pointsSubtitle(points: session.record.points,
                                                                   variant: session.game.variant),
                                   stats: stats, onNewGame: onNewGame,
                                   onHistory: { showHistory = true },
                                   onReview: hasReviewableMoves ? { showReview = true } : nil,
                                   tournamentExit: tournamentExit,
                                   onlineExit: online?.onLeave,
                                   // Handicap games aren't in the vs-Computer record (#148).
                                   showsStats: session.aiColor != nil && session.handicap == nil)
                }
            }
            .environment(\.chromeMode, layout.mode)
            .sheet(isPresented: $showHistory) {
                HistoryView(session: session, naming: naming)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            // Review is the only post-game analysis entry (#130); the drill is
            // launched from inside review (reusing its precomputed analysis) rather
            // than as a parallel top-level choice.
            .fullScreenCover(isPresented: $showReview) {
                // A two-player game has no agent of its own; review it with the
                // variant's model when bundled (#143).
                GameReviewView(record: session.record,
                               agent: session.agent
                                   ?? GameSession.makeAgent(config: session.game.board.config),
                               humanColor: humanColor)
            }
            .alert("Save game", isPresented: $showingSaveDialog) {
                TextField("Name", text: $saveName)
                Button("Save") {
                    let trimmed = saveName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(trimmed.isEmpty ? Self.defaultSaveName() : trimmed)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Name this save so you can find it on the start screen.")
            }
            // The one resign confirmation (#74). Its message carries the human's
            // remaining win chance (or equity, #143) only when that is known and above
            // the warning threshold. The default ends the game in place (AI recorded as
            // winner) and clears the auto-save slot via `onAutosave`. In the tournament
            // `onGiveUp` takes over: it concedes the match but keeps the in-progress
            // game saved (resumable) and returns to the tournament.
            .alert("Give up this game?", isPresented: $showSurrenderConfirm) {
                Button("Keep playing", role: .cancel) {}
                Button("Give up", role: .destructive) {
                    if let onGiveUp {
                        onGiveUp()
                    } else {
                        session.surrender()
                        onAutosave()
                    }
                }
            } message: {
                if let line = surrenderChanceLine {
                    Text(line)
                }
            }
            // Auto-save after every move (#61): `history` grows by one per finished
            // turn — human, AI, or forced pass — so this fires once per ply. The
            // handler overwrites the single autosave slot (or clears it once the
            // game is over), so only the last in-progress game is ever kept.
            .onChange(of: session.history.count) { _, _ in onAutosave() }
            // …and as soon as a roll exists (#171): the human's (tap or auto-roll)
            // and the AI's, so a crash mid-turn resumes the same dice.
            .onChange(of: session.rollRevision) { _, _ in onAutosave() }
            // …and when a handicap token is spent (#148; never fires in a normal game).
            .onChange(of: session.handicap) { _, _ in onAutosave() }
            // Keep the live session in sync with the AI-animation setting (#77):
            // apply it on entry and whenever it's toggled, so the change lands on
            // the next AI turn without restarting the game.
            .onAppear { session.animationTimings = AppSettings.animationTimings }
            .onChange(of: aiAnimation) { _, on in
                session.animationTimings = on ? .standard : .off
            }
            // Auto-roll (#116): keep the session in sync. When enabled mid-game
            // while awaiting a human roll, `start()` fires the roll immediately.
            // Offline only (#134): online players tap to roll their own dice and the
            // opponent's arrive over the wire, so the online session ignores it.
            .onAppear { if online == nil { session.autoRoll = autoRoll } }
            .onChange(of: autoRoll) { _, on in
                guard online == nil else { return }
                session.autoRoll = on
                if on { session.start() }
            }
            // In-play analysis (#146): keep the session's flag in sync so toggling it
            // mid-game takes effect from the next turn (the next human ranking / AI
            // capture). No restart needed.
            .onAppear { session.inPlayAnalysisEnabled = inPlayAnalysis }
            .onChange(of: inPlayAnalysis) { _, on in
                session.inPlayAnalysisEnabled = on
            }
            // AI level (#108, #189): retune the search on entry and whenever the level
            // moves, so the change lands on the AI's next move without restarting.
            // Offline-only — online matches have no AI side.
            .onAppear { if online == nil { session.searchConfig = AppSettings.searchConfig } }
            .onChange(of: aiLevel) { _, _ in
                guard online == nil else { return }
                session.searchConfig = AppSettings.searchConfig
            }
        }
    }

    /// Game-over verdict from the human's perspective (#101): the human's own
    /// win is celebrated directly; an AI win names the winning color. In a
    /// Weltsensation tournament game the verdict is German instead — a win is the
    /// "Sensationell!" flourish, a loss names the AI opponent.
    private func verdict(_ winner: TavliEngine.Color) -> String {
        let humanWon = winner == humanColor
        if tournamentExit != nil {
            if humanWon { return "Sensationell!" }
            return "\(tournamentOpponentName ?? "Computer") war stärker."
        }
        return naming.title(winner)
    }

    /// Winner wording for every verdict (#overlays): "You win" / "Computer wins" vs the
    /// AI, the opponent's name online, "White wins" / "Red wins" two-player.
    private var naming: WinnerNaming {
        if let online {
            return WinnerNaming(localColor: online.localColor, opponentName: online.opponentName)
        }
        if let ai = session.aiColor {
            return WinnerNaming(localColor: ai.opponent, opponentName: String(localized: "Computer"))
        }
        return WinnerNaming(localColor: nil, opponentName: "")
    }

    /// Whether the finished game has anything to review: at least one ply that
    /// actually moved (a game resigned before any move has none).
    private var hasReviewableMoves: Bool {
        session.history.contains { !$0.halfMoves.isEmpty }
    }

    /// Seed the field with a timestamped default and open the naming dialog.
    private func presentSaveDialog() {
        saveName = Self.defaultSaveName()
        showingSaveDialog = true
    }

    /// Begin the surrender flow (#74): a single confirmation, mentioning the
    /// remaining win chance (equity for 2-point variants, #143) only above the
    /// threshold.
    private func onSurrenderTapped() {
        surrenderChanceLine = nil
        if let p = session.humanWinProbability, p > surrenderWarningThreshold {
            if session.game.variant.reportsEquity {
                let equity = EvalScale(variant: session.game.variant).value(p)
                surrenderChanceLine = String(localized: "The computer still rates your position at \(equity) points.")
            } else {
                let pct = Int((p * 100).rounded())
                surrenderChanceLine = String(localized: "You still have a \(pct)% chance of winning.")
            }
        }
        showSurrenderConfirm = true
    }

    /// A timestamped fallback name (e.g. "Game · Jun 2, 3:04 PM") used when the
    /// player leaves the field empty.
    private static func defaultSaveName() -> String {
        String(localized: "Game · ") + saveNameFormatter.string(from: Date())
    }

    private static let saveNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // Landscape: a structured card stack (#101). Navigation + debug toggle on the
    // top row, then the turn-status card with the borne-off counters, the docked
    // debug pane when open, and the action buttons anchored at the bottom. Save/
    // Resign live here (not floating over the board), with Undo/Done beneath them.
    private var sidePanel: some View {
        VStack(spacing: 14) {
            HStack {
                if showsBackButton {
                    BackButton(action: onBack)
                }
                SettingsButton { showSettings = true }
                Spacer(minLength: 0)
                DebugToggleButton(isOn: $showDebugPane)
            }
            if showDebugPane {
                DebugOverlay(session: session,
                             onHistory: { showHistory = true },
                             width: nil)
            }
            VStack(spacing: 16) {
                turnStatus
                HStack(spacing: 12) {
                    BorneOffView(session: session, color: .white)
                    BorneOffView(session: session, color: .black)
                }
            }
            .frame(maxWidth: .infinity)
            .chromeCard(padding: 16)
            // Handicap tag (#148): under the status card, where the narrow panel has room
            // for its label; only in a handicap game.
            HandicapTagButton(session: session)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let match {
                MatchScoreboardView(state: match.state,
                                    localColor: match.localColor,
                                    opponentName: match.opponentName,
                                    gameOver: matchGameOver)
            }
            if let fullTavli {
                FullTavliScoreboardView(state: fullTavli.state, legIndex: fullTavliLegIndex)
            }
            if online == nil && showWinProbability && !session.isTerminal {
                WinProbabilityBar(session: session)
            }
            Spacer(minLength: 0)
            if !session.isTerminal {
                if let online {
                    // Online (#134): one "Leave match" action; in-turn controls only
                    // when it's the local player's move.
                    LeaveButton(action: online.onLeave)
                    if online.isLocalTurn { ControlsView(session: session) }
                } else {
                    HStack(spacing: 12) {
                        SaveButton(action: presentSaveDialog)
                        // Disabled (not hidden) while the AI thinks so the row layout
                        // stays put; `canSurrender` gates both the button and the intent.
                        SurrenderButton(action: onSurrenderTapped)
                            .disabled(!session.canSurrender)
                            .opacity(session.canSurrender ? 1 : 0.4)
                    }
                    ControlsView(session: session)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // Portrait: one organized bar (#101) — navigation/actions leading, borne-off
    // counters trailing. The turn status lives down by the board, not here.
    private var portraitTopBar: some View {
        HStack(spacing: 8) {
            if showsBackButton {
                BackButton(action: onBack)
            }
            SettingsButton { showSettings = true }
            HandicapTagButton(session: session, compact: true)   // only in a handicap game (#148)
            if !session.isTerminal {
                if let online {
                    LeaveButton(action: online.onLeave)
                } else {
                    SaveButton(action: presentSaveDialog)
                    SurrenderButton(action: onSurrenderTapped)
                        .disabled(!session.canSurrender)
                        .opacity(session.canSurrender ? 1 : 0.4)
                }
            }
            BorneOffView(session: session, color: .white)
            BorneOffView(session: session, color: .black)
            Spacer(minLength: 16)
        }
    }

    // MARK: - Compact (iPhone, #109)

    /// The board at exactly the side `ChromeLayout` computed — edge-to-edge within
    /// the safe area, no padding.
    private func compactBoard(_ layout: ChromeLayout) -> some View {
        PlayableBoardView(session: session, flipped: flipped,
                          interactive: boardInteractive)
            .frame(width: layout.boardSide, height: layout.boardSide)
    }

    /// Portrait: one icon bar on top (Back · Settings · ⋯ menu, borne-off counts
    /// trailing), free space, the turn status +
    /// contextual controls just above the board, and the board on the safe bottom.
    /// The controls sit above the board (never under the home indicator), with a gap
    /// so a near-miss lands on chrome padding, not a point.
    private func compactPortraitLayout(_ layout: ChromeLayout) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                compactNavBar
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                // The slack pools here so the status + controls stay right
                // above the board.
                Spacer(minLength: 8)
                FitOrScroll {
                    compactStatusStack
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .layoutPriority(1)
                compactBoard(layout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            compactDebugPane
                .padding(.top, 56)
                .padding(.horizontal, 12)
        }
    }

    /// Landscape: the board takes the full safe height on the leading edge; every
    /// control lives in the rail to its right (scrolls only if an unusually tall
    /// combination — win bar + match score — overflows a short phone).
    private func compactLandscapeLayout(_ layout: ChromeLayout) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: ChromeLayout.compactRailGap) {
                compactBoard(layout)
                FitOrScroll {
                    compactRail
                }
                .frame(width: layout.panelRect.width)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            compactDebugPane
                .padding(8)
        }
    }

    /// Navigation as icons + a "more" menu (Save / Resign or Leave, history, debug),
    /// borne-off counters trailing. Every target stays ≥ 44 pt.
    private var compactNavBar: some View {
        HStack(spacing: 8) {
            if showsBackButton {
                BackButton(action: onBack, iconOnly: true)
            }
            SettingsButton { showSettings = true }
            gameMenu
            HandicapTagButton(session: session, compact: true)   // only in a handicap game (#148)
            Spacer(minLength: 8)
            BorneOffView(session: session, color: .white, compact: true)
            BorneOffView(session: session, color: .black, compact: true)
        }
    }

    /// Save / Resign (offline) or Leave (online), plus move history and the debug
    /// pane — the actions the iPad shows as separate buttons.
    private var gameMenu: some View {
        Menu {
            if !session.isTerminal {
                if let online {
                    Button(role: .destructive, action: online.onLeave) {
                        Label("Leave match", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Button(action: presentSaveDialog) {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    Button(role: .destructive, action: onSurrenderTapped) {
                        Label("Resign", systemImage: "flag.fill")
                    }
                    .disabled(!session.canSurrender)
                }
            }
            Button { showHistory = true } label: {
                Label("Move history", systemImage: "clock.arrow.circlepath")
            }
            Button { showDebugPane.toggle() } label: {
                Label(showDebugPane ? String(localized: "Hide debug pane")
                                    : String(localized: "Show debug pane"),
                      systemImage: "ladybug")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(minWidth: 20, minHeight: 20)
                .chromeSecondaryButtonSurface()
        }
        .accessibilityLabel("More")
        .accessibilityIdentifier("gameMenu")
    }

    /// Turn status, score, win bar and Undo/Done for portrait.
    private var compactStatusStack: some View {
        VStack(spacing: 8) {
            turnStatus
            compactScoreboard
            if online == nil && showWinProbability && !session.isTerminal {
                WinProbabilityBar(session: session)
            }
            if !session.isTerminal && boardInteractive {
                ControlsView(session: session)
            }
        }
    }

    /// The landscape rail: nav bar, status card (with the score), win bar, then
    /// Undo/Done anchored at the bottom.
    private var compactRail: some View {
        VStack(spacing: 8) {
            compactNavBar
            VStack(spacing: 8) {
                turnStatus
                compactScoreboard
            }
            .frame(maxWidth: .infinity)
            .chromeCard(padding: 10)
            if online == nil && showWinProbability && !session.isTerminal {
                WinProbabilityBar(session: session)
            }
            Spacer(minLength: 0)
            if !session.isTerminal && boardInteractive {
                ControlsView(session: session)
            }
        }
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Best-of-three or Full Tavli score as a single line (two when it can't fit).
    @ViewBuilder
    private var compactScoreboard: some View {
        if let match {
            MatchScoreboardView(state: match.state,
                                localColor: match.localColor,
                                opponentName: match.opponentName,
                                gameOver: matchGameOver,
                                compact: true)
        }
        if let fullTavli {
            FullTavliScoreboardView(state: fullTavli.state,
                                    legIndex: fullTavliLegIndex,
                                    compact: true)
        }
    }

    /// The debug pane floats over the board on iPhone (by design, #109); its ladybug
    /// closes it again (the menu opens it).
    @ViewBuilder
    private var compactDebugPane: some View {
        if showDebugPane {
            VStack(alignment: .leading, spacing: 8) {
                DebugToggleButton(isOn: $showDebugPane)
                FitOrScroll {
                    DebugOverlay(session: session,
                                 onHistory: { showHistory = true },
                                 width: 220)
                }
                .frame(width: 220)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Returns to the mode picker.
private struct BackButton: View {
    let action: () -> Void
    /// Chevron only (the compact nav bar, #109); the label stays for VoiceOver.
    var iconOnly = false

    var body: some View {
        Button(action: action) {
            if iconOnly {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 20)       // ≥ 44 pt wide with the button insets
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }
        }
        .buttonStyle(ChromeButton(role: .secondary))
        .accessibilityLabel("Back")
    }
}

/// Opens the manual-save naming dialog (#61).
private struct SaveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                Text("Save")
            }
        }
        .buttonStyle(ChromeButton(role: .secondary))
    }
}

/// Opens the resign confirmation flow (#74) — the one game-ending action, so it
/// carries the kit's destructive (brick) role.
private struct SurrenderButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "flag.fill")
                Text("Resign")
            }
        }
        .buttonStyle(ChromeButton(role: .destructive))
    }
}

/// Gear button that opens the settings sheet (#77). Uses the kit's secondary
/// `ChromeButton` role (#101) so it matches Back/Save and keeps a ≥44pt target.
private struct SettingsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
        }
        .buttonStyle(ChromeButton(role: .secondary))
        .accessibilityLabel("Settings")
    }
}

/// Online (#134): forfeit the match and return to the lobby. The one exit from an
/// online game (there is no local save to fall back on), so it carries the kit's
/// destructive role like Resign.
private struct LeaveButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text("Leave match")
            }
        }
        .buttonStyle(ChromeButton(role: .destructive))
    }
}

/// Online (#134): the status shown on the opponent's turn — a quiet spinner and the
/// opponent's name, in place of the local turn/phase indicator.
private struct OnlineWaitingView: View {
    let opponentName: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Waiting for \(opponentName)…")
                .font(ChromeType.headline)
                .foregroundStyle(ChromeTheme.ink)
                .multilineTextAlignment(.center)
        }
    }
}

// ── Sub-views ───────────────────────────────────────────────────────────────

/// Live win-probability bar for the human (#77), shown in-game when enabled in
/// Settings. Reads `humanWinProbability` (the human's chance), falling back to
/// WHITE's `winProbability` in a human-vs-human session.
private struct WinProbabilityBar: View {
    @ObservedObject var session: GameSession

    private var p: Double { session.humanWinProbability ?? session.winProbability }
    /// Win chance, or equity for a 2-point variant (#143).
    private var scale: EvalScale { EvalScale(variant: session.game.variant) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(scale.title)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Spacer()
                Text(scale.value(p))
                    .font(ChromeType.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ChromeTheme.ink.opacity(0.12))
                    Capsule().fill(ChromeTheme.doneTint.opacity(0.85))
                        .frame(width: geo.size.width * p)
                }
            }
            .frame(height: 10)
        }
        .animation(.easeInOut(duration: 0.25), value: p)
    }
}

/// Reflects the current turn phase. Binds to `session.phase` and
/// `session.currentPlayer`.
private struct TurnIndicatorView: View {
    @ObservedObject var session: GameSession
    /// Winner wording shared with the game-over overlays.
    let naming: WinnerNaming
    @AppStorage(SettingsKey.autoRoll) private var autoRoll = true

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(ChromeType.headline)
                .foregroundStyle(ChromeTheme.ink)
                .multilineTextAlignment(.center)
            if case .awaitingRoll = session.phase, let sub = diceSubtitle {
                Text(sub)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
    }

    private var label: String {
        let name = ChromeTheme.displayName(session.currentPlayer)
        switch session.phase {
        case .awaitingRoll:      return String(localized: "\(name)'s turn")
        case .picking:           return String(localized: "Pick a checker")
        case .moving:
            // Pending two-dice route choice (#169).
            if session.routeChoice != nil { return String(localized: "Choose where to land in between") }
            return String(localized: "Choose destination")
        case .aiThinking:        return String(localized: "Computer is thinking…")
        case .animating:
            if session.aiColor == session.currentPlayer { return String(localized: "Computer is moving…") }
            return String(localized: "\(name) moving…")
        case .gameOver(let w?):
            // A 2-point result (#143) says so.
            if (session.record.points ?? 1) >= 2 {
                return naming.doubleTitle(w)
            }
            return naming.title(w)
        case .gameOver(nil):     return String(localized: "Draw")
        }
    }

    /// Subtitle while a roll is awaited. `nil` suppresses the label (auto-roll:
    /// dice fire immediately so a "tap" prompt would flash misleadingly). Reads the
    /// session's own flag — an online session never auto-rolls (#134); the
    /// `@AppStorage` binding just re-renders this when the setting flips.
    private var diceSubtitle: String? {
        _ = autoRoll
        return session.autoRoll ? nil : String(localized: "Tap dice to roll")
    }
}

/// One side's borne-off count as a horizontal chip (#101): checker-colored disc,
/// name, and bold count. Reads the count straight off the board on each session
/// publish.
private struct BorneOffView: View {
    @ObservedObject var session: GameSession
    let color: TavliEngine.Color
    /// Disc + count only, tighter padding (the compact nav bar, #109).
    var compact = false

    /// Only this colour's borne-off checkers in its own tray (#143): Portes keeps the
    /// opponent's bar checkers in the same end stack, so a raw stack count would lie.
    private var count: Int {
        BoardLayout.borneOffCount(color, stacks: session.game.board.points.map(\.pieces),
                                  variant: session.game.variant)
    }

    var body: some View {
        if compact {
            HStack(spacing: 6) {
                Circle()
                    .fill(ChromeTheme.checkerColor(color))
                    .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.35), lineWidth: 1))
                    .frame(width: 18, height: 18)
                Text("\(count)")
                    .font(ChromeType.callout.bold())
                    .monospacedDigit()
                    .foregroundStyle(ChromeTheme.ink)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(ChromeTheme.ink.opacity(0.06))
            .cornerRadius(ChromeKit.buttonRadius)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(ChromeTheme.displayName(color)) \(count)"))
        } else {
            regularBody
        }
    }

    private var regularBody: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ChromeTheme.checkerColor(color))
                .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.35), lineWidth: 1))
                .frame(width: 20, height: 20)
            Text(ChromeTheme.displayName(color))
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
            Text("\(count)")
                .font(ChromeType.callout.bold())
                .monospacedDigit()
                .foregroundStyle(ChromeTheme.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(ChromeTheme.ink.opacity(0.06))
        .cornerRadius(ChromeKit.buttonRadius)
    }
}

/// Game controls. Undo peels back the last committed half-move within the current
/// turn; it greys out when nothing has been built yet. Done appears only when the
/// partial move is already legal. The dice no longer live here — they sit on the
/// board's center bar (`BoardDiceView`, #46), which frees the side rails.
private struct ControlsView: View {
    @ObservedObject var session: GameSession

    private var isHumanPicking: Bool {
        session.phase == .picking || session.phase == .moving
    }
    private var canFinish: Bool {
        isHumanPicking && session.moveBuilder.canFinishNow && !session.moveBuilder.built.isEmpty
    }

    var body: some View {
        if session.handicap != nil {
            // Reroll / Hint above Undo/Done, only in a handicap game (#148).
            VStack(spacing: 10) {
                HandicapActionsRow(session: session)
                undoDone
            }
        } else {
            undoDone
        }
    }

    private var undoDone: some View {
        HStack(spacing: 12) {
            Button {
                session.undo()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Undo")
                }
            }
            .buttonStyle(ChromeButton(role: .secondary))
            .disabled(!session.canUndo)
            .opacity(session.canUndo ? 1 : 0.4)
            if canFinish {
                Button {
                    session.confirm()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("Done")
                    }
                }
                .buttonStyle(ChromeButton(role: .primary))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Game-over overlay for a single game (#101): the verdict (or draw) on the shared
/// `GameOverCard`, the vs-AI record, Play Again (or the tournament / lobby exit),
/// and Review / History. Sits over `GameView`'s dim scrim.
private struct WinOverlayView: View {
    /// Pre-formatted verdict ("You win" / "Computer wins" / "Red wins") — the caller
    /// knows which side the human played; this view stays presentation-only.
    let title: String
    /// A line under the verdict: the points a 2-point-variant result was worth, or
    /// why a game was drawn (#143). `nil` = none.
    var subtitle: String? = nil
    let stats: HumanGameStats
    let onNewGame: () -> Void
    let onHistory: () -> Void
    /// Open the review; `nil` hides it (nothing reviewable).
    let onReview: (() -> Void)?
    /// Tournament mode (#weltsensation): when set, the primary action returns to
    /// the tournament instead of replaying the game.
    var tournamentExit: (() -> Void)? = nil
    /// Online (#134): when set, the primary action returns to the lobby, and the
    /// vs-AI record + Review (which needs a model the online session lacks) are hidden.
    var onlineExit: (() -> Void)? = nil
    /// Whether this game counts toward the vs-AI record (`false` for two-player, #143).
    var showsStats: Bool = true

    /// The vs-AI record is the main app's, never written from tournament or online
    /// games — hide it there so it doesn't read "No games yet".
    private var showsRecord: Bool { showsStats && tournamentExit == nil && onlineExit == nil }

    @Environment(\.chromeMode) private var chromeMode

    private var primary: GameOverAction {
        if let onlineExit {
            return .init(label: String(localized: "Back to lobby"), icon: "arrow.left", action: onlineExit)
        }
        if let tournamentExit {
            return .init(label: "Zurück zum Turnier", icon: "trophy.fill", action: tournamentExit)
        }
        return .init(label: String(localized: "Play Again"), icon: "arrow.clockwise", action: onNewGame)
    }

    var body: some View {
        GameOverCard(title: title,
                     subtitle: subtitle,
                     primary: primary,
                     // Review needs the bundled model the online session deliberately omits.
                     onReview: onlineExit == nil ? onReview : nil,
                     onHistory: onHistory) {
            if showsRecord {
                StatsPanelView(stats: stats, embedded: true,
                               condensed: chromeMode == .compactLandscape)
            }
        }
    }
}

/// Compact match scoreboard shown during play (#145): the running score and which
/// game of the set is in progress. Pure function of the `MatchState` value.
private struct MatchScoreboardView: View {
    let state: MatchState
    let localColor: TavliEngine.Color
    let opponentName: String
    /// A finished game's result card is up: keep showing that game's number (#179).
    var gameOver = false
    /// One line — "You 1 – 0 Computer · Game 2 of 3" — when it fits (#109).
    var compact = false

    // The score in points (#143): games for Plakoto, a double game counts 2.
    private var localWins: Int { state.score(for: localColor) }
    private var opponentWins: Int { state.score(for: localColor.opponent) }
    private var gameNumber: Int { state.displayedGameNumber(gameOver: gameOver) }

    var body: some View {
        if compact {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { scoreLine; Text(verbatim: "·"); gameLine }
                VStack(spacing: 2) { scoreLine; gameLine }
            }
            .font(ChromeType.caption)
            .foregroundStyle(ChromeKit.inkSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(ChromeTheme.ink.opacity(0.06))
            .cornerRadius(ChromeKit.buttonRadius)
        } else {
            regularBody
        }
    }

    private var scoreLine: some View {
        HStack(spacing: 6) {
            Text("You")
            Text("\(localWins) – \(opponentWins)")
                .font(ChromeType.callout.bold().monospacedDigit())
                .foregroundStyle(ChromeTheme.ink)
            Text(opponentName)
        }
        .lineLimit(1)
    }

    private var gameLine: some View {
        Text("Game \(gameNumber) of \(state.maxGames)").lineLimit(1)
    }

    private var regularBody: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text("You")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Text("\(localWins) – \(opponentWins)")
                    .font(ChromeType.title3.bold().monospacedDigit())
                    .foregroundStyle(ChromeTheme.ink)
                Text(opponentName)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            Text("Game \(gameNumber) of \(state.maxGames)")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(ChromeTheme.ink.opacity(0.06))
        .cornerRadius(ChromeKit.buttonRadius)
    }
}

/// Match-mode game-over overlay (#145): the per-game result plus the running score
/// while the match continues ("Next game"), or the match verdict and a rematch / exit
/// once a side reaches the target. Built on the shared `GameOverCard`; presentation
/// only — every action is a closure supplied by the match context.
private struct MatchOverlayView: View {
    let match: GameView.Match
    /// The just-finished game's result (offline reads it from `session.record`);
    /// a `nil` winner is a draw (#143).
    let lastGameResult: MatchGameResult?
    /// The match's rules, for the points subtitle (#143).
    var variant: any GameVariant = GameVariants.plakoto
    /// Winner wording ("You win" / "Computer wins" / "Red wins").
    let naming: WinnerNaming
    /// Open the just-finished game's review — `nil` hides it (online: no model;
    /// nothing reviewable).
    var onReview: (() -> Void)? = nil
    /// Open the just-finished game's move history.
    var onHistory: () -> Void = {}

    private var state: MatchState { match.state }
    private var localColor: TavliEngine.Color { match.localColor }
    private var isComplete: Bool { state.isComplete }
    private var localWonMatch: Bool { state.matchWinner == localColor }

    private var title: String {
        if isComplete {
            return localWonMatch
                ? String(localized: "You won the match!")
                : String(localized: "\(match.opponentName) won the match")
        }
        guard let result = lastGameResult else { return String(localized: "Game over") }
        guard let w = result.winner else { return ResultCopy.drawTitle }
        return naming.title(w)
    }

    /// Points / draw line for the just-finished game (#143), `nil` for Plakoto wins.
    private var resultSubtitle: String? {
        guard let result = lastGameResult else { return nil }
        if result.isDraw { return ResultCopy.drawSubtitle }
        return ResultCopy.pointsSubtitle(points: result.points, variant: variant)
    }

    /// The game that just finished — the score already counts it, so it is the
    /// number of recorded results (not `currentGameNumber`, which is the next game).
    private var progressCaption: String {
        isComplete
            ? String(localized: "Final")
            : String(localized: "Game \(max(1, state.results.count)) of \(state.maxGames)")
    }

    var body: some View {
        GameOverCard(
            title: title,
            subtitle: resultSubtitle,
            score: .init(leftName: String(localized: "You"),
                         left: state.score(for: localColor),
                         right: state.score(for: localColor.opponent),
                         rightName: match.opponentName,
                         caption: progressCaption),
            primary: primary,
            onReview: onReview,
            onHistory: onHistory,
            exit: .init(label: String(localized: "Back to menu"), icon: "house",
                        action: match.onExit))
    }

    private var primary: GameOverAction {
        if !isComplete {
            return .init(label: String(localized: "Next game"), icon: "arrow.right",
                         action: match.onNextGame)
        }
        if let onRematch = match.onRematch {
            return .init(label: String(localized: "Rematch"), icon: "arrow.clockwise",
                         action: onRematch)
        }
        return .init(label: String(localized: "Back to lobby"), icon: "arrow.left",
                     action: match.onExit)
    }
}

/// Scrollable two-column move sheet (#60, #190), presented as a sheet. One numbered row
/// per full turn: the local player (vs AI / online; White in a two-player game) on the
/// left, the opponent on the right, headed by checker dot + name ("You" / "Computer" /
/// online name / "White" / "Red", via `WinnerNaming`). Each cell is the roll as two small
/// die faces + the move in readable notation (#178, `MoveNotation`). Thin separators
/// instead of row cards; the newest turn is highlighted and the side still to move shows
/// "…". When the right-hand player started, the first row's left cell is empty. Binds to
/// the session so a freshly committed move appears immediately, and auto-scrolls to the
/// newest turn.
///
/// `PlyRecord` (the persistence format) stores only dice + half-moves; the notation
/// (hits, pins, mother) comes from replaying the game from its start
/// (`MoveNotation.game`), and the mover alternates from `session.startingPlayer`.
private struct HistoryView: View {
    @ObservedObject var session: GameSession
    let naming: WinnerNaming
    @Environment(\.dismiss) private var dismiss

    private var compact: Bool { ChromeType.isCompact }
    private var leftColor: TavliEngine.Color { naming.localColor ?? .white }
    private var rightColor: TavliEngine.Color { leftColor.opponent }

    /// One full turn: at most one cell per side; `pending*` marks the side still to move.
    struct Turn {
        var left: MoveNotation?
        var right: MoveNotation?
        var pendingLeft = false
        var pendingRight = false
    }

    private var turns: [Turn] {
        let notations = MoveNotation.game(session.history,
                                          startingPlayer: session.startingPlayer,
                                          config: session.game.board.config,
                                          handicap: session.record.handicap)
        var rows: [Turn] = []
        var mover = session.startingPlayer
        for n in notations {
            if mover == leftColor {
                rows.append(Turn(left: n))
            } else if rows.isEmpty || rows[rows.count - 1].right != nil {
                rows.append(Turn(right: n))          // opponent started: empty left cell
            } else {
                rows[rows.count - 1].right = n
            }
            mover = mover.opponent
        }
        if case .gameOver = session.phase { return rows }
        if mover == leftColor {
            rows.append(Turn(pendingLeft: true))
        } else if rows.isEmpty {
            rows.append(Turn(pendingRight: true))
        } else {
            rows[rows.count - 1].pendingRight = true
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if session.history.isEmpty {
                Spacer()
                Text("No moves yet")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Spacer()
            } else {
                let rows = turns
                columnHeader
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { offset, turn in
                                HistoryRow(index: offset + 1, turn: turn,
                                           current: offset == rows.count - 1)
                                    .id(offset)
                                if offset < rows.count - 1 {
                                    Rectangle().fill(ChromeTheme.ink.opacity(0.12)).frame(height: 1)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onAppear { scrollToLast(proxy, count: rows.count) }
                    .onChange(of: session.history.count) { _, _ in scrollToLast(proxy, count: turns.count) }
                }
            }
        }
        .background(ChromeKit.pageColor)
    }

    private var titleBar: some View {
        HStack {
            Text("Moves")
                .font(ChromeType.title3.bold())
                .foregroundStyle(ChromeTheme.ink)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: compact ? 15 : 17, weight: .semibold))
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .frame(width: 44, height: 44)
                    .background(ChromeTheme.ink.opacity(0.07), in: Circle())
            }
            .accessibilityLabel(Text("Done"))
        }
        .padding(.horizontal, HistoryRow.sidePadding)
        .padding(.vertical, 8)
    }

    private var columnHeader: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Spacer().frame(width: HistoryRow.numberWidth)
                playerHeader(leftColor)
                playerHeader(rightColor)
            }
            .padding(.horizontal, HistoryRow.sidePadding)
            .padding(.bottom, 8)
            Rectangle().fill(ChromeTheme.ink.opacity(0.25)).frame(height: 1)
        }
    }

    private func playerHeader(_ color: TavliEngine.Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ChromeTheme.checkerColor(color))
                .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.35), lineWidth: 1))
                .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
            Text(naming.name(color))
                .font(ChromeType.subheadline)
                .foregroundStyle(ChromeTheme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, count: Int) {
        guard count > 0 else { return }
        withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
    }
}

/// One numbered turn: the left and right cells. The current (newest) turn gets a tinted
/// full-width background.
private struct HistoryRow: View {
    static var sidePadding: CGFloat { ChromeType.isCompact ? 16 : 24 }
    static var numberWidth: CGFloat { ChromeType.isCompact ? 34 : 44 }

    let index: Int
    let turn: HistoryView.Turn
    let current: Bool

    private var compact: Bool { ChromeType.isCompact }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("\(index).")
                .font(ChromeType.subheadline.monospacedDigit())
                .foregroundStyle(ChromeKit.inkSecondary)
                .frame(width: Self.numberWidth, alignment: .leading)
            cell(turn.left, pending: turn.pendingLeft)
            cell(turn.right, pending: turn.pendingRight)
        }
        .padding(.vertical, compact ? 9 : 12)
        .padding(.horizontal, Self.sidePadding)
        .background(current ? ChromeTheme.ink.opacity(0.08) : SColor.clear)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func cell(_ notation: MoveNotation?, pending: Bool) -> some View {
        Group {
            if let notation {
                HStack(alignment: .top, spacing: compact ? 6 : 10) {
                    NotationDice(notation: notation, size: compact ? 15 : 20)
                        .padding(.top, 2)
                    MoveNotationLine(notation: notation,
                                     font: compact ? ChromeType.subheadline : ChromeType.callout)
                }
            } else if pending {
                Text(verbatim: "…")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
            } else {
                SColor.clear
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.trailing, compact ? 8 : 10)
    }
}

/// Centralizes the game chrome's typography (#92). The app targets older players
/// reading at arm's length, so every role sits roughly one step above the SwiftUI
/// text style the chrome originally used. Names mirror the system styles they
/// replace so the hierarchy stays legible; weight/design variants are applied at
/// the use site (`.bold()`, `.monospaced()`), as before. Sizes are fixed —
/// Dynamic Type is a deliberate non-goal for now. Internal, like `ChromeTheme`:
/// the chrome views live in separate files.
///
/// **Compact screens (#109):** every size is multiplied by `scale`, which `App`
/// sets once at launch from the screen size via `ChromeLayout.fontScale(forScreen:)`
/// — 1 on iPad (sizes unchanged), ~0.86 on a phone (2–3 pt smaller). The screen's
/// shorter side never changes with rotation, so the scale is constant per process.
enum ChromeType {
    /// Size multiplier — 1 on iPad. Set once at launch (`TavliApp.init`).
    static var scale: CGFloat = 1
    /// Whether the chrome runs at the compact (phone) scale.
    static var isCompact: Bool { scale < 1 }

    private static func pt(_ size: CGFloat) -> CGFloat {
        scale == 1 ? size : (size * scale).rounded()
    }

    static var title2: Font { .system(size: pt(26)) }                       // was .title2 (22)
    static var title3: Font { .system(size: pt(24)) }                       // was .title3 (20)
    static var headline: Font { .system(size: pt(22), weight: .semibold) }  // was .headline (17)
    static var body: Font { .system(size: pt(20)) }                         // was .body (17)
    static var callout: Font { .system(size: pt(19)) }                      // was .callout (16)
    static var subheadline: Font { .system(size: pt(18)) }                  // was .subheadline (15)
    static var caption: Font { .system(size: pt(16)) }                      // was .caption (12)
    static var caption2: Font { .system(size: pt(14)) }                     // was .caption2 (11)

    // Display faces with bespoke sizes.
    static var winTitle: Font { .system(size: pt(54), weight: .bold, design: .serif) }
    static var statsTitle: Font { .custom("Cormorant Garamond", size: pt(38)) }
    /// Big score digits (Full Tavli score card): the chrome face, bold, so digits are
    /// lining figures like the in-game scoreboard — never the display serif.
    static var scoreDisplay: Font { .system(size: pt(34), weight: .bold) }
    static var wordmark: Font { .custom("Cormorant Garamond", size: pt(96)) }

    // Debug overlay (developer chrome, but it was 9–10 pt — illegible on device).
    static var debugMono: Font { .system(size: pt(12), design: .monospaced) }
    static var debugLabel: Font { .system(size: pt(13)) }
}

/// Centralizes the engine-`Color` → display mappings (name + checker color) so a
/// future visual style can swap them in one place. Black renders as "Red".
/// Shared with `GameReviewView` (#62), so it stays internal rather than private.
enum ChromeTheme {
    // Explicit `SwiftUI.Color` (not the file-private `SColor` alias) so this
    // internal type — shared with `GameReviewView` — exposes no private type.
    // Light value first (unchanged); the dark value is C3 (#191, `ChromeKit`).
    static let ink = SwiftUI.Color(light: 0x3a2510, dark: 0xf4d7a4)            // frame text / cream-caramel
    static let undoTint = SwiftUI.Color(light: 0xa87a3e, dark: 0xe09a42)       // beechwood amber / caramel
    static let doneTint = SwiftUI.Color(light: 0x6a8a4a, dark: 0x86c46c)       // muted olive-green
    static let surrenderTint = SwiftUI.Color(light: 0xb05a44, dark: 0xff8d72)  // muted brick red (resign)

    static func displayName(_ c: TavliEngine.Color) -> String {
        c == .white ? String(localized: "White") : String(localized: "Red")
    }

    static func checkerColor(_ c: TavliEngine.Color) -> SwiftUI.Color {
        c == .white ? SwiftUI.Color(light: 0xfbeed1, dark: 0xf3e8cc)  // ivory (board triangle fill)
                    : SwiftUI.Color(light: 0xa83a2a, dark: 0xe04a35)  // caramel-harmonized deep red
    }
}

// MARK: - Previews

#Preview("Landscape", traits: .landscapeLeft) {
    GameView(session: GameSession())
}

#Preview("Portrait") {
    GameView(session: GameSession())
}

#Preview("Undo/Done", traits: .landscapeLeft) {
    let session = GameSession()
    session.setDice(3, 5)
    if let source = session.selectableSources.sorted().first,
       let target = session.moveBuilder.validDestinations(for: source).sorted().first {
        session.commitHalfMove(from: source, to: target)
    }
    return GameView(session: session)
}

#Preview("History") {
    let session = GameSession(startingPlayer: .white)
    // Script a couple of plies so the log has content.
    session.setDice(3, 5)
    if let src = session.selectableSources.sorted().first {
        session.selectPoint(src)
        if let dst = session.validTargets.sorted().first {
            session.commitHalfMove(from: src, to: dst)
        }
    }
    return HistoryView(session: session, naming: WinnerNaming(localColor: .white, opponentName: "Computer"))
}
