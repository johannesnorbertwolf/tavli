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
    @State private var session: GameSession?
    @State private var humanColor: EngineColor = .white
    @State private var pendingHumanColor: EngineColor?

    init() {
        // UI-test hook: start directly in a deterministic human-vs-AI game so the
        // board interaction can be driven without the picker or random dice.
        if ProcessInfo.processInfo.arguments.contains("-uiTestGame") {
            let s = RootView.makeSession(humanColor: .black, startingPlayer: .black)
            s.setManualDice(3, 5)
            _session = State(initialValue: s)
            _humanColor = State(initialValue: .black)
        } else {
            _session = State(initialValue: nil)
        }
    }

    var body: some View {
        if let session {
            GameView(session: session, onBack: { self.session = nil }) {
                // "Play Again" returns to the opening roll so every game picks a starter.
                self.session = nil
                self.pendingHumanColor = self.humanColor
            }
        } else if let pending = pendingHumanColor {
            OpeningRollView(humanColor: pending) { startingPlayer in
                humanColor = pending
                pendingHumanColor = nil
                session = Self.makeSession(humanColor: pending, startingPlayer: startingPlayer)
            } onBack: {
                pendingHumanColor = nil
            }
        } else {
            ModePickerView { color in
                pendingHumanColor = color
            }
        }
    }

    @MainActor
    private static func makeSession(humanColor: EngineColor, startingPlayer: EngineColor) -> GameSession {
        let session = GameSession(
            startingPlayer: startingPlayer,
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
    let onSelect: (EngineColor) -> Void

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
                }
            }
            .padding(40)
        }
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
