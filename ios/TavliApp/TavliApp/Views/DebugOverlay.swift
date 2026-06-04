import SwiftUI
import TavliEngine

/// Bug-icon toggle plus the eval panel. Off by default. Drop onto any screen as a
/// top-trailing overlay (the game screen in T10 will host it).
struct DebugOverlayToggle: View {
    @ObservedObject var session: GameSession
    @State private var isOn = false
    var onHistory: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button { isOn.toggle() } label: {
                Image(systemName: "ladybug.fill")
                    .font(.title2)
                    .foregroundStyle(isOn ? .yellow : .white.opacity(0.5))
                    .padding(8)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .accessibilityLabel("Toggle debug overlay")

            if isOn {
                DebugOverlay(session: session, onHistory: onHistory)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isOn)
    }
}

/// Read-only panel exposing the AI's evaluation of the current position: WHITE's
/// win probability and the top-3 candidate moves with their 1-ply scores. Binds to
/// a `GameSession` and never mutates gameplay — candidate scoring apply/undoes on
/// the shared board and is only run at a clean turn-start (no committed half-moves).
struct DebugOverlay: View {
    @ObservedObject var session: GameSession
    var onHistory: () -> Void = {}
    @State private var candidates: [(label: String, score: Float)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debug").font(.caption.bold()).foregroundStyle(.yellow)

            // Win probability (WHITE's view), straight from the session.
            HStack(spacing: 6) {
                Text("W").font(.caption2).foregroundStyle(.white.opacity(0.7))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.black.opacity(0.5))
                        Capsule()
                            .fill(Color.yellow.opacity(0.8))
                            .frame(width: geo.size.width * session.winProbability)
                    }
                }
                .frame(height: 8)
                Text(String(format: "%.0f%%", session.winProbability * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
            }

            Divider().background(Color.white.opacity(0.2))

            Text("Top moves").font(.caption2).foregroundStyle(.white.opacity(0.7))
            if candidates.isEmpty {
                Text("—")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, c in
                    HStack {
                        Text(c.label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f%%", c.score * 100))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.9))
                    }
                }
            }

            Divider().background(Color.white.opacity(0.2))

            Text("Turn: \(session.currentPlayer.rawValue)  Dice: \(session.game.dice.die1.value),\(session.game.dice.die2.value)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))

            Divider().background(Color.white.opacity(0.2))

            Button(action: onHistory) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Move history")
                }
                .font(.system(size: 10, design: .default))
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 200, alignment: .leading)
        .background(.black.opacity(0.75))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15), lineWidth: 1))
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
