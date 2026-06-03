import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// T10 — app root. Switches between the caramel mode picker and a live game, and
/// owns save/load (#61): it auto-saves the in-progress game when the app
/// backgrounds, auto-resumes that game on the next cold launch, and lets the
/// player load or delete any saved game from the picker.
///
/// Holds the active `GameSession` in `@State` so the reference stays stable
/// across re-renders; `GameView` observes it. Picking a color builds a fresh
/// human-vs-AI session; Back tears it down and returns to the picker.
struct RootView: View {
    @State private var session: GameSession?
    @State private var humanColor: EngineColor = .white
    /// The current game's display name — a timestamped default ("Game · <date>",
    /// the same convention as a manual save) for a fresh game, or the resumed
    /// game's own name. Written into the auto-save slot on every move (#61).
    @State private var autosaveName: String = ""
    @Environment(\.scenePhase) private var scenePhase

    private let store = SaveStore.default()

    init() {
        // UI-test hook: start directly in a deterministic human-vs-AI game so the
        // board interaction can be driven without the picker or random dice.
        if ProcessInfo.processInfo.arguments.contains("-uiTestGame") {
            let s = RootView.makeSession(humanColor: .black)  // human (Black) opens
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
            if let session {
                GameView(
                    session: session,
                    onBack: {
                        persistAutosave()        // never lose progress on the way out
                        self.session = nil
                    },
                    onNewGame: {
                        autosaveName = Self.newAutosaveName()
                        self.session = Self.makeSession(humanColor: self.humanColor)
                    },
                    onSave: { name in try? store.writeManual(session.snapshot(name: name)) },
                    onAutosave: persistAutosave
                )
            } else {
                ModePickerView(store: store,
                               onSelect: { color in
                                   humanColor = color
                                   autosaveName = Self.newAutosaveName()
                                   session = Self.makeSession(humanColor: color)
                               },
                               onResume: resume)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { persistAutosave() }
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

    /// Load a saved game (from the picker list) and switch into it, carrying its
    /// name forward so the auto-save keeps the same identity.
    private func resume(_ meta: SaveMetadata) {
        guard let save = try? store.load(filename: meta.filename) else { return }
        humanColor = save.aiColor.flatMap { EngineColor(rawValue: $0) }?.opponent ?? .white
        autosaveName = save.name
        let s = GameSession.resume(from: save, agent: GameSession.makeAgent())
        s.start()
        session = s
    }

    /// The auto-save game to resume on launch, if one exists and is still in
    /// progress. A finished auto-save is discarded so launch lands on the picker.
    private static func autoResume() -> (session: GameSession, humanColor: EngineColor, name: String)? {
        let store = SaveStore.default()
        guard let save = store.loadAutosave() else { return nil }
        let s = GameSession.resume(from: save, agent: GameSession.makeAgent())
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
        "Game · " + autosaveNameFormatter.string(from: Date())
    }

    private static let autosaveNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Build a human-vs-AI session. Black always opens for now (the proper
    /// opening-roll rule is a separate ticket); `start()` lets the AI move first
    /// when it owns Black (i.e. the human chose White).
    @MainActor
    private static func makeSession(humanColor: EngineColor) -> GameSession {
        let session = GameSession(
            startingPlayer: .black,
            agent: GameSession.makeAgent(),
            aiColor: humanColor.opponent
        )
        session.start()
        return session
    }
}

/// Caramel start screen: "Tavli" wordmark, two "Play vs AI" choices, and (since
/// #61) a list of saved games to resume or delete. The AI-vs-AI watch mode from
/// the design reference is deferred.
private struct ModePickerView: View {
    let store: SaveStore
    let onSelect: (EngineColor) -> Void
    let onResume: (SaveMetadata) -> Void

    @State private var saves: [SaveMetadata] = []

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            VStack(spacing: 40) {
                Text("Tavli")
                    .font(.custom("Cormorant Garamond", size: 96))
                    .foregroundStyle(CaramelPalette.frameText)

                VStack(spacing: 20) {
                    ModeButton(title: "Play vs AI", subtitle: "You play White") {
                        onSelect(.white)
                    }
                    ModeButton(title: "Play vs AI", subtitle: "You play Black") {
                        onSelect(.black)
                    }
                }

                if !saves.isEmpty {
                    SavedGamesList(saves: saves,
                                   onResume: onResume,
                                   onDelete: delete)
                        .frame(maxWidth: 420)
                }
            }
            .padding(40)
        }
        .onAppear { reload() }
    }

    private func reload() { saves = store.list() }

    private func delete(_ meta: SaveMetadata) {
        try? store.delete(filename: meta.filename)
        reload()
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
                .font(.headline)
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
                        .font(.title3)
                        .foregroundStyle(CaramelPalette.frameText.opacity(0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        if meta.isAutosave {
                            // The auto-save's own name follows the manual convention;
                            // this badge sits on top of it to mark the last game (#61).
                            Text("Continue last game")
                                .font(.caption2.weight(.bold))
                                .textCase(.uppercase)
                                .foregroundStyle(CaramelPalette.frameText.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(CaramelPalette.frameText.opacity(0.12))
                                .clipShape(Capsule())
                                .padding(.bottom, 2)
                        }
                        Text(meta.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(CaramelPalette.frameText)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(CaramelPalette.frameText.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(CaramelPalette.frameText.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SColor.white.opacity(0.35))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(CaramelPalette.frameBot.opacity(0.4), lineWidth: 1))
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

/// A caramel wood pill matching the board frame palette.
private struct ModeButton: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.callout).opacity(0.75)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 48)
            .padding(.vertical, 18)
            .foregroundStyle(CaramelPalette.frameText)
        }
        .buttonStyle(ModeButtonStyle())
    }
}

private struct ModeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                LinearGradient(
                    colors: [CaramelPalette.frameTop, CaramelPalette.frameMid],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(CaramelPalette.frameBot, lineWidth: 1.5)
            )
            .brightness(configuration.isPressed ? -0.05 : 0)
    }
}

#Preview {
    RootView()
}
