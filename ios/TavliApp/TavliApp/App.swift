import SwiftUI
import TavliEngine

@main
struct TavliApp: App {
    var body: some Scene {
        WindowGroup {
            DebugDemoView()
        }
    }
}

/// Temporary host so T11's debug overlay is exercisable before the real screen
/// (T10) exists. The AI plays BLACK and moves first (updating `winProbability`);
/// the human is WHITE and uses Roll to surface candidate scores for their turn.
/// This whole view is throwaway — T10's screen assembly replaces it.
private struct DebugDemoView: View {
    @StateObject private var session = GameSession(
        startingPlayer: .black,
        agent: GameSession.makeAgent(),
        aiColor: .black
    )

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.12, blue: 0.14).ignoresSafeArea()

            VStack(spacing: 24) {
                Text("Plakoto")
                    .font(.custom("Cormorant Garamond", size: 72))
                    .foregroundStyle(.white)

                Text(phaseLabel)
                    .font(.custom("Inter", size: 18))
                    .foregroundStyle(.white.opacity(0.7))

                HStack(spacing: 16) {
                    Button("Roll") { session.roll() }
                        .disabled(session.phase != .awaitingRoll)
                    Button("New Game") { session.newGame() }
                }
                .font(.custom("Inter", size: 18))
                .buttonStyle(.borderedProminent)
            }

            VStack {
                HStack {
                    Spacer()
                    DebugOverlayToggle(session: session)
                }
                Spacer()
            }
            .padding(20)
        }
        .onAppear { session.start() }
    }

    private var phaseLabel: String {
        switch session.phase {
        case .awaitingRoll: return "Your turn — tap Roll (you are WHITE)"
        case .picking, .moving: return "Rolled \(session.game.dice.die1.value),\(session.game.dice.die2.value) — see candidates"
        case .aiThinking: return "AI thinking…"
        case .animating: return "…"
        case .gameOver(let winner): return "Game over — \(winner.rawValue) wins"
        }
    }
}
