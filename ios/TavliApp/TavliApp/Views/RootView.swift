import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// T10 — app root. Switches between the caramel mode picker, the opening roll,
/// and a live game. Owns save/load (#61): auto-saves the in-progress game when
/// the app backgrounds, auto-resumes that game on the next cold launch, and lets
/// the player load or delete any saved game from the picker.
///
/// Holds the active `GameSession` in `@State` so the reference stays stable
/// across re-renders; `GameView` observes it. Picking a color goes to the
/// opening roll; the roll result (or manual override) builds the session.
struct RootView: View {
    @StateObject private var statsStore = HumanStatsStore()
    /// Online multiplayer (#134). Lives at the root so its lifetime spans the lobby
    /// and a live match; inert until the player opens the online lobby.
    @StateObject private var online = GameKitCoordinator()
    /// Whether the online lobby/game is on screen (entered from the mode picker).
    @State private var showOnline = false
    @State private var session: GameSession?
    @State private var humanColor: EngineColor = .white
    /// The running best-of-three score (#145), non-nil only while a match is in
    /// progress. In-memory only — a match isn't resumed across app launches (out of
    /// scope per #145); a cold-launch autosave resumes as a standalone single game.
    @State private var match: MatchState?
    /// Non-nil while the opening roll screen is showing (between mode picker and game).
    @State private var pendingHumanColor: EngineColor?
    /// The current game's display name — a timestamped default ("Game · <date>",
    /// the same convention as a manual save) for a fresh game, or the resumed
    /// game's own name. Written into the auto-save slot on every move (#61).
    @State private var autosaveName: String = ""
    @Environment(\.scenePhase) private var scenePhase

    private let store = SaveStore.default()
    /// Append-only log of every finished game (#104), separate from the autosave slot.
    private let gameLog = GameLogStore.default()

    init() {
        // UI-test hook: start directly in a deterministic human-vs-AI game so the
        // board interaction can be driven without the picker or random dice.
        if ProcessInfo.processInfo.arguments.contains("-uiTestGame") {
            let s = RootView.makeSession(humanColor: .black, startingPlayer: .black)
            s.setManualDice(3, 5)
            _session = State(initialValue: s)
            _humanColor = State(initialValue: .black)
            _autosaveName = State(initialValue: RootView.newAutosaveName())
        } else if let resumed = RootView.autoResume() {
            // Resume exactly where the last session left off (#61, criterion 1).
            _session = State(initialValue: resumed.session)
            _humanColor = State(initialValue: resumed.humanColor)
            _autosaveName = State(initialValue: resumed.name)
        } else {
            _session = State(initialValue: nil)
        }
    }

