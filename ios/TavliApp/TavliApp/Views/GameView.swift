import SwiftUI
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

    @State private var showingSaveDialog = false
    @State private var saveName = ""

    /// Drives the move-history sheet (#60).
    @State private var showHistory = false

    /// Whether the debug eval pane is open (#101). Owned here so each
    /// orientation can place the open pane where it fits.
    @State private var showDebugPane = false

    /// Drives the post-game review sheet (#62).
    @State private var showReview = false

    /// Drives the post-game drill sheet (#63).
    @State private var showDrill = false

    /// Surrender flow (#74). `showWinProbWarning` is the preliminary "you can still
    /// win" alert (shown only when the human's win probability exceeds the threshold);
    /// `showSurrenderConfirm` is the standard confirmation; `surrenderWinPct` is the
    /// rounded percentage captured for the warning copy.
    @State private var showWinProbWarning = false
    @State private var showSurrenderConfirm = false
    @State private var surrenderWinPct = 0

    /// Drives the settings sheet (#77).
    @State private var showSettings = false

    /// Live settings (#77), bound here so the chrome reacts immediately to changes.
    @AppStorage(SettingsKey.diceMode) private var diceMode: DiceModeSetting = .auto
    @AppStorage(SettingsKey.autoRoll) private var autoRoll = false
    @AppStorage(SettingsKey.showWinProbability) private var showWinProbability = false
    @AppStorage(SettingsKey.aiAnimation) private var aiAnimation = true

    /// Above this human win probability, resigning first shows the preliminary
    /// "you can still win" alert before the standard confirmation (#74).
    private let surrenderWarningThreshold = 0.10

    private var flipped: Bool { humanColor == .black }

    /// Manual dice entry is offered whenever a roll is awaited (#77). In manual
    /// mode the session also pauses on the AI's turn (#110), so this is true for
    /// both players' rolls — the human enters the AI's dice too.
    private var manualDiceActive: Bool {
        diceMode == .manual && session.phase == .awaitingRoll
    }

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            ZStack {
                SColor(hex: 0xece6dc).ignoresSafeArea()

                if landscape {
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
                                          manualDiceEntry: diceMode == .manual)
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
                            TurnIndicatorView(session: session)
                            if showWinProbability && !session.isTerminal {
                                WinProbabilityBar(session: session)
                            }
                            if manualDiceActive {
                                ManualDiceControl(session: session)
                            }
                            if !session.isTerminal {
                                ControlsView(session: session)
                            }
                        }
                        .padding(.horizontal, 16)
                        PlayableBoardView(session: session, flipped: flipped,
                                          manualDiceEntry: diceMode == .manual)
                            .padding(.horizontal, 8)
                            .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)

                    // The TavTav logo gets the top-right as its own tile; the debug
                    // toggle (and its pane) move to the top-LEFT band to clear it.
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

                    // Logo tile, top-right corner — floats over the empty band so it
                    // never pushes the board down.
                    TavTavLogo()
                        .frame(width: 180)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                        .allowsHitTesting(false)
                }

                if case .gameOver(let winner) = session.phase {
                    // The scrim is a direct ZStack child (like the page background)
                    // so it provably spans the whole screen in both orientations —
                    // hosted inside the overlay it sized itself to the board column
                    // in landscape, leaving the panel bright.
                    SColor.black.opacity(0.65).ignoresSafeArea()
                    WinOverlayView(title: verdict(winner), stats: stats, onNewGame: onNewGame,
                                   onHistory: { showHistory = true },
                                   onReview: { showReview = true },
                                   onDrill: { showDrill = true },
                                   mascot: session.aiColor.map { winner == $0 ? .smirk : .friendly })
                }
            }
            .sheet(isPresented: $showHistory) {
                HistoryView(session: session)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .fullScreenCover(isPresented: $showReview) {
                GameReviewView(record: session.record,
                               agent: session.agent,
                               humanColor: humanColor)
            }
            .fullScreenCover(isPresented: $showDrill) {
                DrillView(record: session.record,
                          precomputed: nil,
                          agent: session.agent,
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
            // Preliminary "you can still win" alert (#74), shown only when the human's
            // win probability is above the threshold. Confirming here advances to the
            // standard confirmation. The second alert is flipped on via `async` so it
            // presents only after this one has fully dismissed (chained alerts on the
            // same view otherwise race and the second can fail to appear).
            .alert("Are you sure you want to give up?", isPresented: $showWinProbWarning) {
                Button("I'm sure") { DispatchQueue.main.async { showSurrenderConfirm = true } }
                Button("Keep playing", role: .cancel) {}
            } message: {
                Text("You still have a \(surrenderWinPct)% chance of winning. Are you sure you want to give up?")
            }
            // Standard confirmation (#74). Confirming ends the game (AI recorded as
            // winner) and clears the auto-save slot via `onAutosave` — the same path a
            // played-out loss takes through the per-move auto-save hook below.
            .alert("Are you sure you want to give up?", isPresented: $showSurrenderConfirm) {
                Button("Give up", role: .destructive) {
                    session.surrender()
                    onAutosave()
                }
                Button("Keep playing", role: .cancel) {}
            }
            // Auto-save after every move (#61): `history` grows by one per finished
            // turn — human, AI, or forced pass — so this fires once per ply. The
            // handler overwrites the single autosave slot (or clears it once the
            // game is over), so only the last in-progress game is ever kept.
            .onChange(of: session.history.count) { _, _ in onAutosave() }
            // Keep the live session in sync with the AI-animation setting (#77):
            // apply it on entry and whenever it's toggled, so the change lands on
            // the next AI turn without restarting the game.
            .onAppear { session.animationTimings = AppSettings.animationTimings }
            .onChange(of: aiAnimation) { _, on in
                session.animationTimings = on ? .standard : .off
            }
            // Manual-dice mode (#110) applies to both players: keep the session's
            // flag in sync so it pauses for the human to enter the AI's dice too.
            // Applied on entry and whenever the setting is toggled mid-game.
            .onAppear { session.manualDiceEntry = diceMode == .manual }
            .onChange(of: diceMode) { _, mode in
                session.manualDiceEntry = mode == .manual
                // Leaving manual mode while the AI sits paused for its dice:
                // let it roll automatically again (no-op on the human's turn).
                if mode != .manual { session.start() }
            }
            // Auto-roll (#116): keep the session in sync. When enabled mid-game
            // while awaiting a human roll, `start()` fires the roll immediately.
            .onAppear { session.autoRoll = autoRoll }
            .onChange(of: autoRoll) { _, on in
                session.autoRoll = on
                if on { session.start() }
            }
        }
    }

    /// Game-over verdict from the human's perspective (#101): the human's own
    /// win is celebrated directly; an AI win names the winning color.
    private func verdict(_ winner: TavliEngine.Color) -> String {
        winner == humanColor ? String(localized: "You win!") : String(localized: "\(ChromeTheme.displayName(winner)) wins")
    }

    /// Seed the field with a timestamped default and open the naming dialog.
    private func presentSaveDialog() {
        saveName = Self.defaultSaveName()
        showingSaveDialog = true
    }

    /// Begin the surrender flow (#74). Above the win-probability threshold the
    /// player is warned they can still win before the standard confirmation; at or
    /// below it, the standard confirmation is shown directly.
    private func onSurrenderTapped() {
        let p = session.humanWinProbability ?? 0
        if p > surrenderWarningThreshold {
            surrenderWinPct = Int((p * 100).rounded())
            showWinProbWarning = true
        } else {
            showSurrenderConfirm = true
        }
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
            TavTavLogoTile()
            HStack {
                BackButton(action: onBack)
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
                TurnIndicatorView(session: session)
                HStack(spacing: 12) {
                    BorneOffView(session: session, color: .white)
                    BorneOffView(session: session, color: .black)
                }
            }
            .frame(maxWidth: .infinity)
            .chromeCard(padding: 16)
            if showWinProbability && !session.isTerminal {
                WinProbabilityBar(session: session)
            }
            Spacer(minLength: 0)
            if manualDiceActive {
                ManualDiceControl(session: session)
            }
            if !session.isTerminal {
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
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // Portrait: one organized bar (#101) — navigation/actions leading, borne-off
    // counters trailing. The turn status lives down by the board, not here.
    private var portraitTopBar: some View {
        HStack(spacing: 8) {
            BackButton(action: onBack)
            SettingsButton { showSettings = true }
            if !session.isTerminal {
                SaveButton(action: presentSaveDialog)
                SurrenderButton(action: onSurrenderTapped)
                    .disabled(!session.canSurrender)
                    .opacity(session.canSurrender ? 1 : 0.4)
            }
            BorneOffView(session: session, color: .white)
            BorneOffView(session: session, color: .black)
            Spacer(minLength: 16)
        }
    }
}

/// Returns to the mode picker.
private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Back")
            }
        }
        .buttonStyle(ChromeButton(role: .secondary))
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

