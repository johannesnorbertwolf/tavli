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

    /// Index of the evaluated move currently shown (clamped to the streamed set).
    @State private var index = 0
    /// Whether the board compares your move against the best, or shows yours alone.
    /// Always shows your move (#133); `.both` overlays the best move too.
    @State private var overlay: MoveOverlay = .your
    /// Drives the drill, launched full-screen from the review (#63).
    @State private var showDrill = false
    /// When on, Prev/Next/swipe jump only between your own blunders (#132).
    @State private var onlyBlunders = false

    enum MoveOverlay: Hashable { case your, both }

    init(record: GameRecord, agent: Agent?, humanColor: TavliEngine.Color) {
        self.record = record
        self.agent = agent
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: GameReviewModel())
    }

    /// Preview-only: seed a terminal phase so `#Preview`s skip analysis. `trajectory`
    /// seeds the full chart data set (#105).
    fileprivate init(previewPhase: GameReviewModel.Phase, humanColor: TavliEngine.Color = .white,
                     trajectory: [PlyEvaluation] = []) {
        self.record = GameRecord(startingPlayer: .white, aiColor: .black)
        self.agent = nil
        self.humanColor = humanColor
        _model = StateObject(wrappedValue: GameReviewModel(preview: previewPhase, trajectory: trajectory))
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
        .onChange(of: onlyBlunders) { _, on in
            // Snap to the blunder nearest the current move when switching to the
            // blunders-only filter, so you don't land on a hidden non-blunder (#132).
            guard on else { return }
            let plies = model.chartEvaluations
            let blunderIdx = plies.indices.filter { model.blunderPlies.contains(plies[$0].plyNumber) }
            if let nearest = blunderIdx.min(by: { abs($0 - index) < abs($1 - index) }) {
                index = nearest
            }
        }
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
                if total > 0 {
                    Text("Analyzing move \(done) of \(total)…")
                        .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
                } else {
                    Text("Analyzing your moves…")
                        .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
                }
            }
        case .unavailable:
            centered {
                Text("Review needs the AI model, which isn’t available.")
                    .font(.callout).foregroundStyle(ChromeTheme.ink.opacity(0.7))
            }
        case .nothingToReview:
            centered {
                Text("No moves to review.")
                    .font(.title3).foregroundStyle(ChromeTheme.ink.opacity(0.8))
            }
        case .reviewing(let finished):
            // Page through every scored move; blunders are flagged on the chart and
            // in the move detail (#105).
            reviewMode(model.chartEvaluations, finished: finished)
        }
    }

    // ── Board-centric review mode ──────────────────────────────────────────────

    private func reviewMode(_ plies: [PlyEvaluation], finished: Bool) -> some View {
        let i = min(max(index, 0), max(plies.count - 1, 0))
        let eval = plies[i]
        // Scrubbing the chart lands on the move nearest the tapped ply.
        let scrub: (Int) -> Void = { ply in
            guard let nearest = plies.indices.min(by: {
                abs(plies[$0].plyNumber - ply) < abs(plies[$1].plyNumber - ply)
            }) else { return }
            index = nearest
        }
        return GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            Group {
                if landscape {
                    HStack(alignment: .top, spacing: 0) {
                        boardArea(eval)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(12)
                        panel(eval: eval, i: i, count: plies.count, finished: finished, onScrub: scrub)
                            .frame(width: 320)
                            .padding(.top, 56)   // clear the floating Close button
                            .padding(.trailing, 16)
                    }
                } else {
                    VStack(spacing: 12) {
                        panel(eval: eval, i: i, count: plies.count, finished: finished, onScrub: scrub)
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
            .gesture(pagingGesture(count: plies.count, current: i))
        }
    }

    /// The full board at the blunder position, optionally overlaying a move.
    private func boardArea(_ eval: PlyEvaluation) -> some View {
        ZStack {
            BoardView(flipped: flipped)
            CheckersView(stacks: eval.boardStacks, flipped: flipped)
            // Always show your move (amber); `.both` overlays the best move (blue),
            // with shared elements in green (#133).
            MoveHighlightView(playedMove: eval.playedMove,
                              bestMove: overlay == .both ? eval.bestMove : nil,
                              stacks: eval.boardStacks, flipped: flipped)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func panel(eval: PlyEvaluation, i: Int, count: Int, finished: Bool,
                       onScrub: @escaping (Int) -> Void) -> some View {
        let isBlunder = model.blunderPlies.contains(eval.plyNumber)
        let isHuman = eval.mover == humanColor
        let mover = isHuman ? "You" : "TavTav"
        return VStack(alignment: .leading, spacing: 18) {
            // Reassurance headline when the whole game had no blunders (#105).
            if finished, model.blunderPlies.isEmpty {
                Text("No blunders — nicely played!")
                    .font(.title3.bold())
                    .foregroundStyle(ChromeTheme.ink)
            }

            // Win-probability trajectory across the whole game, with blunders ringed
            // (#105). Shown as soon as the 1-ply base pass is in (#103) — the deeper
            // passes refine it in place (needs ≥2 points to trace a line).
            if model.firstPassComplete, model.chartEvaluations.count >= 2 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Win chance through the game")
                        .font(.caption).foregroundStyle(ChromeTheme.ink.opacity(0.55))
                    WinProbabilityChart(evaluations: model.chartEvaluations,
                                        selectedPly: eval.plyNumber,
                                        blunders: model.blunderPlies, onScrub: onScrub)
                }
            }

            // Move counter + blunder badge + dice.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Move \(i + 1) of \(count)")
                        .font(.title3.bold())
                        .foregroundStyle(ChromeTheme.ink)
                    // Whose move this is — your own, or the AI opponent's (#132).
                    MoverChip(label: mover, isHuman: isHuman)
                    if isBlunder { BlunderBadge() }
                    if !finished {
                        // Deeper passes still refining in the background (#103).
                        ProgressView().controlSize(.small)
                    }
                }
                HStack(spacing: 8) {
                    Text("Dice \(eval.die1) · \(eval.die2)")
                        .font(.callout.monospaced())
                        .foregroundStyle(ChromeTheme.ink.opacity(0.6))
                    // Which look-ahead depth this score is from (#103) — refines live
                    // 1→2→3-ply, so you can see what you're looking at.
                    DepthChip(depth: eval.depth)
                }
            }

            // Played vs best. For a ply with a choice we ALWAYS show the played line,
            // the best line, and a status line — so (a) the panel height is constant as
            // you page, keeping the controls below from jumping (#105/#132), and (b) the
            // text agrees with the board: "best move played" shows only when the moves
            // are actually identical, never just close in score (#103).
            let playedIsBest = sameMove(eval.playedMove, eval.bestMove)
            VStack(alignment: .leading, spacing: 10) {
                // Distinct literal labels (not "\(mover) played") so they localize.
                moveLine(label: isHuman ? "You played" : "TavTav played", move: eval.playedMove,
                         pct: Double(eval.playedScore), tint: ChromeTheme.ink)
                if eval.hadChoice {
                    moveLine(label: "Best move", move: eval.bestMove,
                             pct: Double(eval.bestScore), tint: ReviewTint.best)
                    if playedIsBest {
                        Text(isHuman ? "Best move played ✓" : "TavTav played the best ✓")
                            .font(.callout.bold())
                            .foregroundStyle(ReviewTint.best)
                    } else {
                        Text("−\(percent(eval.absoluteGap)) win chance")
                            .font(.callout.bold())
                            .foregroundStyle(isBlunder ? ReviewTint.gap : ChromeKit.inkSecondary)
                    }
                } else {
                    // Forced ply: a single legal move, nothing to choose (#131).
                    Text("Only move available")
                        .font(.callout.bold())
                        .foregroundStyle(ChromeKit.inkSecondary)
                }
            }

            // Highlight selector — your move alone, or compared against the best.
            VStack(alignment: .leading, spacing: 8) {
                Picker("Show on board", selection: $overlay) {
                    Text("Your move").tag(MoveOverlay.your)
                    Text("Compare").tag(MoveOverlay.both)
                }
                .pickerStyle(.segmented)
                // Always laid out (hidden when not comparing) so the controls below
                // don't shift when you toggle Compare (#132).
                HStack(spacing: 14) {
                    legendDot(CaramelPalette.hl, "played")
                    legendDot(CaramelPalette.hlBest, "best")
                    legendDot(CaramelPalette.hlBoth, "both")
                }
                .font(.caption)
                .foregroundStyle(ChromeTheme.ink.opacity(0.6))
                .opacity(overlay == .both ? 1 : 0)
            }

            // Step through all plies (both sides), or jump only between your own
            // blunders so the opponent's moves don't make navigation tedious (#132).
            if !model.blunderPlies.isEmpty {
                Picker("Step through", selection: $onlyBlunders) {
                    Text("All moves").tag(false)
                    Text("My blunders").tag(true)
                }
                .pickerStyle(.segmented)
            }

            // Navigation + drill.
            let prev = navIndex(from: i, dir: -1)
            let next = navIndex(from: i, dir: 1)
            HStack(spacing: 12) {
                Button { index = prev } label: { Label("Prev", systemImage: "chevron.left") }
                    .buttonStyle(ReviewButton(tint: ChromeTheme.undoTint))
                    .disabled(prev == i).opacity(prev == i ? 0.4 : 1)
                Button { index = next } label: { Label("Next", systemImage: "chevron.right") }
                    .buttonStyle(ReviewButton(tint: ChromeTheme.undoTint))
                    .disabled(next == i).opacity(next == i ? 0.4 : 1)
            }
            // Drilling is offered whenever the game had blunders to drill.
            if !model.blunderPlies.isEmpty {
                Button("Drill blunders") { showDrill = true }
                    .buttonStyle(ReviewButton(tint: ChromeTheme.doneTint))
                    .frame(maxWidth: .infinity)
            }
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

    /// Next index in `dir` (+1/−1). In "My blunders" mode, skip to the next ply that
    /// is one of your blunders; otherwise step by one. Returns the same index when
    /// there's nowhere to go (so callers can disable the button) (#132).
    private func navIndex(from i: Int, dir: Int) -> Int {
        let plies = model.chartEvaluations
        guard !plies.isEmpty else { return i }
        if onlyBlunders, !model.blunderPlies.isEmpty {
            var j = i + dir
            while j >= 0 && j < plies.count {
                if model.blunderPlies.contains(plies[j].plyNumber) { return j }
                j += dir
            }
            return i
        }
        return min(max(i + dir, 0), plies.count - 1)
    }

    /// Left/right swipe pages through moves (honoring the blunders-only filter).
    private func pagingGesture(count: Int, current i: Int) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                index = navIndex(from: i, dir: value.translation.width < 0 ? 1 : -1)
            }
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 16) { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Formatting ────────────────────────────────────────────────────────────

    /// A small colour swatch + label for the compare legend (#133).
    private func legendDot(_ color: SColor, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
    private func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }
    /// Whether two moves are the *same* move (order-independent), so the panel claims
    /// "best move played" only when they genuinely match — not merely scoring alike,
    /// which let the text disagree with the highlighted board move (#103).
    private func sameMove(_ a: [[Int]], _ b: [[Int]]) -> Bool {
        func norm(_ m: [[Int]]) -> [[Int]] {
            m.filter { $0.count == 2 }.sorted { $0[0] != $1[0] ? $0[0] < $1[0] : $0[1] < $1[1] }
        }
        return norm(a) == norm(b)
    }
    /// Render a move's half-moves, always **sorted by start point then end point**, so
    /// the same move reads identically however its half-moves were ordered when played
    /// (e.g. a Pasch 1→4, 4→7, 1→4, 6→9 always shows as 1→4, 1→4, 4→7, 6→9).
    private func moveText(_ pairs: [[Int]]) -> String {
        guard !pairs.isEmpty else { return "(pass)" }
        let ordered = pairs.sorted { a, b in
            let a0 = a.first ?? 0, b0 = b.first ?? 0
            if a0 != b0 { return a0 < b0 }
            return (a.count > 1 ? a[1] : 0) < (b.count > 1 ? b[1] : 0)
        }
        return ordered.map { $0.count == 2 ? "\($0[0])→\($0[1])" : "?" }.joined(separator: ", ")
    }
}

