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

    /// Return to the mode picker. Defaults to a no-op so `#Preview`s compile.
    var onBack: () -> Void = {}
    /// Replace the finished session with a fresh one (same settings). Defaults to a no-op so `#Preview`s compile.
    var onNewGame: () -> Void = {}

    /// Drives the move-history sheet (#60).
    @State private var showHistory = false

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            ZStack {
                SColor(hex: 0xece6dc).ignoresSafeArea()

                if landscape {
                    // Board bound to the LEADING edge, filling the height; the chrome
                    // column takes a fixed strip on the trailing edge. The board owns
                    // the leftover width via `frame(maxWidth:)` (flanking it with
                    // `Spacer`s makes the two spacers and the equally-flexible aspect-fit
                    // board split the width three ways, shrinking it to a third) and the
                    // `.leading` alignment pins the square to the left edge, so any slack
                    // between the board and the panel sits on the right and the board
                    // never shifts as the panel chrome changes.
                    HStack(spacing: 0) {
                        PlayableBoardView(session: session)
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        sidePanel
                            .frame(width: 260)
                            .padding(.vertical, 12)
                            .padding(.trailing, 12)
                    }
                } else {
                    // Board bound to the BOTTOM, the turn/counter chrome pinned to the
                    // TOP, and the unavoidable slack (a square can't fill a tall screen)
                    // pooled into the flexible `Spacer` between them. Anchoring the board
                    // to the bottom edge keeps it from shifting as the chrome above it
                    // grows or shrinks — the earlier centered group re-centred on every
                    // turn/phase change (the "Tap dice to roll" caption, the Undo/Done
                    // row), so the board visibly jumped. `layoutPriority(1)` lets the
                    // board claim its full-width square first, so the `Spacer` (not the
                    // board) absorbs the slack; the contextual controls hug it just above.
                    VStack(spacing: 12) {
                        topBar
                            .padding(.horizontal, 16)
                        Spacer(minLength: 0)
                        ControlsView(session: session)
                            .padding(.horizontal, 16)
                        PlayableBoardView(session: session)
                            .padding(.horizontal, 8)
                            .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 12)
                }

                // Floating chrome: Back (top-leading) + debug toggle (top-trailing).
                // The portrait `topBar` keeps its counters centered so these corners
                // stay clear; in landscape the corners overlay the board / panel head.
                BackButton(action: onBack)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                DebugOverlayToggle(session: session, onHistory: { showHistory = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                if case .gameOver(let winner) = session.phase {
                    WinOverlayView(winner: winner, onNewGame: onNewGame,
                                   onHistory: { showHistory = true })
                }
            }
            .sheet(isPresented: $showHistory) {
                HistoryView(session: session)
            }
        }
    }

    // Landscape: turn indicator + counters on top, controls anchored at the bottom.
    // Top-padded so the turn indicator clears the corner Back/debug overlays.
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
        .padding(.top, 44)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // Portrait: counters flank the turn indicator as a centered group, leaving the
    // top corners free for the Back button and debug toggle.
    private var topBar: some View {
        HStack(alignment: .top, spacing: 24) {
            Spacer(minLength: 0)
            BorneOffView(session: session, color: .white)
            TurnIndicatorView(session: session)
            BorneOffView(session: session, color: .black)
            Spacer(minLength: 0)
        }
    }
}

/// Caramel pill that returns to the mode picker.
private struct BackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("Back")
            }
            .font(.callout.bold())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ChromeTheme.undoTint.opacity(0.22))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ChromeTheme.undoTint.opacity(0.6), lineWidth: 1))
            .foregroundStyle(ChromeTheme.ink)
        }
        .buttonStyle(.plain)
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

/// Contextual Undo/Done buttons that appear only when the move builder makes
/// them valid. The dice no longer live here — they sit on the board's center bar
/// (`BoardDiceView`, #46), which frees the side rails.
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
        HStack(spacing: 16) {
            if canUndo {
                Button("Undo") { session.undo() }
                    .buttonStyle(ControlButtonStyle(tint: ChromeTheme.undoTint))
            }
            if canFinish {
                Button("Done") { session.confirm() }
                    .buttonStyle(ControlButtonStyle(tint: ChromeTheme.doneTint))
            }
        }
        .frame(maxWidth: .infinity)
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