    var body: some View {
        Group {
            if showOnline {
                // Online multiplayer (#134) is a self-contained branch: the coordinator
                // owns its own session, so the offline save/resume/stats wiring below is
                // bypassed entirely (online results don't touch the vs-AI record).
                OnlineRootView(coordinator: online, onExit: { showOnline = false })
            } else if let session {
                GameView(
                    session: session,
                    stats: statsStore.stats,
                    humanColor: humanColor,
                    onBack: {
                        persistAutosave()        // never lose progress on the way out
                        self.session = nil
                        self.match = nil
                    },
                    onNewGame: {
                        // "Play Again" keeps the same color and re-runs the starting-player
                        // flow: the opening-roll ceremony, or a forced starter per Settings (#77).
                        self.session = nil
                        self.beginGame(humanColor: self.humanColor)
                    },
                    onSave: { name in try? store.writeManual(session.snapshot(name: name)) },
                    onAutosave: persistAutosave,
                    match: match.map { ms in
                        // Best-of-three chrome (#145): scoreboard during play + a match
                        // transition overlay. Offline reads the just-finished winner from
                        // the session and keys the overlay on the game being over.
                        GameView.Match(
                            state: ms,
                            localColor: humanColor,
                            opponentName: String(localized: "TavTav"),
                            lastGameWinner: nil,
                            showResultOverlay: false,
                            onNextGame: startNextMatchGame,
                            onRematch: startRematch,
                            onExit: {
                                persistAutosave()
                                self.session = nil
                                self.match = nil
                            }
                        )
                    }
                )
            } else if let pending = pendingHumanColor {
                OpeningRollView(humanColor: pending) { startingPlayer in
                    humanColor = pending
                    pendingHumanColor = nil
                    autosaveName = Self.newAutosaveName()
                    match = Self.newMatch(baseStartingPlayer: startingPlayer)
                    session = Self.makeSession(humanColor: pending, startingPlayer: startingPlayer)
                } onBack: {
                    pendingHumanColor = nil
                }
            } else {
                ModePickerView(store: store,
                               stats: statsStore.stats,
                               onSelect: beginGame,
                               onResume: resume,
                               onPlayOnline: { showOnline = true })
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { persistAutosave() }
        }
        // Wire each live session's game-over hook to record the human's W/L (#64).
        // Done here (keyed on session identity) rather than at the static creation
        // sites so it covers every entry point uniformly — opening roll, resume from
        // the picker, and cold-launch auto-resume — while skipping the deterministic
        // UI-test game so test runs never write stats. Runs synchronously (no await)
        // well before any game can end, so the hook is always armed in time.
        .task(id: session.map(ObjectIdentifier.init)) {
            guard let session,
                  !ProcessInfo.processInfo.arguments.contains("-uiTestGame") else { return }
            session.onGameOver = { [statsStore, humanColor, gameLog, autosaveName] winner in
                statsStore.record(humanWon: winner == humanColor)
                // Persist EVERY finished game to the append-only log (#104), regardless
                // of outcome or whether it was ever manually saved. `record.outcome` is
                // already set by the time this hook fires. Synchronous, like the autosave.
                // Carry the in-play 2-ply analysis (#146) so the review opens instantly;
                // empty (analysis off / no model) keeps the file at schema v1.
                let name = autosaveName.isEmpty ? Self.newAutosaveName() : autosaveName
                let entries = session.inPlayAnalysis
                let save = GameSave(record: session.record, name: name,
                                    analysis: entries.isEmpty ? nil : entries)
                try? gameLog.append(save)
                // Advance the best-of-three score (#145), if a match is in progress, so
                // the match scoreboard + transition overlay reflect this game's result.
                self.match?.recordGame(winner: winner)
            }
        }
    }

    /// Write the current game to the single auto-save slot — on every move (#61),
    /// and when backgrounding or leaving. Overwriting one reserved slot means only
    /// the **last** in-progress game is ever kept. The game is stored under its
    /// timestamped `autosaveName` (the "Continue last game" badge is added by the
    /// picker row, not the name). A finished game is cleared instead (completed
    /// games are never resumed); on the picker (`session == nil`) the prior
    /// auto-save is left intact.
    private func persistAutosave() {
        guard let session else { return }
        if session.isTerminal {
            store.clearAutosave()
        } else {
            let name = autosaveName.isEmpty ? Self.newAutosaveName() : autosaveName
            try? store.writeAutosave(session.snapshot(name: name))
        }
    }

    /// Start a new game (or match) as `color`. The starting-player setting decides
    /// whether to run the opening-roll ceremony (#33) or seed the starter directly
    /// (#77). When best-of-three is selected (#145), a `MatchState` is created at the
    /// point the game-1 starter becomes known (here, or in the opening-roll completion).
    private func beginGame(humanColor color: EngineColor) {
        if let starter = AppSettings.startingPlayer.startingPlayer(humanColor: color) {
            humanColor = color
            autosaveName = Self.newAutosaveName()
            match = Self.newMatch(baseStartingPlayer: starter)
            session = Self.makeSession(humanColor: color, startingPlayer: starter)
        } else {
            pendingHumanColor = color   // run the opening-roll ceremony
        }
    }

    /// A fresh best-of-three `MatchState` when match mode is selected (#145), else
    /// `nil` for a single game. The base starter is game 1's starter; later games
    /// alternate from it.
    private static func newMatch(baseStartingPlayer: EngineColor) -> MatchState? {
        AppSettings.matchLength == .bestOfThree
            ? MatchState.bestOfThree(baseStartingPlayer: baseStartingPlayer)
            : nil
    }

    /// Start the next game of the current match (#145), without an opening-roll
    /// ceremony — the starter alternates deterministically from the match's base.
    private func startNextMatchGame() {
        guard let match else { return }
        autosaveName = Self.newAutosaveName()
        session = Self.makeSession(humanColor: humanColor,
                                   startingPlayer: match.currentStartingPlayer)
    }

    /// Start a brand-new match after one has finished (#145, the win overlay's
    /// "Rematch"): same colour, re-resolving the starter per Settings.
    private func startRematch() {
        session = nil
        match = nil
        beginGame(humanColor: humanColor)
    }

    /// Load a saved game (from the picker list) and switch into it, carrying its
    /// name forward so the auto-save keeps the same identity.
    private func resume(_ meta: SaveMetadata) {
        guard let save = try? store.load(filename: meta.filename) else { return }
        humanColor = save.aiColor.flatMap { EngineColor(rawValue: $0) }?.opponent ?? .white
        autosaveName = save.name
        match = nil   // a resumed game is a standalone single game (#145)
        let s = GameSession.resume(from: save, agent: GameSession.makeAgent(),
                                   searchConfig: AppSettings.searchConfig,
                                   animationTimings: AppSettings.animationTimings,
                                   manualDiceEntry: AppSettings.diceMode == .manual,
                                   autoRoll: AppSettings.autoRoll,
                                   inPlayAnalysis: AppSettings.inPlayAnalysisEnabled)
        s.start()
        session = s
    }

    /// The auto-save game to resume on launch, if one exists and is still in
    /// progress. A finished auto-save is discarded so launch lands on the picker.
    private static func autoResume() -> (session: GameSession, humanColor: EngineColor, name: String)? {
        let store = SaveStore.default()
        guard let save = store.loadAutosave() else { return nil }
        let s = GameSession.resume(from: save, agent: GameSession.makeAgent(),
                                   searchConfig: AppSettings.searchConfig,
                                   animationTimings: AppSettings.animationTimings,
                                   manualDiceEntry: AppSettings.diceMode == .manual,
                                   autoRoll: AppSettings.autoRoll,
                                   inPlayAnalysis: AppSettings.inPlayAnalysisEnabled)
        guard !s.isTerminal else {
            store.clearAutosave()
            return nil
        }
        s.start()
        let human = save.aiColor.flatMap { EngineColor(rawValue: $0) }?.opponent ?? .white
        return (s, human, save.name)
    }

    /// A timestamped game name ("Game · <date>"), the same convention the manual
    /// save dialog defaults to. Generated once per game and kept stable across that
    /// game's per-move auto-saves.
    private static func newAutosaveName() -> String {
        String(localized: "Game · ") + autosaveNameFormatter.string(from: Date())
    }

    private static let autosaveNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    @MainActor
    private static func makeSession(humanColor: EngineColor, startingPlayer: EngineColor) -> GameSession {
        let session = GameSession(
            startingPlayer: startingPlayer,
            agent: GameSession.makeAgent(),
            aiColor: humanColor.opponent,
            searchConfig: AppSettings.searchConfig,
            animationTimings: AppSettings.animationTimings,
            manualDiceEntry: AppSettings.diceMode == .manual,
            autoRoll: AppSettings.autoRoll,
            inPlayAnalysis: AppSettings.inPlayAnalysisEnabled
        )
        session.start()
        return session
    }
}

/// Caramel start screen (#101): "Tavli" wordmark, one primary "Play vs AI" card
/// holding the color choice (tapping a color starts the opening roll), a quiet
/// "My Record" row, and (since #61) a list of saved games to resume or delete.
/// The AI-vs-AI watch mode from the design reference is deferred.
private struct ModePickerView: View {
    let store: SaveStore
    let stats: HumanGameStats
    let onSelect: (EngineColor) -> Void
    let onResume: (SaveMetadata) -> Void
    /// Enter the online multiplayer lobby (#134).
    let onPlayOnline: () -> Void