// ── Controller (streaming) ────────────────────────────────────────────────────

/// Drives `GameReview.analyze` off the main actor and **streams** its evaluations
/// back: the all-moves review opens as soon as the first move is scored and fills in
/// as the rest analyze in the background. `@MainActor` so its published state mutates
/// safely; the background task hops back here per event.
@MainActor
final class GameReviewModel: ObservableObject {
    enum Phase {
        case analyzing(done: Int, total: Int)        // before the first scored move
        case reviewing(finished: Bool)               // ≥1 scored move; all-moves pager
        case nothingToReview                         // finished, no scored moves
        case unavailable
    }

    @Published var phase: Phase = .analyzing(done: 0, total: 0)
    /// True once the 1-ply base pass has scored every ply (#103) — the win-probability
    /// graph and the drill are complete from here, while 2-/3-ply refine in place.
    @Published private(set) var firstPassComplete = false

    /// `play/loop.py` default — flag moves ≥10% worse than the best.
    private let threshold = 0.10
    /// The human under review — only this side's plies count as blunders (#132).
    private var humanColor: TavliEngine.Color = .white
    private var blunders: [PlyEvaluation] = []
    /// Every evaluated human ply, in play order — the win-probability chart's data
    /// source (#105). A superset of `blunders` (this same list filtered at `threshold`).
    private var allEvaluations: [PlyEvaluation] = []
    private var started = false
    private var finished = false