/// Dimmed scrim announcing the winner with a Play Again button (plus a History
/// opener, since the scrim covers the in-chrome `HistoryButton`).
private struct WinOverlayView: View {
    let winner: TavliEngine.Color
    let onNewGame: () -> Void
    let onHistory: () -> Void

    var body: some View {
        ZStack {
            SColor.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 24) {
                Text("\(ChromeTheme.displayName(winner)) wins!")
                    .font(.system(size: 48, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Button("Play Again", action: onNewGame)
                    .font(.title3.bold())
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.15))
                    .cornerRadius(14)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.3), lineWidth: 1))
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                Button("History", action: onHistory)
                    .font(.body.bold())
                    .foregroundStyle(.white.opacity(0.85))
                    .buttonStyle(.plain)
            }
        }
    }
}

/// Scrollable ply-by-ply move log (#60), presented as a sheet. Mirrors the CLI
/// `h`/`history` command: one row per ply with its number, mover, dice, and the
/// half-moves played (or "pass"). Binds to the session so a freshly committed
/// move appears immediately, and auto-scrolls to the newest ply.
///
/// `PlyRecord` (the persistence format) stores only dice + half-moves; the 1-based
/// index and mover are derived here from array position and `session.startingPlayer`.
private struct HistoryView: View {
    @ObservedObject var session: GameSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.history.isEmpty {
                Spacer()
                Text("No moves yet")
                    .font(.callout)
                    .foregroundStyle(ChromeTheme.ink.opacity(0.6))
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(session.history.enumerated()), id: \.offset) { offset, ply in
                                let index = offset + 1
                                let mover = index % 2 == 1
                                    ? session.startingPlayer
                                    : session.startingPlayer.opponent
                                HistoryRow(index: index, mover: mover, ply: ply)
                                    .id(offset)
                                Divider().opacity(0.4)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                    .onAppear { scrollToLast(proxy) }
                    .onChange(of: session.history.count) { _, _ in scrollToLast(proxy) }
                }
            }
        }
        .background(SColor(hex: 0xece6dc))
    }

    private var header: some View {
        HStack {
            Text("Move history")
                .font(.title3.bold())
                .foregroundStyle(ChromeTheme.ink)
            Spacer()
            Button("Done") { dismiss() }
                .font(.callout.bold())
                .foregroundStyle(ChromeTheme.ink)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func scrollToLast(_ proxy: ScrollViewProxy) {
        guard !session.history.isEmpty else { return }
        withAnimation { proxy.scrollTo(session.history.count - 1, anchor: .bottom) }
    }
}

/// One ply row: 1-based number, a mover-colored disc, the dice, and the move text.
/// The caller derives `index` and `mover` from array position + `startingPlayer`
/// (neither is stored in `PlyRecord`, which is the persistence format).
private struct HistoryRow: View {
    let index: Int
    let mover: TavliEngine.Color
    let ply: PlyRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(ChromeTheme.ink.opacity(0.5))
                .frame(width: 34, alignment: .trailing)
            Circle()
                .fill(ChromeTheme.checkerColor(mover))
                .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.35), lineWidth: 1))
                .frame(width: 18, height: 18)
            Text("d=\(ply.die1) \(ply.die2)")
                .font(.callout.monospaced())
                .foregroundStyle(ChromeTheme.ink.opacity(0.75))
                .frame(width: 64, alignment: .leading)
            Text(moveText)
                .font(.callout.monospaced())
                .foregroundStyle(ply.halfMoves.isEmpty ? ChromeTheme.ink.opacity(0.5) : ChromeTheme.ink)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var moveText: String {
        guard !ply.halfMoves.isEmpty else { return "(pass)" }
        return ply.halfMoves.map { pair in
            guard pair.count == 2 else { return "?" }
            return "\(pair[0])→\(pair[1])"
        }.joined(separator: ", ")
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

#Preview("History") {
    let session = GameSession(startingPlayer: .white)
    // Script a couple of plies so the log has content.
    session.setManualDice(3, 5)
    if let src = session.selectableSources.sorted().first {
        session.selectPoint(src)
        if let dst = session.validTargets.sorted().first {
            session.commitHalfMove(from: src, to: dst)
        }
    }
    return HistoryView(session: session)
}