// ── Sub-views ───────────────────────────────────────────────────────────────

/// Live win-probability bar for the human (#77), shown in-game when enabled in
/// Settings. Reads `humanWinProbability` (the human's chance), falling back to
/// WHITE's `winProbability` in a human-vs-human session.
private struct WinProbabilityBar: View {
    @ObservedObject var session: GameSession

    private var p: Double { session.humanWinProbability ?? session.winProbability }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Win chance")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Spacer()
                Text(String(format: "%.0f%%", p * 100))
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
    @AppStorage(SettingsKey.diceMode) private var diceMode: DiceModeSetting = .auto
    @AppStorage(SettingsKey.autoRoll) private var autoRoll = false

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
        case .moving:            return String(localized: "Choose destination")
        case .aiThinking:        return String(localized: "TavTav thinking…")
        case .animating:         return String(localized: "\(name) moving…")
        case .gameOver(let w):   return String(localized: "\(ChromeTheme.displayName(w)) wins!")
        }
    }

    /// Subtitle while a roll is awaited. `nil` suppresses the label (auto-roll:
    /// dice fire immediately so a "tap" prompt would flash misleadingly). In
    /// manual mode the hint names which side's dice to enter (#110).
    private var diceSubtitle: String? {
        if diceMode == .manual {
            let isAITurn = session.aiColor != nil && session.currentPlayer == session.aiColor
            return isAITurn ? String(localized: "Enter TavTav's dice") : String(localized: "Enter your dice")
        }
        return autoRoll ? nil : String(localized: "Tap dice to roll")
    }
}