    @State private var saves: [SaveMetadata] = []

    @State private var showStats = false
    @State private var showSettings = false

    /// A fixed preferred color skips the per-game White/Red choice (#77).
    @AppStorage(SettingsKey.preferredColor) private var preferredColor: PreferredColorSetting = .ask
    /// Single game vs best-of-three match (#145). Defaults to best-of-three.
    @AppStorage(SettingsKey.matchLength) private var matchLength: MatchLengthSetting = .bestOfThree

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            VStack(spacing: 28) {
                Text("Tavli")
                    .font(ChromeType.wordmark)
                    .foregroundStyle(CaramelPalette.frameText)

                playCard
                matchLengthPicker
                onlineButton
                recordRow

                if !saves.isEmpty {
                    SavedGamesList(saves: saves,
                                   onResume: onResume,
                                   onDelete: delete)
                        .frame(maxWidth: 440)
                }
            }
            .padding(40)

            // Settings gear in the top-trailing corner (#77).
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(ChromeType.title2)
                    .foregroundStyle(CaramelPalette.frameText.opacity(0.7))
                    .padding(12)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .onAppear { reload() }
        .sheet(isPresented: $showStats) { statsSheet }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    /// The one primary action: start playing. With a pinned preferred color (#77)
    /// it's a single flat "Play vs AI" button (the action is the focus; the color is
    /// just a small swatch). Otherwise it's the color-choice card — pick White/Red,
    /// which carry the checker disc they map to on the board (engine black = Red).
    @ViewBuilder
    private var playCard: some View {
        if let fixed = preferredColor.engineColor {
            Button { onSelect(fixed) } label: {
                HStack(spacing: 10) {
                    Text("Play vs AI")
                    Circle()
                        .fill(ChromeTheme.checkerColor(fixed))
                        .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.25), lineWidth: 1))
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
            .frame(maxWidth: 392)
        } else {
            VStack(spacing: 18) {
                Text("Play vs AI")
                    .font(ChromeType.title2.bold())
                    .foregroundStyle(ChromeTheme.ink)
                HStack(spacing: 14) {
                    ColorChoiceButton(color: .white) { onSelect(.white) }
                    ColorChoiceButton(color: .black) { onSelect(.black) }
                }
            }
            .frame(maxWidth: 392)
            .chromeCard(padding: 24)
        }
    }

