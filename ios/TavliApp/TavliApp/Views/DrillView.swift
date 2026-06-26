import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// #63 — interactive post-game drill, the iPad analogue of the CLI's `drill`
/// command (`play/loop.py:_handle_drill` / `_drill_inner`). Reuses #62's blunder
/// detection (`GameReview`/`PlyEvaluation`): for each flagged ply it seeds a live
/// board at that position (`GameSession.drill`) and asks the player to find a
/// better move on the real board (the same tap/drag input as play). Each attempt
/// is graded against the AI's best (correct / close / wrong); "Show solution"
/// highlights the best move; "Skip"/"Next" advances; finishing shows a summary.
///
/// Pure presentation — all analysis/scoring lives in `TavliEngine`.
struct DrillView: View {
    let record: GameRecord
    /// Reuse an already-computed review (from the review screen) to skip re-analysis.
    let precomputed: GameReviewResult?
    let agent: Agent?
    let humanColor: TavliEngine.Color

    @StateObject private var model: DrillModel
    @Environment(\.dismiss) private var dismiss

    init(record: GameRecord, precomputed: GameReviewResult?, agent: Agent?,
         humanColor: TavliEngine.Color) {
        self.record = record
        self.precomputed = precomputed
        self.agent = agent
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: DrillModel())
    }

    /// Preview-only: seed a terminal phase so `#Preview`s skip analysis.
    fileprivate init(previewModel: DrillModel, humanColor: TavliEngine.Color = .white) {
        self.record = GameRecord(startingPlayer: .white, aiColor: .black)
        self.precomputed = nil
        self.agent = nil
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: previewModel)
    }

    private var flipped: Bool { humanColor == .black }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(SColor(hex: 0xece6dc))
        .task {
            await model.start(record: record, precomputed: precomputed,
                              agent: agent, humanColor: humanColor)
        }
    }

    private var header: some View {
        HStack {
            Text("Drill")
                .font(.title3.bold())
                .foregroundStyle(ChromeTheme.ink)
            if case .drilling = model.phase {
                Text("· Blunder \(model.index + 1) of \(model.total)")
                    .font(.callout)
                    .foregroundStyle(ChromeTheme.ink.opacity(0.6))
            }
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
        case .analyzing:
            centered {
                ProgressView().progressViewStyle(.circular).tint(ChromeTheme.ink)
                Text("Finding your blunders…")
                    .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
            }
        case .empty:
            centered {
                Text("No blunders to drill — well played!")
                    .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
            }
        case .drilling:
            if let card = model.session, let eval = model.current {
                DrillCard(session: card, eval: eval, flipped: flipped,
                          feedback: model.feedback, showingSolution: model.showingSolution,
                          lastAttempt: model.lastAttempt, lastAttemptScore: model.lastAttemptScore,
                          awaitingRetry: model.awaitingRetry,
                          solved: model.solvedThisCard,
                          onTryAgain: { model.tryAgain() },
                          onShowSolution: { model.revealSolution() },
                          onAdvance: { model.advance() })
                .id(model.index)   // fresh card (and board) per blunder
            }
        case .complete(let s):
            completeView(s)
        }
    }

    private func completeView(_ s: DrillModel.Summary) -> some View {
        centered {
            Text("Drill complete")
                .font(.system(size: 34, weight: .bold, design: .serif))
                .foregroundStyle(ChromeTheme.ink)
            Text(drillSummary(s))
                .font(.title3)
                .foregroundStyle(ChromeTheme.ink.opacity(0.7))
            Button("Done") { dismiss() }
                .font(.title3.bold())
                .padding(.horizontal, 28).padding(.vertical, 12)
                .background(ChromeTheme.doneTint.opacity(0.22))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(ChromeTheme.doneTint.opacity(0.6), lineWidth: 1))
                .foregroundStyle(ChromeTheme.ink)
                .buttonStyle(.plain)
        }
    }

    private func drillSummary(_ s: DrillModel.Summary) -> String {
        var text = String(localized: "Solved \(s.solved) of \(s.total)")
        if s.skipped > 0 {
            text += String(localized: " · skipped \(s.skipped)")
        }
        return text
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ── Drill controller ──────────────────────────────────────────────────────────

/// Drives the drill: analysis (or a precomputed result), the per-card seeded
/// session, attempt grading off the main actor, and progress. Same `@MainActor`
/// `ObservableObject` pattern as `GameReviewModel`.
@MainActor
final class DrillModel: ObservableObject {
    struct Summary { let solved: Int; let skipped: Int; let total: Int }

    enum Feedback: Equatable {
        case none
        case checking
        case correct(String)
        case close(String)
        case wrong(String)
    }

    enum Phase {
        case analyzing
        case empty
        case drilling
        case complete(Summary)
    }

    @Published var phase: Phase = .analyzing
    @Published private(set) var index = 0
    @Published private(set) var session: GameSession?
    @Published var feedback: Feedback = .none
    @Published private(set) var showingSolution = false
    /// The player's most recent attempt on this card, as `[from, to]` pairs (for
    /// showing what they actually played, in writing). `nil` until they move.
    @Published private(set) var lastAttempt: [[Int]]?
    /// Win-probability score of `lastAttempt` (#114), shown alongside it.
    @Published private(set) var lastAttemptScore: Float?
    /// Whether a non-solving attempt is held on the board, awaiting "Try again" (#114).
    @Published private(set) var awaitingRetry = false
    /// Whether the current card has been solved (a correct attempt was made).
    @Published private(set) var solvedThisCard = false

    // `play/loop.py` drill tolerances (drill_correct_floor / drill_correct_relative).
    // Hard-coded for now; candidates for the #77 settings work.
    private let correctFloor = 0.01
    private let correctRelative = 0.03
    private let closeFloor = 0.04
    private let closeRelative = 0.10

    private var blunders: [PlyEvaluation] = []
    private var agent: Agent?
    private var humanColor: TavliEngine.Color = .white
    private var started = false
    private var solvedCount = 0
    private var skippedCount = 0

    var total: Int { blunders.count }
    var current: PlyEvaluation? { index < blunders.count ? blunders[index] : nil }

    init() {}

    /// Preview-only: seed straight into a drilling card or a terminal phase.
    fileprivate init(preview phase: Phase, blunders: [PlyEvaluation] = [], agent: Agent? = nil) {
        self.phase = phase
        self.blunders = blunders
        self.agent = agent
        self.started = true
        if case .drilling = phase, let first = blunders.first {
            session = GameSession.drill(boardStacks: first.boardStacks,
                                        die1: first.die1, die2: first.die2,
                                        mover: first.mover, agent: agent)
        }
    }

    func start(record: GameRecord, precomputed: GameReviewResult?, agent: Agent?,
               humanColor: TavliEngine.Color) async {
        guard !started else { return }
        started = true
        self.agent = agent
        self.humanColor = humanColor

        let result: GameReviewResult
        if let precomputed {
            result = precomputed
        } else if let agent {
            result = await Task.detached(priority: .userInitiated) {
                GameReview.analyze(record: record, agent: agent, humanColor: humanColor)
            }.value
        } else {
            phase = .empty
            return
        }

        // Only the human's own blunders are drillable — opponent plies may now be in
        // the result too (#132).
        blunders = result.evaluations.filter { $0.mover == humanColor && $0.isBlunder(threshold: 0.10) }
        guard !blunders.isEmpty else { phase = .empty; return }
        loadCard(0)
        phase = .drilling
    }

    private func loadCard(_ i: Int) {
        index = i
        feedback = .none
        showingSolution = false
        lastAttempt = nil
        lastAttemptScore = nil
        awaitingRetry = false
        solvedThisCard = false
        let b = blunders[i]
        let s = GameSession.drill(boardStacks: b.boardStacks, die1: b.die1, die2: b.die2,
                                  mover: b.mover, agent: agent)
        s.onMoveAttempt = { [weak self] move in self?.grade(move) }
        s.holdAttempts = true   // keep the attempt on the board until "Try again" (#114)
        session = s
    }

    /// Grade a player's attempt: score it off the main actor and set feedback.
    private func grade(_ move: Move) {
        guard let b = current, let agent else { return }
        feedback = .checking
        let pairs = move.halfMoves.map { [$0.from.position, $0.to.position] }
        lastAttempt = pairs
        let stacks = b.boardStacks
        let mover = b.mover
        let best = b.bestScore
        Task.detached(priority: .userInitiated) { [weak self] in
            let score = try? agent.scoreCandidate(boardStacks: stacks, move: pairs, mover: mover)
            await MainActor.run { self?.applyFeedback(score: score, best: best) }
        }
    }

    private func applyFeedback(score: Float?, best: Float) {
        lastAttemptScore = score
        guard let score else {
            awaitingRetry = true
            feedback = .wrong(String(localized: "Couldn’t evaluate — try again."))
            return
        }
        let gap = Double(best - score)
        let correctThreshold = max(correctFloor, Double(best) * correctRelative)
        let closeThreshold = max(closeFloor, Double(best) * closeRelative)
        if gap <= correctThreshold {
            // Solved: leave the move on the board (#114) — no retry, advance with "Next".
            awaitingRetry = false
            if !solvedThisCard { solvedThisCard = true; solvedCount += 1 }
            feedback = .correct(gap < 0.001 ? String(localized: "Excellent — that’s the best move!")
                                            : String(localized: "Great — very close to optimal."))
        } else if gap <= closeThreshold {
            awaitingRetry = true
            feedback = .close(String(localized: "Close — there’s a better move. Try again."))
        } else {
            awaitingRetry = true
            feedback = .wrong(String(localized: "Not quite — think a little harder."))
        }
    }

    /// Roll the held attempt back to the start so the player can try again (#114).
    func tryAgain() {
        session?.retryAttempt()
        awaitingRetry = false
        lastAttempt = nil
        lastAttemptScore = nil
        feedback = .none
    }

    /// Reveal the best move. If an attempt is held, roll it back first so the solution
    /// highlight (drawn from the pre-move position) lines up with the board (#114).
    func revealSolution() {
        if session?.heldAttempt != nil { session?.retryAttempt() }
        awaitingRetry = false
        showingSolution = true
    }

    /// Move to the next blunder (or finish). A card left unsolved counts as skipped.
    func advance() {
        if !solvedThisCard { skippedCount += 1 }
        if index + 1 < blunders.count {
            loadCard(index + 1)
        } else {
            session = nil
            phase = .complete(Summary(solved: solvedCount, skipped: skippedCount, total: blunders.count))
        }
    }
}

// ── Drill card ────────────────────────────────────────────────────────────────

/// One blunder card: the position the player faced, a feedback line, and the
/// Show-solution / Skip-or-Next controls. The board is the real `PlayableBoardView`
/// bound to the seeded session, so taps/drags drive `onMoveAttempt`.
private struct DrillCard: View {
    @ObservedObject var session: GameSession
    let eval: PlyEvaluation
    let flipped: Bool
    let feedback: DrillModel.Feedback
    let showingSolution: Bool
    /// The player's latest attempt on this card, as `[from, to]` pairs (shown in writing).
    let lastAttempt: [[Int]]?
    let lastAttemptScore: Float?
    let awaitingRetry: Bool
    let solved: Bool
    let onTryAgain: () -> Void
    let onShowSolution: () -> Void
    let onAdvance: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            if landscape {
                HStack(spacing: 0) {
                    board
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(12)
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Dice \(eval.die1) · \(eval.die2) — find a better move")
                            .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
                        feedbackLine
                        movesPanel
                        Spacer(minLength: 0)
                        controls
                    }
                    .frame(width: 320, alignment: .leading)
                    .padding(.vertical, 16).padding(.trailing, 16)
                }
            } else {
                VStack(spacing: 14) {
                    Text("Dice \(eval.die1) · \(eval.die2) — find a better move")
                        .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
                    board.layoutPriority(1).padding(.horizontal, 12)
                    feedbackLine
                    movesPanel
                    controls.padding(.horizontal, 20)
                }
                .padding(.vertical, 12)
            }
        }
    }

    private var board: some View {
        ZStack {
            PlayableBoardView(session: session, flipped: flipped)
            // Overlays are drawn from the pre-move position, so only show them when the
            // board is actually there (no attempt held on it) (#114).
            if session.heldAttempt == nil {
                if showingSolution {
                    // Compare what you played (yellow) against the best (blue), both
                    // green where they agree (#133).
                    MoveHighlightView(playedMove: eval.playedMove, bestMove: eval.bestMove,
                                      stacks: eval.boardStacks, flipped: flipped)
                } else if !solved {
                    // The move you originally played — "you did this; find better" (#114).
                    MoveHighlightView(playedMove: eval.playedMove, bestMove: nil,
                                      stacks: eval.boardStacks, flipped: flipped)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private var feedbackLine: some View {
        switch feedback {
        case .none:
            Text("Make your move on the board.")
                .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.55))
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
            }
        case .correct(let msg):
            Text(msg).font(.callout.bold()).foregroundStyle(DrillTint.correct)
        case .close(let msg):
            Text(msg).font(.callout.bold()).foregroundStyle(DrillTint.close)
        case .wrong(let msg):
            Text(msg).font(.callout.bold()).foregroundStyle(DrillTint.wrong)
        }
    }

    /// The scores behind the drill (#114): the move you originally played and its win
    /// chance, your latest attempt and its win chance, and — once revealed — the best
    /// move with the gap. Mirrors the review's number language.
    @ViewBuilder
    private var movesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            moveRow(label: "You played", move: eval.playedMove,
                    pct: Double(eval.playedScore), tint: CaramelPalette.hl)
            if let lastAttempt, let s = lastAttemptScore {
                moveRow(label: "You tried", move: lastAttempt,
                        pct: Double(s), tint: ChromeTheme.ink)
            }
            if showingSolution {
                moveRow(label: "Best move", move: eval.bestMove,
                        pct: Double(eval.bestScore), tint: CaramelPalette.hlBest)
                Text("−\(percent(Double(eval.bestScore - eval.playedScore))) win chance vs your move")
                    .font(.caption).foregroundStyle(ChromeTheme.ink.opacity(0.55))
            }
        }
    }

    private func moveRow(label: String, move: [[Int]], pct: Double, tint: SColor) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(ChromeTheme.ink.opacity(0.55))
            Text(moveText(move)).font(.callout.monospaced().bold()).foregroundStyle(tint)
            Text("\(percent(pct))").font(.caption.monospacedDigit()).foregroundStyle(ChromeTheme.ink.opacity(0.5))
        }
    }

    private func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    private func moveText(_ pairs: [[Int]]) -> String {
        guard !pairs.isEmpty else { return "(pass)" }
        return pairs.map { $0.count == 2 ? "\($0[0])→\($0[1])" : "?" }.joined(separator: ", ")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 16) {
            if solved || showingSolution {
                // Nothing more to do on this card — keep the result on the board (#114).
                Button("Next →", action: onAdvance)
                    .buttonStyle(DrillButton(tint: ChromeTheme.doneTint))
            } else if awaitingRetry {
                // An attempt is held on the board: reset to retry, or reveal the answer.
                Button("Try again", action: onTryAgain)
                    .buttonStyle(DrillButton(tint: ChromeTheme.doneTint))
                Button("Show solution", action: onShowSolution)
                    .buttonStyle(DrillButton(tint: ChromeTheme.undoTint))
            } else {
                // Before the first attempt.
                Button("Show solution", action: onShowSolution)
                    .buttonStyle(DrillButton(tint: ChromeTheme.undoTint))
                Button("Skip", action: onAdvance)
                    .buttonStyle(DrillButton(tint: ChromeTheme.undoTint))
            }
        }
    }
}