    /// The evaluated plies found so far, as a result the drill can consume directly
    /// (it re-filters to blunders at its own threshold).
    var result: GameReviewResult { GameReviewResult(evaluations: allEvaluations) }

    /// The full win-probability trajectory for the chart (#105): every evaluated ply.
    var chartEvaluations: [PlyEvaluation] { allEvaluations }

    /// Ply numbers flagged as blunders — drives the chart rings + the detail badge (#105).
    var blunderPlies: Set<Int> { Set(blunders.map(\.plyNumber)) }

    init() {}

    /// Preview-only: start in a terminal phase so analysis never runs. `trajectory`
    /// seeds the full chart data set; blunders are derived from it.
    fileprivate init(preview phase: Phase, trajectory: [PlyEvaluation] = []) {
        self.phase = phase
        self.started = true
        self.finished = true
        self.allEvaluations = trajectory
        self.blunders = trajectory.filter { $0.isBlunder(threshold: threshold) }
        self.firstPassComplete = true
    }

    /// The append-only game log (#104). Holds the saved analysis: read it back to skip
    /// re-analysis, and write the freshly computed analysis back into the same entry.
    private let gameLog = GameLogStore.default()

    func run(record: GameRecord, agent: Agent?, humanColor: TavliEngine.Color) async {
        guard !started else { return }   // `.task` can re-fire; analyze once
        started = true
        self.humanColor = humanColor

        // Seed from any saved analysis (#104, #146): the in-play 2-ply analysis written
        // during the game, or a full prior review. Restoring it up front opens the graph,
        // pager and drill instantly — no model inference for these plies and no visible
        // 2-ply "Analyzing…" pass (the phase is already `.reviewing`, so `report` stays
        // quiet). With a complete 2-ply seed only the 3-ply borderline refinement remains.
        let cached = gameLog.analysis(forGameId: record.gameId) ?? []
        if !cached.isEmpty {
            for eval in GameReview.cachedResult(record: record, analysis: cached).evaluations {
                ingest(eval)
            }
            firstPassComplete = true
        }

        guard let agent else {
            // No model: keep whatever we restored from cache; nothing more we can do.
            if cached.isEmpty { phase = .unavailable } else { finish(with: result) }
            return
        }

        // Deepen on top of the seed: a full 2-ply seed makes the 1-/2-ply passes no-ops
        // and only the human's borderline plies refine to 3-ply; an empty seed runs the
        // original full 1→2→3-ply analysis (pre-#146 logs / analysis-off games).
        let reviewed = await Task.detached(priority: .userInitiated) { [weak self] in
            GameReview.analyzeProgressive(
                record: record, agent: agent, humanColor: humanColor,
                includeOpponent: true, seed: cached,
                onEvaluation: { eval in Task { @MainActor in self?.ingest(eval) } },
                onPassComplete: { pass, _ in Task { @MainActor in self?.passComplete(pass) } },
                progress: { done, total, _ in Task { @MainActor in self?.report(done: done, total: total) } }
            )
        }.value

        finish(with: reviewed)
        // Write the (possibly deepened) analysis back so it never recomputes (#104). No-op
        // if the game isn't logged (e.g. a preview/test record). Off the main actor.
        let gameId = record.gameId
        let entries = [AnalysisEntry](reviewResult: reviewed)
        if !entries.isEmpty {
            let log = gameLog
            Task.detached { try? log.attachAnalysis(entries, forGameId: gameId) }
        }
    }