    /// Single-game vs best-of-three choice for the next vs-AI game (#145). A best-of-
    /// three match is the social default, so it's pre-selected; the setting is sticky.
    private var matchLengthPicker: some View {
        Picker("Match length", selection: $matchLength) {
            ForEach(MatchLengthSetting.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .tint(ChromeTheme.undoTint)
        .frame(maxWidth: 392)
    }

    /// Enter online multiplayer (#134): a secondary action under the primary
    /// "Play vs AI", so playing the AI stays the obvious default.
    private var onlineButton: some View {
        Button(action: onPlayOnline) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                Text("Play Online")
                Spacer(minLength: 24)
                Image(systemName: "chevron.right")
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
        .frame(maxWidth: 440)
    }

    /// Quiet secondary row: current W–L at a glance, full panel on tap.
    private var recordRow: some View {
        Button {
            showStats = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.fill")
                Text("My Record")
                Spacer(minLength: 24)
                Text(recordSubtitle)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
        .frame(maxWidth: 440)
    }

    /// Fitted stats sheet (#101): explicit Done affordance, sized to the card
    /// rather than the near-fullscreen system default.
    private var statsSheet: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("My Record")
                        .font(ChromeType.title3.bold())
                        .foregroundStyle(ChromeTheme.ink)
                    Spacer()
                    Button("Done") { showStats = false }
                        .buttonStyle(ChromeButton(role: .secondary))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                Spacer(minLength: 0)
                StatsPanelView(stats: stats)
                    .padding(.horizontal, 24)
                Spacer(minLength: 0)
            }
        }
        .presentationDetents([.height(480)])
        .presentationDragIndicator(.visible)
    }

    private var recordSubtitle: String {
        stats.total == 0
            ? String(localized: "No games yet")
            : "\(stats.wins)W – \(stats.losses)L"
    }

    private func reload() { saves = store.list() }

    private func delete(_ meta: SaveMetadata) {
        try? store.delete(filename: meta.filename)
        reload()
    }
}

/// One side of the play card: the checker disc the player would command plus a
/// "Play <Name>" label. Tapping starts the opening roll for that color.
private struct ColorChoiceButton: View {
    let color: EngineColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Circle()
                    .fill(ChromeTheme.checkerColor(color))
                    .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.25), lineWidth: 1.5))
                    .frame(width: 44, height: 44)
                Text("Play \(ChromeTheme.displayName(color))")
                    .foregroundStyle(ChromeTheme.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(ChromeButton(role: .secondary))
    }
}

/// The "Saved games" section: a titled, scrollable list of resumable games.
private struct SavedGamesList: View {
    let saves: [SaveMetadata]
    let onResume: (SaveMetadata) -> Void
    let onDelete: (SaveMetadata) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved games")
                .font(ChromeType.headline)
                .foregroundStyle(CaramelPalette.frameText.opacity(0.8))

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(saves) { meta in
                        SavedGameRow(meta: meta,
                                     onResume: { onResume(meta) },
                                     onDelete: { onDelete(meta) })
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }
}

/// One saved-game row: title + subtitle (when it was saved, how many plies) with
/// a trailing delete button. Tapping the body resumes the game.
private struct SavedGameRow: View {
    let meta: SaveMetadata
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onResume) {
                HStack(spacing: 12) {
                    Image(systemName: meta.isAutosave ? "arrow.clockwise.circle.fill" : "doc.fill")
                        .font(ChromeType.title3)
                        .foregroundStyle(CaramelPalette.frameText.opacity(0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        if meta.isAutosave {
                            // The auto-save's own name follows the manual convention;
                            // this badge sits on top of it to mark the last game (#61).
                            Text("Continue last game")
                                .font(ChromeType.caption2.weight(.bold))
                                .textCase(.uppercase)
                                .foregroundStyle(CaramelPalette.frameText.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(CaramelPalette.frameText.opacity(0.12))
                                .clipShape(Capsule())
                                .padding(.bottom, 2)
                        }
                        Text(meta.name)
                            .font(ChromeType.body.weight(.semibold))
                            .foregroundStyle(CaramelPalette.frameText)
                        Text(subtitle)
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(ChromeType.body)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(ChromeKit.cardColor)
        .cornerRadius(ChromeKit.buttonRadius)
        .shadow(color: ChromeKit.cardShadow, radius: 5, x: 0, y: 2)
    }

    private var subtitle: String {
        let when = SavedGameRow.dateFormatter.string(from: meta.savedAt)
        let moves = meta.plyCount == 1 ? "1 move" : "\(meta.plyCount) moves"
        return "\(when) · \(moves)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

#Preview {
    RootView()
}