/// Caramel pill matching the in-game control buttons.
private struct DrillButton: ButtonStyle {
    let tint: SColor
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.bold())
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(tint.opacity(configuration.isPressed ? 0.45 : 0.22))
            .cornerRadius(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.6), lineWidth: 1))
            .foregroundStyle(ChromeTheme.ink)
    }
}

private enum DrillTint {
    static let correct = SColor(hex: 0x6a8a4a)   // olive-green
    static let close = SColor(hex: 0xa87a3e)     // amber
    static let wrong = SColor(hex: 0xa83a2a)     // deep red
}

// MARK: - Previews

#Preview("Drilling") {
    let board = GameBoard()
    board.initializeBoard()
    let eval = PlyEvaluation(
        plyNumber: 5, die1: 6, die2: 5,
        boardStacks: board.points.map(\.pieces), mover: .white,
        playedMove: [[1, 7]], playedScore: 0.42,
        bestMove: [[1, 12]], bestScore: 0.58
    )
    return DrillView(previewModel: DrillModel(preview: .drilling, blunders: [eval]))
}

#Preview("No blunders") {
    DrillView(previewModel: DrillModel(preview: .empty))
}

#Preview("Complete") {
    DrillView(previewModel: DrillModel(preview: .complete(.init(solved: 3, skipped: 1, total: 4))))
}