    /// A streamed evaluation: upsert it by ply number (a deeper pass replaces the
    /// shallower result, #103) and open the pager as soon as the first move is scored.
    /// Blunders are recomputed from the current set so they track the latest depth.
    private func ingest(_ eval: PlyEvaluation) {
        guard !finished else { return }
        if let idx = allEvaluations.firstIndex(where: { $0.plyNumber == eval.plyNumber }) {
            allEvaluations[idx] = eval
        } else {
            allEvaluations.append(eval)
            allEvaluations.sort { $0.plyNumber < $1.plyNumber }
        }
        blunders = allEvaluations.filter { $0.mover == humanColor && $0.isBlunder(threshold: threshold) }
        phase = .reviewing(finished: false)
    }

    /// The 1-ply base pass (pass 0) is done: the graph + drill are now complete (#103).
    private func passComplete(_ pass: Int) {
        if pass == 0 { firstPassComplete = true }
    }

    private func report(done: Int, total: Int) {
        if case .analyzing = phase { phase = .analyzing(done: done, total: total) }
    }

    /// Analysis complete: settle on the authoritative full set (streamed events may
    /// still be in flight, so take everything straight from the returned result).
    private func finish(with result: GameReviewResult) {
        finished = true
        firstPassComplete = true
        allEvaluations = result.evaluations
        blunders = result.evaluations.filter { $0.mover == humanColor && $0.isBlunder(threshold: threshold) }
        phase = allEvaluations.isEmpty ? .nothingToReview : .reviewing(finished: true)
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

/// Amber pill flagging the current move as a blunder (#105), in the board's
/// move-highlight amber (`CaramelPalette.hl`) so it matches the chart's blunder rings.
private struct BlunderBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Blunder")
        }
        .font(.caption.bold())
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(CaramelPalette.hlEdge)
        .background(CaramelPalette.hl.opacity(0.22), in: Capsule())
        .overlay(Capsule().stroke(CaramelPalette.hlEdge.opacity(0.55), lineWidth: 1))
    }
}

