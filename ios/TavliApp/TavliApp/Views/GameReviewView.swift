import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// #62 — post-game blunder review, the iPad analogue of the CLI's `review`
/// command. A **full-screen, board-centric** mode (one blunder at a time): the
/// position the player faced fills the screen, with a panel showing what was
/// played vs the AI's best and the win-probability gap, and Prev/Next (or swipe)
/// to page through the blunders. Blunders **stream in** as they're found, so the
/// first one shows immediately while the rest analyze in the background.
///
/// The threshold is fixed at 10% for now; a configurable one is tracked in #77.
/// Pure presentation — all analysis lives in `TavliEngine`.
struct GameReviewView: View {
    let record: GameRecord
    let agent: Agent?
    let humanColor: TavliEngine.Color

    @StateObject private var model: GameReviewModel
    @Environment(\.dismiss) private var dismiss

    /// Index of the blunder currently shown (clamped to the streamed set).
    @State private var index = 0
    /// Which move, if any, is highlighted on the board.
    @State private var overlay: MoveOverlay = .best
    /// Drives the drill, launched full-screen from the review (#63).
    @State private var showDrill = false

    enum MoveOverlay: Hashable { case none, your, best }

    init(record: GameRecord, agent: Agent?, humanColor: TavliEngine.Color) {
        self.record = record
        self.agent = agent
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: GameReviewModel())
    }

    /// Preview-only: seed a terminal phase so `#Preview`s skip analysis.
    fileprivate init(previewPhase: GameReviewModel.Phase, humanColor: TavliEngine.Color = .white) {
        self.record = GameRecord(startingPlayer: .white, aiColor: .black)
        self.agent = nil
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: GameReviewModel(preview: previewPhase))
    }

    private var flipped: Bool { humanColor == .black }

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            content
            // Floating Done, top-leading, clear of the board/panel.
            CloseButton { dismiss() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)
        }
        .task { await model.run(record: record, agent: agent, humanColor: humanColor) }
        .fullScreenCover(isPresented: $showDrill) {
            DrillView(record: record, precomputed: model.result,
                      agent: agent, humanColor: humanColor)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .analyzing(let done, let total):
            centered {
                ProgressView().progressViewStyle(.circular).tint(ChromeTheme.ink)
                Text(total > 0 ? "Analyzing move \(done) of \(total)…" : "Analyzing your moves…")
                    .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
            }
        case .unavailable:
            centered {
                Text("Review needs the AI model, which isn’t available.")
                    .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
            }
        case .noBlunders:
            centered {
                Text("No blunders found — well played!")
                    .font(.title3).foregroundStyle(ChromeTheme.ink.opacity(0.8))
            }
        case .results(let blunders, let finished):
            blunderMode(blunders, finished: finished)
        }
    }

    // ── Board-centric blunder mode ────────────────────────────────────────────

    private func blunderMode(_ blunders: [PlyEvaluation], finished: Bool) -> some View {
        let i = min(index, blunders.count - 1)
        let eval = blunders[i]
        return GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            Group {
                if landscape {
                    HStack(alignment: .top, spacing: 0) {
                        boardArea(eval)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(12)
                        panel(eval: eval, i: i, count: blunders.count, finished: finished)
                            .frame(width: 320)
                            .padding(.top, 56)   // clear the floating Close button
                            .padding(.trailing, 16)
                    }
                } else {
                    VStack(spacing: 12) {
                        panel(eval: eval, i: i, count: blunders.count, finished: finished)
                            .padding(.horizontal, 20)
                            .padding(.top, 56)   // clear the floating Done button
                        boardArea(eval)
                            .padding(.horizontal, 12)
                            .layoutPriority(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(pagingGesture(count: blunders.count, current: i))
        }
    }

    /// The full board at the blunder position, optionally overlaying a move.
    private func boardArea(_ eval: PlyEvaluation) -> some View {
        ZStack {
            BoardView(flipped: flipped)
            CheckersView(stacks: eval.boardStacks, flipped: flipped)
            if overlay != .none {
                let move = overlay == .your ? eval.playedMove : eval.bestMove
                TargetHighlightView(targets: targets(of: move), style: .frame, flipped: flipped)
                    .allowsHitTesting(false)
                SourceRingView(selectedPoint: move.first?.first, stacks: eval.boardStacks, flipped: flipped)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func panel(eval: PlyEvaluation, i: Int, count: Int, finished: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // Progress + dice.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Blunder \(i + 1) of \(count)")
                        .font(.title3.bold())
                        .foregroundStyle(ChromeTheme.ink)
                    if !finished {
                        ProgressView().controlSize(.small)
                    }
                }
                Text("Dice \(eval.die1) · \(eval.die2)")
                    .font(.callout.monospaced())
                    .foregroundStyle(ChromeTheme.ink.opacity(0.6))
            }

            // Played vs best, with the win-prob gap.
            VStack(alignment: .leading, spacing: 10) {
                moveLine(label: "You played", move: eval.playedMove,
                         pct: Double(eval.playedScore), tint: ChromeTheme.ink)
                moveLine(label: "Best move", move: eval.bestMove,
                         pct: Double(eval.bestScore), tint: ReviewTint.best)
                Text("−\(percent(eval.absoluteGap)) win chance")
                    .font(.callout.bold())
                    .foregroundStyle(ReviewTint.gap)
            }

            // Highlight selector — what to draw on the board.
            Picker("Show on board", selection: $overlay) {
                Text("Best").tag(MoveOverlay.best)
                Text("Yours").tag(MoveOverlay.your)
                Text("None").tag(MoveOverlay.none)
            }
            .pickerStyle(.segmented)

            // Navigation + drill.
            HStack(spacing: 12) {
                Button { index = max(0, i - 1) } label: { Label("Prev", systemImage: "chevron.left") }
                    .buttonStyle(ReviewButton(tint: ChromeTheme.undoTint))
                    .disabled(i == 0).opacity(i == 0 ? 0.4 : 1)
                Button { index = min(count - 1, i + 1) } label: { Label("Next", systemImage: "chevron.right") }
                    .buttonStyle(ReviewButton(tint: ChromeTheme.undoTint))
                    .disabled(i >= count - 1).opacity(i >= count - 1 ? 0.4 : 1)
            }
            Button("Drill these") { showDrill = true }
                .buttonStyle(ReviewButton(tint: ChromeTheme.doneTint))
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moveLine(label: String, move: [[Int]], pct: Double, tint: SColor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(ChromeTheme.ink.opacity(0.55))
            HStack(spacing: 8) {
                Text(moveText(move)).font(.body.monospaced().bold()).foregroundStyle(tint)
                Text("\(percent(pct))").font(.caption.monospacedDigit()).foregroundStyle(ChromeTheme.ink.opacity(0.55))
            }
        }
    }

    /// Left/right swipe pages between blunders.
    private func pagingGesture(count: Int, current i: Int) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < 0 { index = min(count - 1, i + 1) }
                else { index = max(0, i - 1) }
            }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Formatting ────────────────────────────────────────────────────────────

    private func targets(of move: [[Int]]) -> Set<Int> {
        Set(move.compactMap { $0.count == 2 ? $0[1] : nil })
    }
    private func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }
    private func moveText(_ pairs: [[Int]]) -> String {
        guard !pairs.isEmpty else { return "(pass)" }
        return pairs.map { $0.count == 2 ? "\($0[0])→\($0[1])" : "?" }.joined(separator: ", ")
    }
}

// ── Controller (streaming) ────────────────────────────────────────────────────

/// Drives `GameReview.analyze` off the main actor and **streams** its blunders back:
/// each blunder appears as soon as it's found, so the first one shows immediately
/// while the rest are still being analyzed in the background. `@MainActor` so its
/// published state mutates safely; the background task hops back here per event.
@MainActor
final class GameReviewModel: ObservableObject {
    enum Phase {
        case analyzing(done: Int, total: Int)        // before the first blunder
        case results(blunders: [PlyEvaluation], finished: Bool)
        case noBlunders                              // finished, none found
        case unavailable
    }

    @Published var phase: Phase = .analyzing(done: 0, total: 0)

    /// `play/loop.py` default — flag moves ≥10% worse than the best.
    private let threshold = 0.10
    private var blunders: [PlyEvaluation] = []
    private var started = false
    private var finished = false

    /// The blunders found so far, as a result the drill can consume directly.
    var result: GameReviewResult { GameReviewResult(evaluations: blunders) }

    init() {}

    /// Preview-only: start in a terminal phase so analysis never runs.
    fileprivate init(preview phase: Phase) {
        self.phase = phase
        self.started = true
        self.finished = true
        if case .results(let b, _) = phase { self.blunders = b }
    }

    func run(record: GameRecord, agent: Agent?, humanColor: TavliEngine.Color) async {
        guard !started else { return }   // `.task` can re-fire; analyze once
        started = true

        guard let agent else { phase = .unavailable; return }

        let result = await Task.detached(priority: .userInitiated) { [weak self] in
            GameReview.analyze(
                record: record, agent: agent, humanColor: humanColor,
                onEvaluation: { eval in Task { @MainActor in self?.ingest(eval) } },
                progress: { done, total in Task { @MainActor in self?.report(done: done, total: total) } }
            )
        }.value

        finish(with: result)
    }

    /// A streamed evaluation: show it immediately if it's a blunder.
    private func ingest(_ eval: PlyEvaluation) {
        guard !finished, eval.isBlunder(threshold: threshold) else { return }
        blunders.append(eval)
        phase = .results(blunders: blunders, finished: false)
    }

    private func report(done: Int, total: Int) {
        if case .analyzing = phase { phase = .analyzing(done: done, total: total) }
    }

    /// Analysis complete: settle on the authoritative full set (streamed events may
    /// still be in flight, so take the blunders straight from the returned result).
    private func finish(with result: GameReviewResult) {
        finished = true
        blunders = result.blunders(threshold: threshold)
        phase = blunders.isEmpty ? .noBlunders : .results(blunders: blunders, finished: true)
    }
}

// ── Shared chrome ─────────────────────────────────────────────────────────────

/// A circular Done/close button for the full-screen review mode.
private struct CloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(ChromeTheme.ink)
                .padding(12)
                .background(ChromeTheme.undoTint.opacity(0.22), in: Circle())
                .overlay(Circle().stroke(ChromeTheme.undoTint.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

/// Caramel pill matching the in-game control buttons.
private struct ReviewButton: ButtonStyle {
    let tint: SColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.bold())
            .padding(.horizontal, 18).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(tint.opacity(configuration.isPressed ? 0.45 : 0.22))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.6), lineWidth: 1))
            .foregroundStyle(ChromeTheme.ink)
    }
}

private enum ReviewTint {
    static let best = SColor(hex: 0x6a8a4a)   // olive-green (matches Done)
    static let gap = SColor(hex: 0xa83a2a)    // deep red
}

// MARK: - Previews

#Preview("Blunder mode") {
    let board = GameBoard()
    board.initializeBoard()
    let evals = [
        PlyEvaluation(plyNumber: 3, die1: 6, die2: 5, boardStacks: board.points.map(\.pieces),
                      mover: .white, playedMove: [[1, 7], [1, 6]], playedScore: 0.41,
                      bestMove: [[12, 18], [12, 17]], bestScore: 0.58),
        PlyEvaluation(plyNumber: 9, die1: 3, die2: 2, boardStacks: board.points.map(\.pieces),
                      mover: .white, playedMove: [[1, 4]], playedScore: 0.30,
                      bestMove: [[1, 3]], bestScore: 0.49),
    ]
    return GameReviewView(previewPhase: .results(blunders: evals, finished: true))
}

#Preview("No blunders") {
    GameReviewView(previewPhase: .noBlunders)
}

#Preview("Analyzing") {
    GameReviewView(previewPhase: .analyzing(done: 7, total: 18))
}
