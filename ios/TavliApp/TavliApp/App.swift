import SwiftUI
import TavliEngine

@main
struct TavliApp: App {
    var body: some Scene {
        WindowGroup {
            DiceDemoScreen()
        }
    }
}

/// Temporary harness for T8 (dice view + roll + manual entry). Exercises the
/// real `GameSession` so the dice look and behavior can be signed off before the
/// board and full screen assembly land (T6/T7/T10).
private struct DiceDemoScreen: View {
    @StateObject private var session = GameSession()
    @State private var manualMode = false

    private var felt: some View {
        LinearGradient(
            colors: [SwiftUI.Color(red: 138 / 255, green: 74 / 255, blue: 34 / 255),
                     SwiftUI.Color(red: 106 / 255, green: 54 / 255, blue: 26 / 255)],
            startPoint: .top, endPoint: .bottom
        )
    }

    var body: some View {
        ZStack {
            felt.ignoresSafeArea()

            VStack(spacing: 28) {
                Text("Dice")
                    .font(.custom("Cormorant Garamond", size: 56))
                    .foregroundStyle(.white)

                DiceView(session: session, size: 72)

                Text(phaseLabel)
                    .font(.custom("Inter", size: 16))
                    .foregroundStyle(.white.opacity(0.8))

                Toggle("Manual dice", isOn: $manualMode)
                    .toggleStyle(.switch)
                    .frame(width: 200)
                    .foregroundStyle(.white)

                if manualMode {
                    ManualDiceControl(session: session)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                HStack(spacing: 16) {
                    Button("New turn") { session.newGame() }
                    Button("Play a half-move", action: playOneHalfMove)
                        .disabled(session.selectableSources.isEmpty)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(40)
        }
    }

    private var phaseLabel: String {
        switch session.phase {
        case .awaitingRoll: return "Tap the dice to roll"
        case .picking, .moving: return "Rolled — \(session.legalMoves.count) legal moves"
        case .aiThinking: return "AI thinking…"
        case .animating: return "Animating…"
        case .gameOver(let winner): return "Game over — \(winner) wins"
        }
    }

    /// Commits the first available legal half-move, to visibly grey a consumed die.
    private func playOneHalfMove() {
        guard let from = session.moveBuilder.selectableSourcePoints.sorted().first,
              let to = session.moveBuilder.validDestinations(for: from).sorted().first
        else { return }
        session.commitHalfMove(from: from, to: to)
    }
}
