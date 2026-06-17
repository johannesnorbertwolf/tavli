import SwiftUI
import TavliEngine

/// The ladybug button that shows/hides the eval pane. Off by default. The pane's
/// visibility state lives in `GameView` (#101) so each orientation can place the
/// open pane where it fits: floating under the button in portrait, docked into
/// the side panel flow in landscape (never covering other chrome).
struct DebugToggleButton: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: "ladybug.fill")
                .font(ChromeType.title2)
                .foregroundStyle(isOn ? ChromeTheme.undoTint : ChromeKit.inkSecondary)
                .padding(10)
                .background(ChromeKit.cardColor, in: Circle())
                .shadow(color: ChromeKit.cardShadow, radius: 5, x: 0, y: 2)
        }
        .accessibilityLabel("Toggle debug overlay")
    }
}

/// Read-only panel exposing the AI's evaluation of the current position: WHITE's
/// win probability and the top-3 candidate moves with their 1-ply scores. Binds to
/// a `GameSession` and never mutates gameplay — candidate scoring apply/undoes on
/// the shared board and is only run at a clean turn-start (no committed half-moves).
struct DebugOverlay: View {
    @ObservedObject var session: GameSession
    var onHistory: () -> Void = {}
    /// Fixed pane width when floating (portrait); `nil` fills the container
    /// (the landscape side panel, where the pane docks as a row).
    var width: CGFloat? = 240
    @State private var candidates: [(label: String, score: Float)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEBUG")
                .font(ChromeType.caption2.weight(.bold))
                .kerning(1.2)
                .foregroundStyle(ChromeKit.inkSecondary)

            // Win probability (WHITE's view), straight from the session.
            HStack(spacing: 6) {
                Text("W").font(ChromeType.caption2).foregroundStyle(ChromeKit.inkSecondary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ChromeTheme.ink.opacity(0.12))
                        Capsule()
                            .fill(ChromeTheme.doneTint)
                            .frame(width: geo.size.width * session.winProbability)
                    }
                }
                .frame(height: 8)
                Text(String(format: "%.0f%%", session.winProbability * 100))
                    .font(ChromeType.caption2.monospacedDigit())
                    .foregroundStyle(ChromeTheme.ink)
            }

            Divider()

            Text("Top moves").font(ChromeType.caption2).foregroundStyle(ChromeKit.inkSecondary)
            if candidates.isEmpty {
                Text("—")
                    .font(ChromeType.debugMono)
                    .foregroundStyle(ChromeKit.inkSecondary)
            } else {
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, c in
                    HStack {
                        Text(c.label)
                            .font(ChromeType.debugMono)
                            .foregroundStyle(ChromeTheme.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", c.score * 100))
                            .font(ChromeType.debugMono)
                            .foregroundStyle(ChromeTheme.doneTint)
                    }
                }
            }

            Divider()

            Text("Turn: \(session.currentPlayer.rawValue)  Dice: \(session.game.dice.die1.value),\(session.game.dice.die2.value)")
                .font(ChromeType.debugMono)
                .foregroundStyle(ChromeKit.inkSecondary)

            Divider()

            Button(action: onHistory) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Move history")
                }
                .font(ChromeType.debugLabel)
                .foregroundStyle(ChromeTheme.ink)
            }
            .buttonStyle(.plain)
            Button("↩ Undo decision") { session.undoLastDecision() }
                .font(ChromeType.debugMono.weight(.semibold))
                .foregroundStyle(session.canUndoLastDecision
                                 ? ChromeTheme.undoTint
                                 : ChromeTheme.ink.opacity(0.35))
                .disabled(!session.canUndoLastDecision)
        }
        .padding(12)
        .frame(maxWidth: width ?? .infinity, alignment: .leading)
        .background(ChromeKit.cardColor)
        .cornerRadius(ChromeKit.buttonRadius)
        .shadow(color: ChromeKit.cardShadow, radius: 8, x: 0, y: 3)
        .onAppear { recomputeCandidates() }
        .onChange(of: positionSignature) { recomputeCandidates() }
    }

    /// Score the legal moves with the agent and keep the best three. Guarded to a
    /// clean turn-start so we never apply a full move onto a partially-built
    /// sequence; runs on the main actor alongside the session that owns the board.
    private func recomputeCandidates() {
        guard let agent = session.agent,
              session.moveBuilder.built.isEmpty,
              !session.legalMoves.isEmpty,
              let scores = try? agent.evaluateMoves(session.game.board,
                                                    session.legalMoves,
                                                    color: session.currentPlayer)
        else {
            candidates = []
            return
        }
        candidates = zip(session.legalMoves, scores)
            .map { (label: $0.0.description, score: $0.1) }
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { $0 }
    }

    /// Identifies the current decision point; drives `onChange` recompute.
    private var positionSignature: String {
        "\(session.currentPlayer.rawValue)|\(session.game.dice.die1.value),\(session.game.dice.die2.value)|\(session.legalMoves.count)|\(session.moveBuilder.built.count)|\(session.phase)"
    }
}
