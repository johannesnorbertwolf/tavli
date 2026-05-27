import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// T9 — Game chrome. Assembles the static `BoardView` with the non-board UI
/// (turn/phase indicator, borne-off counters, contextual Undo/Done, dice, win
/// overlay) into a responsive layout bound to a `GameSession`. No game logic
/// lives here — every sub-view binds to the session's published read-state and
/// calls its intents. Board interactivity (T4/T7) is a separate ticket, so the
/// board itself stays visually static.
struct GameView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            ZStack {
                SColor(hex: 0xece6dc).ignoresSafeArea()

                if landscape {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        BoardView()
                            .aspectRatio(1, contentMode: .fit)
                            .padding(24)
                        Spacer(minLength: 0)
                        sidePanel
                            .frame(width: 300)
                            .padding(.vertical, 24)
                            .padding(.trailing, 24)
                    }
                } else {
                    VStack(spacing: 0) {
                        topBar
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                        Spacer(minLength: 0)
                        BoardView()
                            .aspectRatio(1, contentMode: .fit)
                            .padding(.horizontal, 24)
                        Spacer(minLength: 0)
                        ControlsView(session: session)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }
                }

                if case .gameOver(let winner) = session.phase {
                    WinOverlayView(winner: winner) { session.newGame() }
                }
            }
        }
    }

    // Landscape: turn indicator + counters on top, controls anchored at the bottom.
    private var sidePanel: some View {
        VStack(spacing: 24) {
            TurnIndicatorView(session: session)
            HStack(spacing: 24) {
                BorneOffView(session: session, color: .white)
                BorneOffView(session: session, color: .black)
            }
            Spacer(minLength: 0)
            ControlsView(session: session)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // Portrait: counters flank the turn indicator across the top.
    private var topBar: some View {
        HStack(alignment: .top) {
            BorneOffView(session: session, color: .white)
            Spacer()
            TurnIndicatorView(session: session)
            Spacer()
            BorneOffView(session: session, color: .black)
        }
    }
}

// ── Sub-views ───────────────────────────────────────────────────────────────

/// Reflects the current turn phase. Binds to `session.phase` and
/// `session.currentPlayer`.
private struct TurnIndicatorView: View {
    @ObservedObject var session: GameSession

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.headline)
                .foregroundStyle(ChromeTheme.ink)
                .multilineTextAlignment(.center)
            if case .awaitingRoll = session.phase {
                Text("Tap dice to roll")
                    .font(.caption)
                    .foregroundStyle(ChromeTheme.ink.opacity(0.6))
            }
        }
    }

    private var label: String {
        let name = ChromeTheme.displayName(session.currentPlayer)
        switch session.phase {
        case .awaitingRoll:      return "\(name)'s turn"
        case .picking:           return "Pick a checker"
        case .moving:            return "Choose destination"
        case .aiThinking:        return "AI thinking…"
        case .animating:         return "\(name) moving…"
        case .gameOver(let w):   return "\(ChromeTheme.displayName(w)) wins!"
        }
    }
}

/// One side's borne-off count: a checker-colored disc, the count, and a label.
/// Reads the count straight off the board on each session publish.
private struct BorneOffView: View {
    @ObservedObject var session: GameSession
    let color: TavliEngine.Color

    private var count: Int {
        let board = session.game.board
        return color == .white
            ? board.points[board.boardSize + 1].count
            : board.points[0].count
    }

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(ChromeTheme.checkerColor(color))
                .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.35), lineWidth: 1))
                .frame(width: 28, height: 28)
            Text("\(count)")
                .font(.caption.bold())
                .foregroundStyle(ChromeTheme.ink)
            Text(ChromeTheme.displayName(color))
                .font(.caption2)
                .foregroundStyle(ChromeTheme.ink.opacity(0.6))
        }
    }
}

/// Dice (tap-to-roll, existing `DiceView`) plus contextual Undo/Done buttons
/// that appear only when the move builder makes them valid.
private struct ControlsView: View {
    @ObservedObject var session: GameSession

    private var isHumanPicking: Bool {
        session.phase == .picking || session.phase == .moving
    }
    private var canUndo: Bool {
        isHumanPicking && !session.moveBuilder.built.isEmpty
    }
    private var canFinish: Bool {
        isHumanPicking && session.moveBuilder.canFinishNow && !session.moveBuilder.built.isEmpty
    }

    var body: some View {
        HStack(spacing: 20) {
            DiceView(session: session)
            Spacer(minLength: 0)
            if canUndo {
                Button("Undo") { session.undo() }
                    .buttonStyle(ControlButtonStyle(tint: ChromeTheme.undoTint))
            }
            if canFinish {
                Button("Done") { session.confirm() }
                    .buttonStyle(ControlButtonStyle(tint: ChromeTheme.doneTint))
            }
        }
    }
}

/// Pill button tinted to the palette; adapted from the reference GameView.
private struct ControlButtonStyle: ButtonStyle {
    let tint: SColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.bold())
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(tint.opacity(configuration.isPressed ? 0.45 : 0.22))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.6), lineWidth: 1))
            .foregroundStyle(ChromeTheme.ink)
    }
}

/// Dimmed scrim announcing the winner with a New Game button.
private struct WinOverlayView: View {
    let winner: TavliEngine.Color
    let onNewGame: () -> Void

    var body: some View {
        ZStack {
            SColor.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 24) {
                Text("\(ChromeTheme.displayName(winner)) wins!")
                    .font(.system(size: 48, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Button("New Game", action: onNewGame)
                    .font(.title3.bold())
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.15))
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.3), lineWidth: 1))
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
            }
        }
    }
}

/// Centralizes the engine-`Color` → display mappings (name + checker color) so a
/// future visual style can swap them in one place. Black renders as "Red".
private enum ChromeTheme {
    static let ink = SColor(hex: 0x3a2510)            // frame text from the Caramel palette
    static let undoTint = SColor(hex: 0xa87a3e)       // beechwood amber
    static let doneTint = SColor(hex: 0x6a8a4a)       // muted olive-green

    static func displayName(_ c: TavliEngine.Color) -> String {
        c == .white ? "White" : "Red"
    }

    static func checkerColor(_ c: TavliEngine.Color) -> SColor {
        c == .white ? SColor(hex: 0xfbeed1)           // ivory (board triangle fill)
                    : SColor(hex: 0xa83a2a)           // caramel-harmonized deep red
    }
}

// MARK: - Previews

#Preview("Landscape") {
    GameView(session: GameSession())
        .previewInterfaceOrientation(.landscapeLeft)
}

#Preview("Portrait") {
    GameView(session: GameSession())
}

#Preview("Undo/Done") {
    let session = GameSession()
    session.setManualDice(3, 5)
    if let source = session.selectableSources.sorted().first,
       let target = session.moveBuilder.validDestinations(for: source).sorted().first {
        session.commitHalfMove(from: source, to: target)
    }
    return GameView(session: session)
        .previewInterfaceOrientation(.landscapeLeft)
}
