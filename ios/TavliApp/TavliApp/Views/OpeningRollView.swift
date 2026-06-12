import SwiftUI
import BoardGeometry
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// Opening roll ceremony shown between mode picker and game (#33). The board is
/// live; two dice straddle the center bar vertically (AI near the top, human
/// near the bottom). Tap anywhere on the board to roll. Higher die goes first;
/// ties auto-re-roll. On resolution the game starts automatically after 1 s.
/// A manual
/// override is always available in the chrome before the roll resolves.
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
    @State private var started = false

    var body: some View {
        GeometryReader { screen in
            ZStack {
                SColor(hex: 0xece6dc).ignoresSafeArea()

                if screen.size.width >= screen.size.height {
                    landscapeLayout
                } else {
                    portraitLayout
                }
            }
        }
    }

    // MARK: - Layouts

    // Mirrors GameView's panel structure (#101): navigation on top, then the
    // status card with the manual-start choices directly beneath it — nothing
    // floats over the board and nothing is orphaned in a far corner.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            boardArea
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            sidePanel
                .frame(width: 280)
                .padding(.vertical, 12)
                .padding(.trailing, 12)
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 16) {
            ZStack {
                statusBlock
                HStack {
                    backButton
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            manualRow
                .padding(.horizontal, 16)
            Spacer(minLength: 0)
            boardArea
                .padding(.horizontal, 8)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 12)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Back")
            }
        }
        .buttonStyle(ChromeButton(role: .secondary))
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
        let dieSize = geo.diceSize
        // Same horizontal step as the normal two-dice row; doubled vertically so
        // the two dice sit just a bit further apart than they do side-by-side.
        let step = dieSize + 12 * geo.scale
        let aiCenter = CGPoint(x: geo.boardCenter.x, y: geo.boardCenter.y - step)
        let humanCenter = CGPoint(x: geo.boardCenter.x, y: geo.boardCenter.y + step)

        return ZStack {
            // AI die — no highlight
            DieFace(value: aiDieValue, size: dieSize)
                .rotationEffect(.degrees(tumbling ? spin : 0))
                .scaleEffect(tumbling ? 0.9 : 1.0)
                .position(aiCenter)

            // Human die — same gold ring as the game dice use during awaitingRoll
            DieFace(value: humanDieValue, isHighlighted: showHalo, size: dieSize)
                .rotationEffect(.degrees(tumbling ? spin : 0))
                .scaleEffect(tumbling ? 0.9 : 1.0)
                .position(humanCenter)
        }
    }

    // MARK: - Chrome

    private var sidePanel: some View {
        VStack(spacing: 14) {
            HStack {
                backButton
                Spacer(minLength: 0)
            }
            statusBlock
                .frame(maxWidth: .infinity)
                .chromeCard(padding: 16)
            manualRow
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var statusBlock: some View {
        VStack(spacing: 6) {
            Text("Opening Roll")
                .font(ChromeType.headline)
                .foregroundStyle(CaramelPalette.frameText)
            // The roll prompt is the screen's call to action, so it reads at
            // body size in full ink — not as a dimmed caption (#101).
            Text(statusCaption)
                .font(ChromeType.body)
                .foregroundStyle(CaramelPalette.frameText)
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
        if case .resolved = rollState {
            EmptyView()
        } else {
            VStack(spacing: 10) {
                Text("Or choose manually:")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                HStack(spacing: 12) {
                    Button("You start") { startGame(humanColor) }
                        .buttonStyle(ChromeButton(role: .secondary))
                    Button("AI starts") { startGame(humanColor.opponent) }
                        .buttonStyle(ChromeButton(role: .secondary))
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

    private func startGame(_ winner: EngineColor) {
        guard !started else { return }
        started = true
        onStart(winner)
    }

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
                let winner: EngineColor = h > a ? humanColor : humanColor.opponent
                rollState = .resolved(humanDie: h, aiDie: a, winner: winner)
                let delay: Double = 1.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    startGame(winner)
                }
            }
        }
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
