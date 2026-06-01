import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// Pre-game opening roll ceremony. Each side rolls one die; higher goes first.
/// Ties auto-re-roll. The player may also force a manual choice. Calls `onStart`
/// with the resolved starting player, or `onBack` to return to the mode picker.
struct OpeningRollView: View {
    let humanColor: EngineColor
    let onStart: (EngineColor) -> Void
    let onBack: () -> Void

    private enum RollState {
        case idle
        case rolling
        case tied(Int, Int)
        case resolved(humanDie: Int, aiDie: Int, winner: EngineColor)
    }

    @State private var rollState: RollState = .idle
    @State private var tumbling = false
    @State private var spin: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            SColor(hex: 0xece6dc).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 8) {
                    Text("Opening Roll")
                        .font(.custom("Cormorant Garamond", size: 72))
                        .foregroundStyle(CaramelPalette.frameText)
                    Text("Higher die goes first")
                        .font(.callout)
                        .foregroundStyle(CaramelPalette.frameText.opacity(0.65))
                }

                Spacer().frame(height: 48)

                HStack(spacing: 56) {
                    dieColumn(label: "You", value: humanDieValue)
                    dieColumn(label: "AI", value: aiDieValue)
                }
                .rotationEffect(.degrees(tumbling ? spin : 0))
                .scaleEffect(tumbling ? 0.9 : 1.0)

                Spacer().frame(height: 32)

                statusText
                    .frame(height: 44)

                Spacer().frame(height: 32)

                primaryButton

                Spacer().frame(height: 32)

                VStack(spacing: 12) {
                    Text("Or choose manually:")
                        .font(.callout)
                        .foregroundStyle(CaramelPalette.frameText.opacity(0.55))
                    HStack(spacing: 16) {
                        ORButton("You start") { onStart(humanColor) }
                        ORButton("AI starts") { onStart(humanColor.opponent) }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 40)

            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.callout.bold())
                .foregroundStyle(CaramelPalette.frameText)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [CaramelPalette.frameTop, CaramelPalette.frameMid],
                                   startPoint: .top, endPoint: .bottom)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(CaramelPalette.frameBot, lineWidth: 1.5))
            }
            .padding(20)
        }
    }

    // MARK: - Subviews

    private func dieColumn(label: String, value: Int) -> some View {
        VStack(spacing: 12) {
            Text(label)
                .font(.callout)
                .foregroundStyle(CaramelPalette.frameText.opacity(0.75))
            DieFace(value: value, size: 80)
            Text(value > 0 ? "\(value)" : "—")
                .font(.title3.bold())
                .foregroundStyle(CaramelPalette.frameText.opacity(value > 0 ? 1.0 : 0.4))
                .frame(height: 28)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch rollState {
        case .idle:
            Text("Roll to decide who goes first")
                .font(.callout)
                .foregroundStyle(CaramelPalette.frameText.opacity(0.65))
        case .rolling:
            Text("Rolling…")
                .font(.callout)
                .foregroundStyle(CaramelPalette.frameText.opacity(0.65))
        case .tied(let h, let a):
            Text("Tie (\(h) vs \(a)) — rolling again…")
                .font(.callout)
                .foregroundStyle(CaramelPalette.frameText.opacity(0.65))
        case .resolved(_, _, let winner):
            Text(winner == humanColor ? "You go first!" : "AI goes first!")
                .font(.title2.bold())
                .foregroundStyle(CaramelPalette.frameText)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch rollState {
        case .idle:
            ORButton("Roll") { startRoll() }
        case .rolling:
            ORButton("Rolling…", enabled: false) { }
        case .tied:
            ORButton("Roll Again") { startRoll() }
        case .resolved(_, _, let winner):
            ORButton("Start Game") { onStart(winner) }
        }
    }

    // MARK: - Computed helpers

    private var humanDieValue: Int {
        switch rollState {
        case .idle, .rolling: return 0
        case .tied(let h, _): return h
        case .resolved(let h, _, _): return h
        }
    }

    private var aiDieValue: Int {
        switch rollState {
        case .idle, .rolling: return 0
        case .tied(_, let a): return a
        case .resolved(_, let a, _): return a
        }
    }

    // MARK: - Roll logic

    private func startRoll() {
        guard !tumbling else { return }
        rollState = .rolling
        withAnimation(.easeInOut(duration: 0.09).repeatCount(4, autoreverses: false)) {
            spin += 360
            tumbling = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            tumbling = false
            let h = Int.random(in: 1...6)
            let a = Int.random(in: 1...6)
            if h == a {
                rollState = .tied(h, a)
                // Auto re-roll unless the user already intervened (state changed)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if case .tied = rollState { startRoll() }
                }
            } else {
                rollState = .resolved(humanDie: h, aiDie: a,
                                      winner: h > a ? humanColor : humanColor.opponent)
            }
        }
    }
}

// MARK: - Button

private struct ORButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.title3.bold())
                .frame(maxWidth: 240)
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                .foregroundStyle(CaramelPalette.frameText)
        }
        .buttonStyle(ORButtonStyle())
        .disabled(!enabled)
    }
}

private struct ORButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                LinearGradient(colors: [CaramelPalette.frameTop, CaramelPalette.frameMid],
                               startPoint: .top, endPoint: .bottom)
            )
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(CaramelPalette.frameBot, lineWidth: 1.5))
            .brightness(configuration.isPressed ? -0.05 : 0)
            .opacity(enabled ? 1.0 : 0.6)
    }

    @Environment(\.isEnabled) private var enabled
}

// MARK: - Preview

#Preview("Opening Roll — idle") {
    OpeningRollView(humanColor: .white, onStart: { _ in }, onBack: { })
}

#Preview("Opening Roll — human Black") {
    OpeningRollView(humanColor: .black, onStart: { _ in }, onBack: { })
}
