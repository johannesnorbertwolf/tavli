import SwiftUI
import BoardGeometry
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// Opening roll ceremony shown between mode picker and game (#33). The board is
/// live; two dice straddle the center bar vertically (AI near the top, human
/// near the bottom). Tap anywhere on the board to roll. Higher die goes first;
/// ties auto-re-roll. A manual override is always available in the chrome.
struct OpeningRollView: View {
    let humanColor: TavliEngine.Color
    let onStart: (TavliEngine.Color) -> Void
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
        GeometryReader { screen in
            ZStack {
                SColor(hex: 0xece6dc).ignoresSafeArea()

                if screen.size.width >= screen.size.height {
                    landscapeLayout
                } else {
                    portraitLayout
                }

                // Floating Back button — same pill style as GameView.
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.callout.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(SColor(hex: 0xa87a3e).opacity(0.22))
                    .cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(SColor(hex: 0xa87a3e).opacity(0.6), lineWidth: 1))
                    .foregroundStyle(CaramelPalette.frameText)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
        }
    }

    // MARK: - Layouts

    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            boardArea
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            sidePanel
                .frame(width: 260)
                .padding(.vertical, 12)
                .padding(.trailing, 12)
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 12) {
            statusBlock
                .padding(.horizontal, 16)
            Spacer(minLength: 0)
            manualRow
                .padding(.horizontal, 16)
            boardArea
                .padding(.horizontal, 8)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Board

    private var boardArea: some View {
        ZStack {
            BoardView()
            GeometryReader { proxy in
                openingDice(in: proxy.size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { startRoll() }
    }

    private func openingDice(in size: CGSize) -> some View {
        let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size))
        let dieSize = geo.diceSize * 1.3
        let aiCenter = CGPoint(x: geo.barTop.x,
                               y: geo.barTop.y + dieSize / 2 + 4 * geo.scale)
        let humanCenter = CGPoint(x: geo.barBottom.x,
                                  y: geo.barBottom.y - dieSize / 2 - 4 * geo.scale)

        return ZStack {
            // AI die — no halo
            DieFace(value: aiDieValue, size: dieSize)
                .rotationEffect(.degrees(tumbling ? spin : 0))
                .scaleEffect(tumbling ? 0.9 : 1.0)
                .position(aiCenter)

            // Human die — gold halo ring pulses while awaiting roll
            ZStack {
                if showHalo {
                    HaloRing(dieSize: dieSize)
                }
                DieFace(value: humanDieValue, size: dieSize)
                    .rotationEffect(.degrees(tumbling ? spin : 0))
                    .scaleEffect(tumbling ? 0.9 : 1.0)
            }
            .position(humanCenter)
        }
    }

    // MARK: - Chrome

    private var sidePanel: some View {
        VStack(spacing: 24) {
            statusBlock
            Spacer(minLength: 0)
            manualRow
        }
        .padding(.top, 44)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusBlock: some View {
        VStack(spacing: 4) {
            Text("Opening Roll")
                .font(.headline)
                .foregroundStyle(CaramelPalette.frameText)
            Text(statusCaption)
                .font(.caption)
                .foregroundStyle(CaramelPalette.frameText.opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private var statusCaption: String {
        switch rollState {
        case .idle:                     return "Tap the board to roll"
        case .rolling:                  return "Rolling…"
        case .tied(let h, let a):       return "Tie (\(h) vs \(a)) — rolling again…"
        case .resolved(_, _, let w):    return w == humanColor ? "You go first!" : "AI goes first!"
        }
    }

    @ViewBuilder
    private var manualRow: some View {
        if case .resolved(_, _, let winner) = rollState {
            Button("Start Game") { onStart(winner) }
                .buttonStyle(ORButton(tint: SColor(hex: 0x6a8a4a)))
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 8) {
                Text("Or choose manually:")
                    .font(.caption)
                    .foregroundStyle(CaramelPalette.frameText.opacity(0.5))
                HStack(spacing: 12) {
                    Button("You start") { onStart(humanColor) }
                        .buttonStyle(ORButton(tint: SColor(hex: 0xa87a3e)))
                    Button("AI starts") { onStart(humanColor.opponent) }
                        .buttonStyle(ORButton(tint: SColor(hex: 0xa87a3e)))
                }
            }
        }
    }

    // MARK: - State helpers

    private var aiDieValue: Int {
        switch rollState {
        case .idle, .rolling:           return 0
        case .tied(_, let a):           return a
        case .resolved(_, let a, _):    return a
        }
    }

    private var humanDieValue: Int {
        switch rollState {
        case .idle, .rolling:           return 0
        case .tied(let h, _):           return h
        case .resolved(let h, _, _):    return h
        }
    }

    private var showHalo: Bool {
        switch rollState {
        case .idle, .tied:              return true
        case .rolling, .resolved:       return false
        }
    }

    // MARK: - Roll logic

    private func startRoll() {
        guard !tumbling else { return }
        if case .resolved = rollState { return }
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

// MARK: - Pulsing halo ring

/// A self-contained pulsing amber ring that encircles the human die. Owns its
/// own `@State` so the opacity animation restarts cleanly every time the view
/// appears.
private struct HaloRing: View {
    let dieSize: CGFloat
    @State private var opacity: Double = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: dieSize * 0.107 + 3, style: .continuous)
            .stroke(CaramelPalette.hl, lineWidth: 3)
            .frame(width: dieSize + 10, height: dieSize + 10)
            .shadow(color: CaramelPalette.hl.opacity(0.55), radius: 8, x: 0, y: 0)
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    opacity = 0.3
                }
            }
    }
}

// MARK: - Button style matching GameView chrome

private struct ORButton: ButtonStyle {
    let tint: SColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.bold())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(tint.opacity(configuration.isPressed ? 0.45 : 0.22))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.6), lineWidth: 1))
            .foregroundStyle(CaramelPalette.frameText)
    }
}

// MARK: - Previews

#Preview("Opening Roll — idle") {
    OpeningRollView(humanColor: .white, onStart: { _ in }, onBack: { })
}

#Preview("Opening Roll — landscape") {
    OpeningRollView(humanColor: .black, onStart: { _ in }, onBack: { })
        .previewInterfaceOrientation(.landscapeLeft)
}