/// The look-ahead depth a review score is from (#103): 1/2/3-ply, refining live.
private struct DepthChip: View {
    let depth: Int
    var body: some View {
        Text("\(depth)-ply")
            .font(.caption2.bold().monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(ChromeTheme.ink.opacity(0.6))
            .background(ChromeTheme.ink.opacity(0.08), in: Capsule())
            .accessibilityLabel("\(depth)-ply analysis")
    }
}

/// Whose move a review card is — "You" (amber) or the AI persona "TavTav" (#132).
private struct MoverChip: View {
    let label: String
    let isHuman: Bool
    var body: some View {
        let tint = isHuman ? ChromeTheme.undoTint : ReviewTint.best
        Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
    }
}

// ── Win-probability chart (#105) ──────────────────────────────────────────────

/// Win-probability trajectory across the reviewed game, drawn as a little **window
/// of the board**: the mahogany play surface gives the ivory-White trace the same
/// contrast it has as a checker (cream-on-cream was invisible). Time runs left→right
/// (evaluated plies in order); win probability runs bottom→top, **normalized to
/// White's perspective**. Labelled reference lines bound the scale — top = a certain
/// White win, bottom = a certain Red win, dashed centre = even — so it's clear where
/// the maximum sits. The band between the centre and the trace is filled with a soft
/// tint of the leading side's checker colour (#105 note); the trace uses the full
/// checker colour over a dark casing, switching colour wherever it crosses the
/// centre. Colours come from `CaramelPalette` (the central board palette), so a
/// future theme change propagates. Blunder plies are ringed in the board's
/// move-highlight amber (#105). Tapping or dragging scrubs to the nearest move.
private struct WinProbabilityChart: View {
    let evaluations: [PlyEvaluation]
    /// `plyNumber` of the move currently shown — marked with a solid dot.
    let selectedPly: Int
    /// Ply numbers flagged as blunders — ringed in amber.
    let blunders: Set<Int>
    /// Called with a tapped/scrubbed `plyNumber`; the caller snaps to the nearest move.
    let onScrub: (Int) -> Void