/// One side's borne-off count as a horizontal chip (#101): checker-colored disc,
/// name, and bold count. Reads the count straight off the board on each session
/// publish.
private struct BorneOffView: View {
    @ObservedObject var session: GameSession
    let color: TavliEngine.Color

    private var count: Int {
        let board = session.game.board
        return color == .white
            ? board.points[board.boardSize + 1].count
            : board.points[0].count
    }

    var body: some View {
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
        HStack(spacing: 12) {
            Button {
                session.undoOrStepBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Undo")
                }
            }
            .buttonStyle(ChromeButton(role: .secondary))
            .disabled(!session.canUndoOrStepBack)
            .opacity(session.canUndoOrStepBack ? 1 : 0.4)
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

/// Full-screen game-over takeover (#101): a scrim strong enough to retire the
/// chrome behind it, a personalized serif verdict, the stats card, a solid
/// primary Play Again, and real secondary buttons (icons + labels) for the
/// post-game tools.
private struct WinOverlayView: View {
    /// Pre-formatted verdict ("You win!" / "Red wins") — the caller knows which
    /// side the human played; this view stays presentation-only.
    let title: String
    let stats: HumanGameStats
    let onNewGame: () -> Void
    let onHistory: () -> Void
    let onReview: () -> Void
    let onDrill: () -> Void
    /// TavTav's persona for the verdict — smirk if it won, friendly if it lost.
    /// `nil` in human-vs-human games (no mascot shown).
    var mascot: TavTavPersona? = nil

    var body: some View {
        VStack(spacing: 28) {
            if let mascot {
                TavTavAvatar(persona: mascot, size: 108)
            }
            Text(title)
                .font(ChromeType.winTitle)
                .foregroundStyle(.white)
            StatsPanelView(stats: stats)
            Button {
                onNewGame()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Play Again")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }
            .buttonStyle(ChromeButton(role: .primary))
            HStack(spacing: 14) {
                Button {
                    onReview()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                        Text("Review game")
                    }
                }
                .buttonStyle(ChromeButton(role: .scrim))
                Button {
                    onDrill()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "target")
                        Text("Drill blunders")
                    }
                }
                .buttonStyle(ChromeButton(role: .scrim))
                Button {
                    onHistory()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("History")
                    }
                }
                .buttonStyle(ChromeButton(role: .scrim))
            }
        }
    }
}

