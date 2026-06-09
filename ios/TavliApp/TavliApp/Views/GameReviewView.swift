import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// #62 — post-game blunder review, the iPad analogue of the CLI's `review`
/// command. Presented as a sheet from the win overlay: it replays the finished
/// game off the main actor (`GameReview.analyze`), then lists the human plies
/// where the played move fell ≥10% short of the AI's best (relative win-prob gap).
/// Tapping a row reveals the board the player faced at that point.
///
/// The threshold is fixed at 10% for now; a configurable one is tracked in #77.
/// Pure presentation — all analysis lives in `TavliEngine`.
struct GameReviewView: View {
    let record: GameRecord
    let agent: Agent?
    let humanColor: TavliEngine.Color

    @StateObject private var model: GameReviewModel
    @Environment(\.dismiss) private var dismiss

    /// Drives the drill sheet launched from the review list (#63).
    @State private var showDrill = false

    /// `play/loop.py` default — flag moves ≥10% worse than the best.
    private let threshold = 0.10

    init(record: GameRecord, agent: Agent?, humanColor: TavliEngine.Color) {
        self.record = record
        self.agent = agent
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: GameReviewModel())
    }

    /// Preview-only: seed a terminal phase so `#Preview`s skip the (model-driven)
    /// analysis. `agent` is nil and the model is pre-marked started, so `.task`
    /// is a no-op.
    fileprivate init(previewPhase: GameReviewModel.Phase,
                     expanded: Int? = nil,
                     humanColor: TavliEngine.Color = .white) {
        self.record = GameRecord(startingPlayer: .white, aiColor: .black)
        self.agent = nil
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: GameReviewModel(preview: previewPhase, expanded: expanded))
    }

    private var flipped: Bool { humanColor == .black }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(SColor(hex: 0xece6dc))
        .task { await model.run(record: record, agent: agent, humanColor: humanColor) }
        .sheet(isPresented: $showDrill) {
            if case .done(let result) = model.phase {
                DrillView(record: record, precomputed: result,
                          agent: agent, humanColor: humanColor)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Game review")
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

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .analyzing(let done, let total):
            analyzing(done: done, total: total)
        case .unavailable:
            message("Review needs the AI model, which isn’t available.")
        case .done(let result):
            let blunders = result.blunders(threshold: threshold)
            if blunders.isEmpty {
                message("No blunders found — well played!")
            } else {
                blunderList(blunders)
            }
        }
    }

    private func analyzing(done: Int, total: Int) -> some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView()
                .progressViewStyle(.circular)
                .tint(ChromeTheme.ink)
            Text(total > 0 ? "Analyzing move \(done) of \(total)…" : "Analyzing your moves…")
                .font(.callout)
                .foregroundStyle(ChromeTheme.ink.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(ChromeTheme.ink.opacity(0.7))
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func blunderList(_ blunders: [PlyEvaluation]) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(summary(blunders.count))
                        .font(.subheadline)
                        .foregroundStyle(ChromeTheme.ink.opacity(0.7))
                    Spacer(minLength: 12)
                    Button("Drill these") { showDrill = true }
                        .font(.subheadline.bold())
                        .foregroundStyle(ChromeTheme.ink)
                        .buttonStyle(.plain)
                }
                .padding(.vertical, 12)

                ForEach(blunders, id: \.plyNumber) { eval in
                    BlunderRow(eval: eval,
                               expanded: model.expanded == eval.plyNumber,
                               flipped: flipped,
                               onTap: { model.toggle(eval.plyNumber) })
                    Divider().opacity(0.4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func summary(_ count: Int) -> String {
        count == 1 ? "1 blunder found (≥10% worse than best)."
                   : "\(count) blunders found (≥10% worse than best)."
    }
}

/// Drives `GameReview.analyze` off the main actor and publishes its progress.
/// `@MainActor` so `phase`/`expanded` mutate safely; the background task hops back
/// here for each progress tick.
@MainActor
final class GameReviewModel: ObservableObject {
    enum Phase {
        case analyzing(done: Int, total: Int)
        case done(GameReviewResult)
        case unavailable
    }

    @Published var phase: Phase = .analyzing(done: 0, total: 0)
    /// `plyNumber` of the row whose board preview is expanded, if any.
    @Published var expanded: Int?

    private var started = false

    init() {}

    /// Preview-only: start in a terminal phase so analysis never runs.
    fileprivate init(preview phase: Phase, expanded: Int?) {
        self.phase = phase
        self.expanded = expanded
        self.started = true
    }

    func run(record: GameRecord, agent: Agent?, humanColor: TavliEngine.Color) async {
        guard !started else { return }   // `.task` can re-fire; analyze once
        started = true

        guard let agent else { phase = .unavailable; return }

        let result = await Task.detached(priority: .userInitiated) { [weak self] in
            GameReview.analyze(record: record, agent: agent, humanColor: humanColor, depth: 3) { done, total in
                Task { @MainActor in self?.report(done: done, total: total) }
            }
        }.value

        phase = .done(result)
    }

    func toggle(_ plyNumber: Int) {
        expanded = (expanded == plyNumber) ? nil : plyNumber
    }

    private func report(done: Int, total: Int) {
        if case .analyzing = phase { phase = .analyzing(done: done, total: total) }
    }
}

/// One flagged ply: the number, dice, played→best move, and the win-probability
/// gap. Expands on tap to show the board the player faced (#62).
private struct BlunderRow: View {
    let eval: PlyEvaluation
    let expanded: Bool
    let flipped: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    Text("\(eval.plyNumber).")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(ChromeTheme.ink.opacity(0.5))
                        .frame(width: 34, alignment: .trailing)
                    Circle()
                        .fill(ChromeTheme.checkerColor(eval.mover))
                        .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.35), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("d=\(eval.die1) \(eval.die2)")
                            .font(.caption.monospaced())
                            .foregroundStyle(ChromeTheme.ink.opacity(0.6))
                        Text("You: \(moveText(eval.playedMove))")
                            .font(.callout.monospaced())
                            .foregroundStyle(ChromeTheme.ink)
                        Text("Best: \(moveText(eval.bestMove))")
                            .font(.callout.monospaced())
                            .foregroundStyle(ChromeTheme.bestTint)
                    }
                    Spacer(minLength: 8)
                    gapBadge
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ZStack {
                    BoardView(flipped: flipped)
                    CheckersView(stacks: eval.boardStacks, flipped: flipped)
                }
                .frame(maxWidth: 460)
                .padding(.vertical, 8)
            }
        }
    }

    /// Win-probability shortfall as a red badge (e.g. "−12%"), with the played and
    /// best percentages beneath.
    private var gapBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("−\(percent(eval.absoluteGap))")
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(ChromeTheme.gapTint)
            Text("\(percent(Double(eval.playedScore))) → \(percent(Double(eval.bestScore)))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(ChromeTheme.ink.opacity(0.55))
        }
    }

    private func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    private func moveText(_ pairs: [[Int]]) -> String {
        guard !pairs.isEmpty else { return "(pass)" }
        return pairs.map { $0.count == 2 ? "\($0[0])→\($0[1])" : "?" }.joined(separator: ", ")
    }
}

private extension ChromeTheme {
    /// Best-move text and gap accents, harmonized with the Caramel palette.
    static var bestTint: SColor { SColor(hex: 0x6a8a4a) }   // olive-green (matches Done)
    static var gapTint: SColor { SColor(hex: 0xa83a2a) }    // deep red
}

// MARK: - Previews

#Preview("Blunders") {
    // A scripted result with one flagged ply on the opening position.
    let board = GameBoard()
    board.initializeBoard()
    let eval = PlyEvaluation(
        plyNumber: 3, die1: 6, die2: 5,
        boardStacks: board.points.map(\.pieces), mover: .white,
        playedMove: [[1, 7], [1, 6]], playedScore: 0.41,
        bestMove: [[12, 18], [12, 17]], bestScore: 0.58
    )
    return GameReviewView(previewPhase: .done(GameReviewResult(evaluations: [eval])), expanded: 3)
}

#Preview("No blunders") {
    GameReviewView(previewPhase: .done(GameReviewResult(evaluations: [])))
}

#Preview("Analyzing") {
    GameReviewView(previewPhase: .analyzing(done: 7, total: 18))
}
