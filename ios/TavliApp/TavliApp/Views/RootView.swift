import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// T10 — app root. Switches between the caramel mode picker and a live game.
///
/// Holds the active `GameSession` in `@State` so the reference stays stable
/// across re-renders; `GameView` observes it. Picking a color builds a fresh
/// human-vs-AI session; Back tears it down and returns to the picker.
struct RootView: View {
    @StateObject private var statsStore = HumanStatsStore()
    @State private var session: GameSession?
    @State private var humanColor: EngineColor = .white

    init() {
        // UI-test hook: start directly in a deterministic human-vs-AI game so the
        // board interaction can be driven without the picker or random dice.
        if ProcessInfo.processInfo.arguments.contains("-uiTestGame") {
            let s = RootView.makeSession(humanColor: .black)  // human (Black) opens
            s.setManualDice(3, 5)
            _session = State(initialValue: s)
            _humanColor = State(initialValue: .black)
        } else {
            _session = State(initialValue: nil)
        }
    }

    var body: some View {
        if let session {
            GameView(session: session, stats: statsStore.stats, onBack: { self.session = nil }) {
                self.session = self.startSession(humanColor: self.humanColor)
            }
        } else {
            ModePickerView(stats: statsStore.stats) { color in
                humanColor = color
                session = self.startSession(humanColor: color)
            }
        }
    }

    /// Build a tracked human-vs-AI session: construct it (`makeSession`) and wire
    /// its game-over callback to record the human's win/loss in `statsStore`.
    private func startSession(humanColor: EngineColor) -> GameSession {
        let session = Self.makeSession(humanColor: humanColor)
        let store = statsStore
        let human = humanColor
        session.onGameOver = { winner in
            store.record(humanWon: winner == human)
        }
        return session
    }

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

/// Caramel start screen: "Tavli" wordmark over two "Play vs AI" choices. The
/// AI-vs-AI watch mode from the design reference is deferred.
private struct ModePickerView: View {
    let stats: HumanGameStats
    let onSelect: (EngineColor) -> Void

    @State private var showStats = false

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            VStack(spacing: 56) {
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
                    ModeButton(title: "My Record", subtitle: recordSubtitle) {
                        showStats = true
                    }
                }
            }
            .padding(40)
        }
        .sheet(isPresented: $showStats) {
            ZStack {
                SColor(hex: 0xece6dc).ignoresSafeArea()
                StatsPanelView(stats: stats)
                    .padding(40)
            }
        }
    }

    private var recordSubtitle: String {
        stats.total == 0
            ? "No games yet"
            : "\(stats.wins)W – \(stats.losses)L"
    }
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