/// Scrollable ply-by-ply move log (#60), presented as a sheet. Mirrors the CLI
/// `h`/`history` command: one row per ply with its number, mover, dice, and the
/// half-moves played (or "pass"). Binds to the session so a freshly committed
/// move appears immediately, and auto-scrolls to the newest ply.
///
/// `PlyRecord` (the persistence format) stores only dice + half-moves; the 1-based
/// index and mover are derived here from array position and `session.startingPlayer`.
private struct HistoryView: View {
    @ObservedObject var session: GameSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.history.isEmpty {
                Spacer()
                Text("No moves yet")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(session.history.enumerated()), id: \.offset) { offset, ply in
                                let index = offset + 1
                                let mover = index % 2 == 1
                                    ? session.startingPlayer
                                    : session.startingPlayer.opponent
                                HistoryRow(index: index, mover: mover, ply: ply)
                                    .background(offset % 2 == 1
                                        ? ChromeTheme.ink.opacity(0.04)
                                        : SColor.clear)
                                    .cornerRadius(8)
                                    .id(offset)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                    .onAppear { scrollToLast(proxy) }
                    .onChange(of: session.history.count) { _, _ in scrollToLast(proxy) }
                }
            }
        }
        .background(SColor(hex: 0xece6dc))
    }

    private var header: some View {
        HStack {
            Text("Move history")
                .font(ChromeType.title3.bold())
                .foregroundStyle(ChromeTheme.ink)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(ChromeButton(role: .secondary))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        guard !session.history.isEmpty else { return }
        withAnimation { proxy.scrollTo(session.history.count - 1, anchor: .bottom) }
    }
}

/// One ply row: 1-based number, a mover-colored disc, the dice, and the move text.
/// The caller derives `index` and `mover` from array position + `startingPlayer`
/// (neither is stored in `PlyRecord`, which is the persistence format).
private struct HistoryRow: View {
    let index: Int
    let mover: TavliEngine.Color
    let ply: PlyRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index).")
                .font(ChromeType.callout.monospacedDigit())
                .foregroundStyle(ChromeKit.inkSecondary)
                .frame(width: 48, alignment: .trailing)
            Circle()
                .fill(ChromeTheme.checkerColor(mover))
                .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.35), lineWidth: 1))
                .frame(width: 18, height: 18)
            Text("d=\(ply.die1) \(ply.die2)")
                .font(ChromeType.callout.monospaced())
                .foregroundStyle(ChromeKit.inkSecondary)
                .frame(width: 78, alignment: .leading)
            Text(moveText)
                .font(ChromeType.callout.monospaced())
                .foregroundStyle(ply.halfMoves.isEmpty ? ChromeKit.inkSecondary : ChromeTheme.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    private var moveText: String {
        guard !ply.halfMoves.isEmpty else { return "(pass)" }
        return ply.halfMoves.map { pair in
            guard pair.count == 2 else { return "?" }
            return "\(pair[0])→\(pair[1])"
        }.joined(separator: ", ")
    }
}

