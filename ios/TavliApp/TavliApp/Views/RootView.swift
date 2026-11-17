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
    /// The running Full Tavli session (#144), non-nil from its first leg until the
    /// player leaves it. Unlike `match` it is persisted: every autosave of one of its
    /// legs carries it (`GameSave.fullTavli`), so a relaunch resumes mid-leg or on the
    /// between-legs screen.
    @State private var fullTavli: FullTavliSession?
    /// Which Full Tavli screen shows while no leg is on the board.
    @State private var fullTavliScreen: FullTavliScreen?
    /// Non-nil while the opening roll screen is showing (between mode picker and game).
    @State private var pendingHumanColor: EngineColor?
    /// The variant the pending (opening-roll) game will be played under (#143).
    @State private var pendingVariant: GameVariantSetting = .plakoto
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
            // Resume exactly where the last session left off (#61, criterion 1) —
            // including a Full Tavli session mid-leg or between legs (#144).
            _session = State(initialValue: resumed.session)
            _humanColor = State(initialValue: resumed.humanColor)
            _autosaveName = State(initialValue: resumed.name)
            _fullTavli = State(initialValue: resumed.fullTavli)
            _fullTavliScreen = State(initialValue: resumed.screen)
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
                        self.leaveFullTavli()
                    },
                    onNewGame: {
                        // "Play Again" keeps the same color, mode and variant, and re-runs
                        // the starting-player flow: the opening-roll ceremony, or a forced
                        // starter per Settings (#77).
                        let variant = GameVariantSetting(variant: session.game.variant)
                        let vsAI = session.aiColor != nil
                        self.session = nil
                        if vsAI {
                            self.beginGame(humanColor: self.humanColor, variant: variant)
                        } else {
                            self.beginTwoPlayer(variant: variant)
                        }
                    },
                    onSave: { name in
                        _ = try? store.writeManual(session.snapshot(name: name, fullTavli: fullTavli))
                    },
                    onAutosave: persistAutosave,
                    match: match.map { ms in
                        // Best-of-three chrome (#145): scoreboard during play + a match
                        // transition overlay. Offline reads the just-finished winner from
                        // the session and keys the overlay on the game being over.
                        GameView.Match(
                            state: ms,
                            localColor: humanColor,
                            opponentName: String(localized: "TavTav"),
                            lastGameResult: nil,
                            showResultOverlay: false,
                            onNextGame: startNextMatchGame,
                            onRematch: startRematch,
                            onExit: {
                                persistAutosave()
                                self.session = nil
                                self.match = nil
                            }
                        )
                    },
                    fullTavli: fullTavli.map { ft in
                        GameView.FullTavli(
                            state: ft,
                            onContinue: {
                                // The between-legs state is already in the autosave
                                // (written when the leg ended), so just switch screens.
                                self.session = nil
                                self.fullTavliScreen = ft.isComplete ? .result : .transition
                            },
                            onExit: {
                                persistAutosave()
                                self.session = nil
                                self.leaveFullTavli()
                            })
                    }
                )
            } else if let pending = pendingHumanColor {
                OpeningRollView(humanColor: pending) { startingPlayer in
                    humanColor = pending
                    pendingHumanColor = nil
                    if fullTavli != nil {
                        // A Full Tavli leg (#144): the session keeps its own name/score.
                        match = nil
                        fullTavliScreen = nil
                    } else {
                        autosaveName = Self.newAutosaveName()
                        match = Self.newMatch(baseStartingPlayer: startingPlayer)
                    }
                    session = Self.makeSession(humanColor: pending, startingPlayer: startingPlayer,
                                               variant: pendingVariant)
                } onBack: {
                    pendingHumanColor = nil
                    // Backing out of the first leg's roll cancels the (unplayed) Full
                    // Tavli session; later legs return to the between-legs screen.
                    if let ft = fullTavli {
                        if ft.completedLegs == 0 { leaveFullTavli() } else { fullTavliScreen = .transition }
                    }
                }
            } else if let ft = fullTavli, let screen = fullTavliScreen {
                switch screen {
                case .transition:
                    FullTavliTransitionView(state: ft,
                                            onStartNext: startFullTavliLeg,
                                            onExit: leaveFullTavli)
                case .result:
                    FullTavliResultView(state: ft,
                                        onPlayAgain: {
                                            leaveFullTavli()
                                            beginFullTavli(humanColor: ft.aiColor?.opponent)
                                        },
                                        onExit: leaveFullTavli)
                }
            } else {
                ModePickerView(store: store,
                               stats: statsStore.stats,
                               onSelect: { color in
                                   if AppSettings.matchLength == .fullTavli {
                                       beginFullTavli(humanColor: color)
                                   } else {
                                       beginGame(humanColor: color, variant: AppSettings.variant)
                                   }
                               },
                               onTwoPlayer: {
                                   if AppSettings.matchLength == .fullTavli {
                                       beginFullTavli(humanColor: nil)
                                   } else {
                                       beginTwoPlayer(variant: AppSettings.variant)
                                   }
                               },
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
            // `onGameFinished` (#143) fires for every end — wins of 1 or 2 points and
            // draws. The vs-AI W/L record only takes decided vs-AI games (a draw is
            // neither; a two-player game isn't the human's record).
            session.onGameFinished = { [statsStore, humanColor, gameLog, autosaveName, store] winner, points in
                if let winner, session.aiColor != nil {
                    statsStore.record(humanWon: winner == humanColor)
                }
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
                // Points count (a double game scores 2); a draw scores nothing.
                self.match?.recordGame(winner: winner, points: points)
                // Advance the Full Tavli session (#144) and persist the between-legs
                // state right away (finished leg + updated score), so quitting on the
                // leg overlay or the transition screen resumes exactly there.
                if var ft = self.fullTavli {
                    ft.recordGame(winner: winner, points: points)
                    self.fullTavli = ft
                    Self.persist(session: session, fullTavli: ft, name: name, store: store)
                }
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
        let name = autosaveName.isEmpty ? Self.newAutosaveName() : autosaveName
        Self.persist(session: session, fullTavli: fullTavli, name: name, store: store)
    }

    /// The autosave write itself. A finished game is cleared — except a finished leg of
    /// an unfinished Full Tavli session (#144), which is kept together with the session
    /// so a relaunch lands on the between-legs screen. A completed session is cleared.
    @MainActor
    private static func persist(session: GameSession, fullTavli: FullTavliSession?,
                                name: String, store: SaveStore) {
        if session.isTerminal && (fullTavli?.isComplete ?? true) {
            store.clearAutosave()
        } else {
            try? store.writeAutosave(session.snapshot(name: name, fullTavli: fullTavli))
        }
    }

    // ── Full Tavli (#144) ────────────────────────────────────────────────────

    /// Start a Full Tavli session: vs the AI as `humanColor`, or two players (`nil`).
    /// Its Plakoto leg follows the variant preference. vs-AI needs every leg's model
    /// (the start screen shows "AI not available yet" otherwise).
    private func beginFullTavli(humanColor color: EngineColor?) {
        let ft = AppSettings.newFullTavli(aiColor: color?.opponent)
        if color != nil && !ft.isAIAvailable() { return }
        match = nil
        fullTavli = ft
        autosaveName = Self.newFullTavliName()
        startFullTavliLeg(ft)
    }

    /// Start the session's current leg (from the transition screen).
    private func startFullTavliLeg() {
        guard let ft = fullTavli else { return }
        startFullTavliLeg(ft)
    }

    /// Start `ft`'s current leg with that leg's variant (and its own model vs the AI).
    /// The starter follows the same rules as a single game: vs the AI the
    /// starting-player setting (fixed starter or the opening-roll ceremony); two
    /// players `variant.startingPlayer(default: .white)`.
    private func startFullTavliLeg(_ ft: FullTavliSession) {
        guard let variant = ft.currentVariant else { return }
        let setting = GameVariantSetting(variant: variant)
        let human = ft.aiColor?.opponent ?? .white
        humanColor = human
        if ft.aiColor != nil {
            if let starter = AppSettings.startingPlayer.startingPlayer(humanColor: human) {
                fullTavliScreen = nil
                session = Self.makeSession(humanColor: human, startingPlayer: starter, variant: setting)
            } else {
                pendingVariant = setting
                pendingHumanColor = human   // the opening-roll ceremony, as for a single game
            }
        } else {
            fullTavliScreen = nil
            session = Self.makeSession(humanColor: .white,
                                       startingPlayer: variant.startingPlayer(default: .white),
                                       variant: setting, vsAI: false)
        }
    }

    /// Leave the Full Tavli screens/state for the menu. The autosave is untouched, so
    /// an unfinished session stays resumable from "Continue last game".
    private func leaveFullTavli() {
        fullTavli = nil
        fullTavliScreen = nil
    }

    /// Start a new vs-AI game (or match) as `color` under `variant` (#143). The
    /// starting-player setting decides whether to run the opening-roll ceremony (#33)
    /// or seed the starter directly (#77). When best-of-three is selected (#145), a
    /// `MatchState` is created at the point the game-1 starter becomes known (here, or
    /// in the opening-roll completion). A variant without a bundled model never gets
    /// here (the start screen disables vs-AI play for it).
    private func beginGame(humanColor color: EngineColor, variant: GameVariantSetting) {
        guard AppSettings.aiAvailable(variant) else { return }
        leaveFullTavli()
        if let starter = AppSettings.startingPlayer.startingPlayer(humanColor: color) {
            humanColor = color
            autosaveName = Self.newAutosaveName()
            match = Self.newMatch(baseStartingPlayer: starter)
            session = Self.makeSession(humanColor: color, startingPlayer: starter, variant: variant)
        } else {
            pendingVariant = variant
            pendingHumanColor = color   // run the opening-roll ceremony
        }
    }

    /// Start a two-player (pass-and-play) game under `variant` (#143) — available for
    /// every variant, model or not. The board faces White; the variant picks the
    /// starter (`startingPlayer(default:)`: random for the bkgm-rules variants, White
    /// for house Plakoto). A single game: no match, no vs-AI record.
    private func beginTwoPlayer(variant: GameVariantSetting) {
        humanColor = .white
        autosaveName = Self.newAutosaveName()
        match = nil
        leaveFullTavli()
        session = Self.makeSession(humanColor: .white,
                                   startingPlayer: variant.variant.startingPlayer(default: .white),
                                   variant: variant, vsAI: false)
    }

    /// A fresh best-of-three `MatchState` when match mode is selected (#145), else
    /// `nil` for a single game. The base starter is game 1's starter; later games
    /// alternate from it.
    private static func newMatch(baseStartingPlayer: EngineColor) -> MatchState? {
        AppSettings.matchLength == .bestOfThree
            ? MatchState.bestOfThree(baseStartingPlayer: baseStartingPlayer)
            : nil
    }

    /// The variant of the game on screen (the match's variant), else the setting.
    private var currentVariant: GameVariantSetting {
        session.map { GameVariantSetting(variant: $0.game.variant) } ?? AppSettings.variant
    }

    /// Start the next game of the current match (#145), without an opening-roll
    /// ceremony — the starter alternates deterministically from the match's base.
    private func startNextMatchGame() {
        guard let match else { return }
        autosaveName = Self.newAutosaveName()
        session = Self.makeSession(humanColor: humanColor,
                                   startingPlayer: match.currentStartingPlayer,
                                   variant: currentVariant)
    }

    /// Start a brand-new match after one has finished (#145, the win overlay's
    /// "Rematch"): same colour and variant, re-resolving the starter per Settings.
    private func startRematch() {
        let variant = currentVariant
        session = nil
        match = nil
        beginGame(humanColor: humanColor, variant: variant)
    }

    /// The agent for resuming `save` (its own variant's model), or `.unavailable` when
    /// the save is vs-AI but that model isn't bundled — resuming it would silently play
    /// random moves (#143), so the picker disables such saves.
    private enum ResumeAgent { case agent(Agent?), unavailable }

    private static func resumeAgent(for save: GameSave) -> ResumeAgent {
        guard save.aiColor != nil else { return .agent(nil) }   // two-player save
        let config = GameConfig(variantID: save.variant)
        guard ModelCatalog.main.isAvailable(config.variant) else { return .unavailable }
        // A vs-AI Full Tavli session (#144) needs every leg's model, not just this one.
        if let ft = save.fullTavli, ft.aiColor != nil, !ft.isAIAvailable() { return .unavailable }
        return .agent(GameSession.makeAgent(config: config))
    }

    /// What a save resumes into: a live game (`session`), or — for a Full Tavli save
    /// whose leg is already over (#144) — the between-legs / final screen.
    private struct Resumed {
        var session: GameSession?
        var humanColor: EngineColor
        var name: String
        var fullTavli: FullTavliSession?
        var screen: FullTavliScreen?
    }

    /// Rebuild what `save` resumes into, or `nil` when it can't be (vs-AI model missing).
    @MainActor
    private static func prepareResume(_ save: GameSave) -> Resumed? {
        guard case .agent(let agent) = resumeAgent(for: save) else { return nil }
        let human = save.aiColor.flatMap { EngineColor(rawValue: $0) }?.opponent ?? .white
        var fullTavli = save.fullTavli
        if var ft = fullTavli {
            // Reconcile the session with its saved leg (#144): between legs / complete
            // show the session screens; mid-leg resumes the game below.
            let point = ft.resume(savedGame: save.record)
            fullTavli = ft
            switch point {
            case .betweenLegs:
                return Resumed(session: nil, humanColor: human, name: save.name,
                               fullTavli: ft, screen: .transition)
            case .complete:
                return Resumed(session: nil, humanColor: human, name: save.name,
                               fullTavli: ft, screen: .result)
            case .inLeg:
                break
            }
        }
        let s = GameSession.resume(from: save, agent: agent,
                                   searchConfig: AppSettings.searchConfig,
                                   animationTimings: AppSettings.animationTimings,
                                   autoRoll: AppSettings.autoRoll,
                                   inPlayAnalysis: AppSettings.inPlayAnalysisEnabled)
        return Resumed(session: s, humanColor: human, name: save.name,
                       fullTavli: fullTavli, screen: nil)
    }

    /// Load a saved game (from the picker list) and switch into it, carrying its
    /// name forward so the auto-save keeps the same identity.
    private func resume(_ meta: SaveMetadata) {
        guard let save = try? store.load(filename: meta.filename),
              let resumed = Self.prepareResume(save) else { return }
        humanColor = resumed.humanColor
        autosaveName = resumed.name
        match = nil   // a resumed single game is standalone (#145); Full Tavli resumes (#144)
        fullTavli = resumed.fullTavli
        fullTavliScreen = resumed.screen
        resumed.session?.start()
        session = resumed.session
    }

    /// The auto-save game to resume on launch, if one exists and is still in
    /// progress. A finished auto-save is discarded so launch lands on the picker —
    /// unless it is a finished leg of a Full Tavli session (#144), which resumes on the
    /// between-legs screen. A vs-AI save whose model is missing stays on disk but isn't
    /// resumed.
    @MainActor
    private static func autoResume() -> Resumed? {
        let store = SaveStore.default()
        guard let save = store.loadAutosave(), let resumed = prepareResume(save) else { return nil }
        if resumed.screen == .result { store.clearAutosave() }   // shown once, then gone
        if let s = resumed.session {
            guard !s.isTerminal else {
                store.clearAutosave()
                return nil
            }
            s.start()
        }
        return resumed
    }

    /// A timestamped game name ("Game · <date>"), the same convention the manual
    /// save dialog defaults to. Generated once per game and kept stable across that
    /// game's per-move auto-saves.
    private static func newAutosaveName() -> String {
        String(localized: "Game · ") + autosaveNameFormatter.string(from: Date())
    }

    /// The name every leg of a Full Tavli session is saved/logged under (#144).
    private static func newFullTavliName() -> String {
        String(localized: "Full Tavli · ") + autosaveNameFormatter.string(from: Date())
    }

    private static let autosaveNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// A new session under `variant` (#143): vs-AI with that variant's model, or a
    /// two-player game (`vsAI: false`, no agent).
    @MainActor
    private static func makeSession(humanColor: EngineColor, startingPlayer: EngineColor,
                                    variant: GameVariantSetting = .plakoto,
                                    vsAI: Bool = true) -> GameSession {
        let config = variant.config
        let session = GameSession(
            startingPlayer: startingPlayer,
            config: config,
            agent: vsAI ? GameSession.makeAgent(config: config) : nil,
            aiColor: vsAI ? humanColor.opponent : nil,
            searchConfig: AppSettings.searchConfig,
            animationTimings: AppSettings.animationTimings,
            autoRoll: AppSettings.autoRoll,
            inPlayAnalysis: vsAI && AppSettings.inPlayAnalysisEnabled
        )
        session.start()
        return session
    }
}

/// Which Full Tavli screen shows between legs (#144).
private enum FullTavliScreen: Equatable {
    case transition, result
}

/// Caramel start screen (#101, slimmed down in #174). Top to bottom: an icon bar
/// (Settings · My Record · Saved games), the "Tavli" wordmark, a "Continue last game"
/// card (only while an autosave exists), the primary "Play vs TavTav" (colour from
/// Settings; a small White/Red choice only when Settings says Ask), the match-length
/// pill (Single · Best of 3 · Full Tavli), the secondary modes (two players, online)
/// and a quiet current-variant line that opens Settings. The variant itself is chosen
/// in Settings; Full Tavli ignores it. One column on a phone (fits a 13 mini without
/// scrolling; `FitOrScroll` for big Dynamic Type / landscape), two on iPad (Continue +
/// Play left; match length + other modes right).
private struct ModePickerView: View {
    let store: SaveStore
    let stats: HumanGameStats
    let onSelect: (EngineColor) -> Void
    /// Start a two-player (pass-and-play) game of the selected variant (#143).
    let onTwoPlayer: () -> Void
    let onResume: (SaveMetadata) -> Void
    /// Enter the online multiplayer lobby (#134).
    let onPlayOnline: () -> Void

    @State private var saves: [SaveMetadata] = []

    @State private var showStats = false
    @State private var showSettings = false
    @State private var showSaves = false

    /// The colour to play (#77); default White (#174). `.ask` shows a small choice.
    @AppStorage(SettingsKey.preferredColor) private var preferredColor: PreferredColorSetting = .white
    /// Single game / best-of-three match (#145) / Full Tavli (#144). Default best-of-three.
    @AppStorage(SettingsKey.matchLength) private var matchLength: MatchLengthSetting = .bestOfThree
    /// The variant new games use (#143), chosen in Settings.
    @AppStorage(SettingsKey.variant) private var variant: GameVariantSetting = .plakoto

    private var isCompact: Bool { ChromeType.isCompact }

    /// Full Tavli mode (#144): the fixed Portes → Fevga → Plakoto session.
    private var isFullTavli: Bool { matchLength == .fullTavli }

    /// Whether vs-AI play is possible: the selected variant's model is bundled, or in
    /// Full Tavli mode every leg's model (#144; its Plakoto leg follows the variant).
    private var aiAvailable: Bool {
        isFullTavli
            ? FullTavliSession(preferredVariantID: variant.rawValue, aiColor: .black).isAIAvailable()
            : AppSettings.aiAvailable(variant)
    }

    private var autosave: SaveMetadata? { saves.first(where: \.isAutosave) }
    private var manualSaves: [SaveMetadata] { saves.filter { !$0.isAutosave } }

    /// Column width cap: one phone column / each iPad column.
    private var columnWidth: CGFloat { isCompact ? 440 : 380 }
    private var stackSpacing: CGFloat { isCompact ? 14 : 18 }

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                FitOrScroll {
                    VStack(spacing: isCompact ? 16 : 32) {
                        Text("Tavli")
                            .font(ChromeType.wordmark)
                            .compactSingleLine()
                            .foregroundStyle(CaramelPalette.frameText)
                        if isCompact {
                            VStack(spacing: stackSpacing) {
                                leadColumn
                                trailColumn
                            }
                            .frame(maxWidth: columnWidth)
                        } else {
                            HStack(alignment: .top, spacing: 32) {
                                leadColumn.frame(width: columnWidth)
                                trailColumn.frame(width: columnWidth)
                            }
                        }
                    }
                    .padding(.horizontal, isCompact ? 16 : 40)
                    .padding(.bottom, isCompact ? 12 : 40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { reload() }
        .sheet(isPresented: $showStats) { statsSheet }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showSaves, onDismiss: reload) {
            SavedGamesSheet(store: store, onResume: { meta in
                showSaves = false
                onResume(meta)
            })
        }
    }

    // MARK: - Sections

    /// Continue + Play (the left column on iPad).
    private var leadColumn: some View {
        VStack(spacing: stackSpacing) {
            if let autosave {
                ContinueCard(meta: autosave) { onResume(autosave) }
            }
            if isCompact {
                playCard
            } else {
                // iPad: TavTav himself heads the play card (no mascot on a phone, #109).
                VStack(spacing: 12) {
                    TavTavLoco(persona: .friendly, height: 128)
                    playCard
                }
                .frame(maxWidth: .infinity)
                .chromeCard(padding: 20)
            }
        }
    }

    /// Match length + the other modes + the variant line (the right column on iPad).
    private var trailColumn: some View {
        VStack(spacing: stackSpacing) {
            matchLengthPicker
            twoPlayerButton
            onlineButton
            // Full Tavli ignores the variant: hide the line but keep its room, so
            // switching the pill never shifts the layout.
            variantLine
                .opacity(isFullTavli ? 0 : 1)
                .disabled(isFullTavli)
                .accessibilityHidden(isFullTavli)
        }
    }

    /// Settings, My Record and Saved games as icon buttons in the top-trailing corner.
    private var topBar: some View {
        HStack(spacing: isCompact ? 4 : 8) {
            Spacer()
            iconButton("chart.bar.fill", label: "My Record") { showStats = true }
            iconButton("tray.full.fill", label: "Saved games") { showSaves = true }
            iconButton("gearshape.fill", label: "Settings") { showSettings = true }
        }
        .padding(.horizontal, isCompact ? 8 : 20)
        .padding(.top, isCompact ? 0 : 12)
    }

    private func iconButton(_ systemName: String, label: LocalizedStringKey,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(ChromeType.title3)
                .foregroundStyle(CaramelPalette.frameText.opacity(0.75))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// The primary action. A fixed colour (the default, White) is one solid "Play vs
    /// TavTav" button carrying that colour's swatch; `.ask` shows a small White/Red
    /// choice instead. Without the model, an explanation in its place (#143) — never a
    /// silently random opponent.
    @ViewBuilder
    private var playCard: some View {
        if !aiAvailable {
            VStack(spacing: 8) {
                Text("Play vs TavTav")
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Text(isFullTavli
                     ? String(localized: "TavTav is still learning some of the Full Tavli games. Play Full Tavli with two players for now.")
                     : String(localized: "TavTav is still learning \(variant.name). Play it with two players for now."))
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .modifier(CompactCard())
        } else if let fixed = preferredColor.engineColor {
            Button { onSelect(fixed) } label: {
                HStack(spacing: 10) {
                    Text("Play vs TavTav")
                    swatch(fixed, size: 18)
                }
                .padding(.vertical, isCompact ? 4 : 6)
            }
            .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
            .accessibilityIdentifier("playVsTavTav")
        } else {
            VStack(spacing: 8) {
                Text("Play vs TavTav as")
                    .font(ChromeType.callout.weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
                HStack(spacing: 10) {
                    colorButton(.white)
                    colorButton(.black)
                }
            }
        }
    }

    private func colorButton(_ color: EngineColor) -> some View {
        Button { onSelect(color) } label: {
            HStack(spacing: 8) {
                swatch(color, size: 18)
                Text(ChromeTheme.displayName(color))
            }
            .padding(.vertical, isCompact ? 4 : 6)
        }
        .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
    }

    private func swatch(_ color: EngineColor, size: CGFloat) -> some View {
        Circle()
            .fill(ChromeTheme.checkerColor(color))
            .overlay(Circle().stroke(SColor.white.opacity(0.7), lineWidth: 1.5))
            .frame(width: size, height: size)
    }

    /// Single · Best of 3 · Full Tavli (#145, #144), with a one-line caption that keeps
    /// the height stable; Full Tavli names its fixed leg order.
    private var matchLengthPicker: some View {
        VStack(spacing: 6) {
            Picker("Match length", selection: $matchLength) {
                ForEach(MatchLengthSetting.allCases) { option in
                    Text(option.shortLabel).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(ChromeTheme.undoTint)
            Text(matchLength.caption)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// Two players on this device (#143) — works for every variant, model or not.
    private var twoPlayerButton: some View {
        secondaryRow(icon: "person.2",
                     // Names the device it runs on (#109).
                     title: UIDevice.current.userInterfaceIdiom == .phone
                        ? String(localized: "Two players on this iPhone")
                        : String(localized: "Two players on this iPad"),
                     action: onTwoPlayer)
    }

    /// Online multiplayer (#134).
    private var onlineButton: some View {
        secondaryRow(icon: "globe", title: String(localized: "Play Online"), action: onPlayOnline)
    }

    private func secondaryRow(icon: String, title: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 28)
                Text(title)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
    }

    /// The current variant, quietly, with a shortcut into Settings where it's chosen.
    private var variantLine: some View {
        Button { showSettings = true } label: {
            Text("\(variant.name) · change in Settings")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Fitted stats sheet (#101): explicit Done affordance, sized to the card
    /// rather than the near-fullscreen system default.
    private var statsSheet: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            // A phone in landscape (#109) can't fit the 480 pt card; scroll there.
            FitOrScroll(enabled: ChromeType.isCompact) {
                VStack(spacing: 16) {
                    HStack {
                        Text("My Record")
                            .font(ChromeType.title3.bold())
                            .foregroundStyle(ChromeTheme.ink)
                        Spacer()
                        Button("Done") { showStats = false }
                            .buttonStyle(ChromeButton(role: .secondary))
                    }
                    .padding(.horizontal, ChromeType.isCompact ? 16 : 24)
                    .padding(.top, 16)
                    Spacer(minLength: 0)
                    StatsPanelView(stats: stats)
                        .padding(.horizontal, ChromeType.isCompact ? 16 : 24)
                    Spacer(minLength: 0)
                }
            }
        }
        .presentationDetents([.height(480)])
        .presentationDragIndicator(.visible)
    }

    private func reload() { saves = store.list() }
}

/// A `.chromeCard()` on a phone only — on iPad the play section is already a card.
private struct CompactCard: ViewModifier {
    func body(content: Content) -> some View {
        if ChromeType.isCompact { content.chromeCard(padding: 14) } else { content }
    }
}

/// "Continue last game" (#61): the autosave as one tappable card — badge, name and
/// a variant · date · moves line. Disabled (with a badge) when its vs-AI model is
/// missing (#143).
private struct ContinueCard: View {
    let meta: SaveMetadata
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(ChromeType.title2)
                    .foregroundStyle(ChromeTheme.undoTint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Continue last game")
                        .font(ChromeType.body.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    Group {
                        Text(SaveCopy.mode(meta))
                        Text(SaveCopy.detail(meta))
                    }
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 8)
                if SaveCopy.resumable(meta) {
                    Image(systemName: "chevron.right")
                        .font(ChromeType.callout.bold())
                        .foregroundStyle(ChromeKit.inkSecondary)
                } else {
                    AIUnavailableBadge()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .chromeCard(padding: ChromeType.isCompact ? 14 : 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!SaveCopy.resumable(meta))
        .accessibilityIdentifier("continueLastGame")
    }
}

/// Shared save-row wording + the resumability gate (#143/#144).
private enum SaveCopy {
    /// A vs-AI save needs its variant's model; a vs-AI Full Tavli save every leg's.
    static func resumable(_ meta: SaveMetadata) -> Bool {
        guard meta.isVsAI else { return true }
        if let ft = meta.fullTavli { return ft.isAIAvailable() }
        return AppSettings.aiAvailable(GameVariantSetting(variantID: meta.variantID))
    }

    /// "Plakoto (house rules)", "Fevga · two players", "Full Tavli · Portes".
    static func mode(_ meta: SaveMetadata) -> String {
        let variant = GameVariantSetting(variantID: meta.variantID)
        let mode = meta.isVsAI ? variant.name
                               : String(localized: "\(variant.name) · two players")
        return meta.fullTavli != nil ? String(localized: "Full Tavli · \(mode)") : mode
    }

    /// "17 Nov 2026 at 10:02 · 12 moves".
    static func detail(_ meta: SaveMetadata) -> String {
        let when = dateFormatter.string(from: meta.savedAt)
        let moves = meta.plyCount == 1 ? String(localized: "1 move")
                                       : String(localized: "\(meta.plyCount) moves")
        return "\(when) · \(moves)"
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// The "Saved games" sheet (#174): the manual saves (the autosave is the start
/// screen's Continue card), each resumable by tap and deletable.
private struct SavedGamesSheet: View {
    let store: SaveStore
    let onResume: (SaveMetadata) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var saves: [SaveMetadata] = []

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("Saved games")
                        .font(ChromeType.title3.bold())
                        .foregroundStyle(ChromeTheme.ink)
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(ChromeButton(role: .secondary))
                }
                if saves.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(ChromeType.title2)
                        Text("No saved games yet")
                            .font(ChromeType.body.weight(.semibold))
                        Text("Save a game from its menu to come back to it later.")
                            .font(ChromeType.caption)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(ChromeKit.inkSecondary)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(saves) { meta in
                                SavedGameRow(meta: meta,
                                             onResume: { onResume(meta) },
                                             onDelete: { delete(meta) })
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .padding(ChromeType.isCompact ? 16 : 24)
            .frame(maxWidth: 560)
        }
        .presentationDragIndicator(.visible)
        .onAppear(perform: reload)
    }

    private func reload() { saves = store.list().filter { !$0.isAutosave } }

    private func delete(_ meta: SaveMetadata) {
        try? store.delete(filename: meta.filename)
        reload()
    }
}

/// One saved-game row: name + subtitle (variant, when, how many plies) with a
/// trailing delete button. Tapping the body resumes the game.
private struct SavedGameRow: View {
    let meta: SaveMetadata
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onResume) {
                HStack(spacing: 12) {
                    Image(systemName: "doc.fill")
                        .font(ChromeType.title3)
                        .foregroundStyle(CaramelPalette.frameText.opacity(0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name)
                            .font(ChromeType.body.weight(.semibold))
                            .foregroundStyle(CaramelPalette.frameText)
                        Group {
                            Text(SaveCopy.mode(meta))
                            Text(SaveCopy.detail(meta))
                        }
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A vs-AI save of a variant whose model isn't bundled can't be resumed
            // without a silently random opponent (#143).
            .disabled(!SaveCopy.resumable(meta))
            .opacity(SaveCopy.resumable(meta) ? 1 : 0.5)
            if !SaveCopy.resumable(meta) { AIUnavailableBadge() }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(ChromeType.body)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(ChromeKit.cardColor)
        .cornerRadius(ChromeKit.buttonRadius)
        .shadow(color: ChromeKit.cardShadow, radius: 5, x: 0, y: 2)
    }
}

#Preview {
    RootView()
}