    /// Soft band fill: the checker colour at low opacity over the mahogany surface.
    /// Tune here if the bands feel too strong or too faint.
    private static let fillOpacity = 0.32
    private static let insetX: CGFloat = 10
    private static let insetY: CGFloat = 14
    private static let corner: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in draw(into: ctx, size: size) }
                .contentShape(Rectangle())
                .highPriorityGesture(            // beat the ancestor paging swipe
                    DragGesture(minimumDistance: 0)
                        .onChanged { scrub(atX: $0.location.x, width: geo.size.width) }
                )
        }
        .frame(height: 96)
        .accessibilityLabel("Win chance through the game")
    }

    // ── Drawing ──────────────────────────────────────────────────────────────

    private func draw(into ctx: GraphicsContext, size: CGSize) {
        let n = evaluations.count

        // Mahogany "board window" surface + framed border (fixes White contrast and
        // gives the scale a visible ceiling/floor).
        let card = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Self.corner)
        ctx.fill(card, with: .linearGradient(
            Gradient(colors: [CaramelPalette.playTop, CaramelPalette.playBot]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        ctx.stroke(card, with: .color(.black.opacity(0.35)), lineWidth: 1.5)

        let left = Self.insetX, right = size.width - Self.insetX
        let top = Self.insetY, bottom = size.height - Self.insetY
        let yc = (top + bottom) / 2

        func x(_ i: Int) -> CGFloat {
            n <= 1 ? size.width / 2 : left + (right - left) * CGFloat(i) / CGFloat(n - 1)
        }
        func y(_ wp: Double) -> CGFloat { top + (1 - wp) * (bottom - top) }   // top = wp 1

        // Scale references: certain-White (top), even (centre, dashed), certain-Red (bottom).
        rule(ctx, from: left, to: right, y: top, color: CaramelPalette.whiteFill.opacity(0.30))
        rule(ctx, from: left, to: right, y: bottom, color: CaramelPalette.redFill.opacity(0.45))
        rule(ctx, from: left, to: right, y: yc, color: CaramelPalette.triangleFill.opacity(0.22),
             dash: [3, 3])
        label(ctx, "White", at: CGPoint(x: left + 1, y: top + 1), anchor: .topLeading,
              color: CaramelPalette.whiteFill.opacity(0.85))
        label(ctx, "Red", at: CGPoint(x: left + 1, y: bottom - 1), anchor: .bottomLeading,
              color: CaramelPalette.redHi.opacity(0.9))

        guard n >= 2 else {
            if let e = evaluations.first {
                let p = CGPoint(x: x(0), y: y(whiteProb(e)))
                if blunders.contains(e.plyNumber) { drawRing(ctx, at: p) }
                drawDot(ctx, at: p, above: whiteProb(e) > 0.5)
            }
            return
        }

        let pts = evaluations.enumerated().map { i, e in
            (CGPoint(x: x(i), y: y(whiteProb(e))), whiteProb(e) > 0.5)
        }

        // Soft bands, split wherever the line crosses centre so each side keeps its
        // colour (no bow-tie at a crossing).
        for k in 0..<(pts.count - 1) {
            for (s, e, above) in segments(pts[k].0, pts[k].1, pts[k + 1].0, pts[k + 1].1, yc: yc) {
                var band = Path()
                band.move(to: CGPoint(x: s.x, y: yc))
                band.addLine(to: s)
                band.addLine(to: e)
                band.addLine(to: CGPoint(x: e.x, y: yc))
                band.closeSubpath()
                ctx.fill(band, with: .color(fillColor(above: above)))
            }
        }

        // Dark casing under the whole trace, then the checker-coloured segments on top.
        var trace = Path()
        trace.move(to: pts[0].0)
        for k in 1..<pts.count { trace.addLine(to: pts[k].0) }
        ctx.stroke(trace, with: .color(.black.opacity(0.40)),
                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        for k in 0..<(pts.count - 1) {
            for (s, e, above) in segments(pts[k].0, pts[k].1, pts[k + 1].0, pts[k + 1].1, yc: yc) {
                var line = Path(); line.move(to: s); line.addLine(to: e)
                ctx.stroke(line, with: .color(lineColor(above: above)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }

        // Amber rings on every blunder (drawn under the selected dot, so a selected
        // blunder shows the dot inside its ring).
        for (idx, e) in evaluations.enumerated() where blunders.contains(e.plyNumber) {
            drawRing(ctx, at: pts[idx].0)
        }

        // Selected-move dot.
        if let sel = evaluations.firstIndex(where: { $0.plyNumber == selectedPly }) {
            drawDot(ctx, at: pts[sel].0, above: pts[sel].1)
        }
    }

    /// Win probability from **White's** perspective for an evaluated ply.
    private func whiteProb(_ e: PlyEvaluation) -> Double {
        let s = Double(e.playedScore)
        return e.mover == .white ? s : 1 - s
    }

    /// Split a segment at the centre line so each part lies entirely on one side.
    /// Returns `(start, end, above)` tuples (`above` = White ahead).
    private func segments(_ a: CGPoint, _ aboveA: Bool, _ b: CGPoint, _ aboveB: Bool,
                          yc: CGFloat) -> [(CGPoint, CGPoint, Bool)] {
        guard aboveA != aboveB, b.y != a.y else { return [(a, b, aboveA)] }
        let t = (yc - a.y) / (b.y - a.y)
        let cross = CGPoint(x: a.x + t * (b.x - a.x), y: yc)
        return [(a, cross, aboveA), (cross, b, aboveB)]
    }

    private func rule(_ ctx: GraphicsContext, from x0: CGFloat, to x1: CGFloat, y: CGFloat,
                      color: SColor, dash: [CGFloat] = []) {
        var p = Path(); p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
    }

    private func label(_ ctx: GraphicsContext, _ s: String, at p: CGPoint, anchor: UnitPoint,
                       color: SColor) {
        ctx.draw(Text(s).font(.system(size: 9, weight: .semibold)).foregroundColor(color),
                 at: p, anchor: anchor)
    }

    private func drawDot(_ ctx: GraphicsContext, at p: CGPoint, above: Bool) {
        let r: CGFloat = 4.5
        let disc = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(disc, with: .color(lineColor(above: above)))
        ctx.stroke(disc, with: .color(.black.opacity(0.55)), lineWidth: 1.5)
    }

    /// Hollow amber ring marking a blunder ply.
    private func drawRing(_ ctx: GraphicsContext, at p: CGPoint) {
        let r: CGFloat = 6
        let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.stroke(ring, with: .color(.black.opacity(0.35)), lineWidth: 3)   // casing for contrast
        ctx.stroke(ring, with: .color(CaramelPalette.hl), lineWidth: 2)
    }

    private func fillColor(above: Bool) -> SColor {
        (above ? CaramelPalette.whiteFill : CaramelPalette.redFill).opacity(Self.fillOpacity)
    }
    private func lineColor(above: Bool) -> SColor {
        above ? CaramelPalette.whiteFill : CaramelPalette.redFill
    }

    // ── Interaction ──────────────────────────────────────────────────────────

    private func scrub(atX gx: CGFloat, width: CGFloat) {
        guard !evaluations.isEmpty else { return }
        let n = evaluations.count
        let plotW = max(1, width - 2 * Self.insetX)
        let frac = Double((gx - Self.insetX) / plotW)
        let i = min(n - 1, max(0, Int((frac * Double(n - 1)).rounded())))
        onScrub(evaluations[i].plyNumber)
    }
}

// MARK: - Previews

#Preview("Review — with blunders") {
    let board = GameBoard()
    board.initializeBoard()
    let stacks = board.points.map(\.pieces)
    func ev(_ ply: Int, _ played: Float, _ best: Float) -> PlyEvaluation {
        PlyEvaluation(plyNumber: ply, die1: 4, die2: 2, boardStacks: stacks,
                      mover: .white, playedMove: [[1, 5]], playedScore: played,
                      bestMove: [[1, 3]], bestScore: best)
    }
    // A trajectory that swings across the centre a few times, with a few blunders.
    let traj = [ev(2, 0.52, 0.55), ev(4, 0.60, 0.62), ev(6, 0.48, 0.66), ev(8, 0.43, 0.50),
                ev(10, 0.55, 0.58), ev(12, 0.62, 0.64), ev(14, 0.70, 0.72), ev(16, 0.40, 0.68),
                ev(18, 0.58, 0.60), ev(20, 0.66, 0.69)]
    return GameReviewView(previewPhase: .reviewing(finished: true), trajectory: traj)
}

#Preview("Review — no blunders") {
    let board = GameBoard()
    board.initializeBoard()
    let stacks = board.points.map(\.pieces)
    func ev(_ ply: Int, _ played: Float, _ best: Float) -> PlyEvaluation {
        PlyEvaluation(plyNumber: ply, die1: 4, die2: 2, boardStacks: stacks,
                      mover: .white, playedMove: [[1, 5]], playedScore: played,
                      bestMove: [[1, 3]], bestScore: best)
    }
    // Every move within a hair of best → no blunders, but still reviewable.
    let traj = [ev(2, 0.52, 0.53), ev(4, 0.58, 0.59), ev(6, 0.50, 0.50),
                ev(8, 0.55, 0.56), ev(10, 0.61, 0.62), ev(12, 0.57, 0.58)]
    return GameReviewView(previewPhase: .reviewing(finished: true), trajectory: traj)
}

#Preview("Nothing to review") {
    GameReviewView(previewPhase: .nothingToReview)
}

#Preview("Analyzing") {
    GameReviewView(previewPhase: .analyzing(done: 7, total: 18))
}