/// Centralizes the game chrome's typography (#92). The app targets older players
/// reading at arm's length, so every role sits roughly one step above the SwiftUI
/// text style the chrome originally used. Names mirror the system styles they
/// replace so the hierarchy stays legible; weight/design variants are applied at
/// the use site (`.bold()`, `.monospaced()`), as before. Sizes are fixed —
/// Dynamic Type is a deliberate non-goal for now. Internal, like `ChromeTheme`:
/// the chrome views live in separate files.
enum ChromeType {
    static let title2 = Font.system(size: 26)                       // was .title2 (22)
    static let title3 = Font.system(size: 24)                       // was .title3 (20)
    static let headline = Font.system(size: 22, weight: .semibold)  // was .headline (17)
    static let body = Font.system(size: 20)                         // was .body (17)
    static let callout = Font.system(size: 19)                      // was .callout (16)
    static let subheadline = Font.system(size: 18)                  // was .subheadline (15)
    static let caption = Font.system(size: 16)                      // was .caption (12)
    static let caption2 = Font.system(size: 14)                     // was .caption2 (11)

    // Display faces with bespoke sizes.
    static let winTitle = Font.system(size: 54, weight: .bold, design: .serif)
    static let statsTitle = Font.custom("Cormorant Garamond", size: 38)
    static let wordmark = Font.custom("Cormorant Garamond", size: 96)

    // Debug overlay (developer chrome, but it was 9–10 pt — illegible on device).
    static let debugMono = Font.system(size: 12, design: .monospaced)
    static let debugLabel = Font.system(size: 13)
}

/// Centralizes the engine-`Color` → display mappings (name + checker color) so a
/// future visual style can swap them in one place. Black renders as "Red".
/// Shared with `GameReviewView` (#62), so it stays internal rather than private.
enum ChromeTheme {
    // Explicit `SwiftUI.Color` (not the file-private `SColor` alias) so this
    // internal type — shared with `GameReviewView` — exposes no private type.
    static let ink = SwiftUI.Color(hex: 0x3a2510)            // frame text from the Caramel palette
    static let undoTint = SwiftUI.Color(hex: 0xa87a3e)       // beechwood amber
    static let doneTint = SwiftUI.Color(hex: 0x6a8a4a)       // muted olive-green
    static let surrenderTint = SwiftUI.Color(hex: 0xb05a44)  // muted brick red (resign)

    static func displayName(_ c: TavliEngine.Color) -> String {
        c == .white ? String(localized: "White") : String(localized: "Red")
    }

    static func checkerColor(_ c: TavliEngine.Color) -> SwiftUI.Color {
        c == .white ? SwiftUI.Color(hex: 0xfbeed1)           // ivory (board triangle fill)
                    : SwiftUI.Color(hex: 0xa83a2a)           // caramel-harmonized deep red
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
    session.setManualDice(3, 5)
    if let source = session.selectableSources.sorted().first,
       let target = session.moveBuilder.validDestinations(for: source).sorted().first {
        session.commitHalfMove(from: source, to: target)
    }
    return GameView(session: session)
}

#Preview("History") {
    let session = GameSession(startingPlayer: .white)
    // Script a couple of plies so the log has content.
    session.setManualDice(3, 5)
    if let src = session.selectableSources.sorted().first {
        session.selectPoint(src)
        if let dst = session.validTargets.sorted().first {
            session.commitHalfMove(from: src, to: dst)
        }
    }
    return HistoryView(session: session)
}
