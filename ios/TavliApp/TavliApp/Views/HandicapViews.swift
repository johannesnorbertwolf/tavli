import SwiftUI
import BoardGeometry
import TavliEngine

fileprivate typealias EngineColor = TavliEngine.Color

// Handicap chrome (#148, tier 1). Every view here renders only in a handicap game (or
// the builder); with handicaps off none of them is on screen (concept §7).

// MARK: - Estimate

/// Computes the builder's / tag's win-chance estimate off the main actor: the net's
/// position estimate (head start ± moves first) plus the measured dice-lever table.
@MainActor
final class HandicapEstimateModel: ObservableObject {
    @Published private(set) var estimate: HandicapEstimate?
    @Published private(set) var computing = false
    /// The net is not bundled (no estimate possible).
    @Published private(set) var unavailable = false

    private var task: Task<Void, Never>?
    private var lastKey: String?
    private static var agent: Agent?

    func update(setup: HandicapSetup, rule: HandicapStartRule) {
        let key = "\(setup.hashValue)-\(rule)"
        guard key != lastKey else { return }
        lastKey = key
        task?.cancel()
        let table = HandicapTableResource.table
        // The net sees only the position levers (tier-2 levers come from the table, §11),
        // so a tier-2-only change reuses the last position estimate: instant update.
        let positionKey = "\(setup.tier1Only.hashValue)-\(rule)"
        if positionKey == lastPositionKey, let position = lastPosition {
            computing = false
            estimate = HandicapEstimator.combine(positionWhite: position, setup: setup, table: table)
            return
        }
        let config = GameSettingsConfig.plakoto
        guard let agent = Self.agent ?? ModelCatalog.main.makeAgent(config: config) else {
            unavailable = true
            estimate = nil
            return
        }
        Self.agent = agent
        computing = true
        task = Task { [weak self] in
            let position = await Task.detached(priority: .userInitiated) {
                try? HandicapEstimator.positionWhiteWinChance(setup: setup, agent: agent, rule: rule)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.computing = false
            if let position {
                self.lastPositionKey = positionKey
                self.lastPosition = position
                self.estimate = HandicapEstimator.combine(positionWhite: position, setup: setup, table: table)
            }
        }
    }

    private var lastPositionKey: String?
    private var lastPosition: Double?
}

/// The house-Plakoto config the estimate runs under.
private enum GameSettingsConfig {
    static let plakoto = GameConfig(variant: GameVariants.plakoto)
}

/// "Estimated win chance: You 61% · Computer 39%" + the notes and the footnote.
struct HandicapEstimateView: View {
    let estimate: HandicapEstimate?
    var computing = false
    var unavailable = false
    /// Name and colour of side A ("You"/"White") and B ("Computer"/"Red").
    let aName: String
    let bName: String
    /// Which engine colour side A is (the estimate is White's).
    let aColor: TavliEngine.Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if unavailable {
                Text("Estimate needs the computer's model, which isn't available.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            } else if let estimate {
                let a = aColor == .white ? estimate.whiteWinChance : 1 - estimate.whiteWinChance
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(estimate.approximate ? "Estimated win chance (approx.)" : "Estimated win chance")
                        .font(ChromeType.subheadline.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    if computing { ProgressView().controlSize(.small) }
                }
                Text("\(aName) \(pct(a)) · \(bName) \(pct(1 - a))")
                    .font(ChromeType.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(ChromeTheme.ink)
                    .accessibilityIdentifier("handicapEstimate")
                if !estimate.unmeasured.isEmpty {
                    Text(unmeasuredLine(estimate.unmeasured))
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                }
                if estimate.approximate {
                    Text("Hints aren't counted: what they're worth depends on the player.")
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                }
                Text("If both played at the computer's full strength.")
                    .font(ChromeType.caption.italic())
                    .foregroundStyle(ChromeKit.inkSecondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Estimating…")
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pct(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }

    private func unmeasuredLine(_ kinds: [String]) -> String {
        let line: String
        switch Set(kinds) {
        case ["weighted_dice", "rerolls"]: line = String(localized: "Weighted dice and rerolls")
        case ["weighted_dice"]:            line = String(localized: "Weighted dice")
        default:                           line = String(localized: "Rerolls")
        }
        return String(localized: "\(line): not measured yet, so not in the number.")
    }
}

// MARK: - Settings row

/// The one Settings row (#148): "Handicap" + "Off" or a short summary; opens the builder.
struct HandicapSettingsRow: View {
    @AppStorage(HandicapPreferences.storageKey) private var raw = ""
    @State private var showBuilder = false

    var body: some View {
        Button { showBuilder = true } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Handicap")
                        .font(ChromeType.body.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    Text(HandicapPreferences.decode(raw).summary)
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.iconInk)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chromeCard(padding: 20)
        .accessibilityIdentifier("handicapRow")
        .sheet(isPresented: $showBuilder) {
            HandicapSettingsView()
        }
    }
}

// MARK: - In-game tag

/// The small "Handicap" tag in the game's top bar (only in a handicap game). Tapping it
/// shows the setup, the estimate and the dice disclosure.
struct HandicapTagButton: View {
    @ObservedObject var session: GameSession
    var compact = false
    @State private var showInfo = false

    var body: some View {
        if session.handicap != nil {
            Button { showInfo = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scalemass")
                    if !compact { Text("Handicap") }
                }
                .font(ChromeType.caption.weight(.semibold))
            }
            .buttonStyle(ChromeButton(role: .secondary))
            .accessibilityLabel("Handicap")
            .accessibilityIdentifier("handicapTag")
            .sheet(isPresented: $showInfo) {
                HandicapInfoSheet(session: session)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}

/// The tag's sheet: the setup line by line, tokens left, and the estimate for this game.
struct HandicapInfoSheet: View {
    @ObservedObject var session: GameSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = HandicapEstimateModel()

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Handicap")
                            .font(ChromeType.statsTitle)
                            .foregroundStyle(ChromeTheme.ink)
                        Spacer()
                        Button("Done") { dismiss() }
                            .buttonStyle(ChromeButton(role: .secondary))
                    }
                    if let state = session.handicap {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(HandicapCopy.lines(state.setup, aiColor: session.aiColor), id: \.self) { line in
                                Label(line, systemImage: "checkmark.circle")
                                    .font(ChromeType.callout)
                                    .foregroundStyle(ChromeTheme.ink)
                            }
                            ForEach(tokenLines(state), id: \.self) { line in
                                Text(line)
                                    .font(ChromeType.caption)
                                    .foregroundStyle(ChromeKit.inkSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .chromeCard(padding: 16)

                        HandicapEstimateView(estimate: model.estimate, computing: model.computing,
                                             unavailable: model.unavailable,
                                             aName: HandicapCopy.name(sideA, aiColor: session.aiColor),
                                             bName: HandicapCopy.name(sideA.opponent, aiColor: session.aiColor),
                                             aColor: sideA)
                            .chromeCard(padding: 16)
                            .onAppear {
                                model.update(setup: state.setup, rule: .fixed(session.startingPlayer))
                            }
                        Text("Win chances in the review and the win-probability bar still assume fair dice.")
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .opacity(state.setup.altersDice ? 1 : 0)
                    }
                }
                .compactPadding(24, compact: 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// The human ("You") vs the computer, White for two players.
    private var sideA: EngineColor { session.aiColor?.opponent ?? .white }

    private func tokenLines(_ s: HandicapGameState) -> [String] {
        var out: [String] = []
        for c in [EngineColor.white, .black] {
            let who = HandicapCopy.name(c, aiColor: session.aiColor)
            if s.setup[c].rerolls > 0 { out.append(String(localized: "\(who): rerolls left \(s.rerollsLeft[c]) of \(s.setup[c].rerolls)")) }
            if s.setup[c].hints > 0 { out.append(String(localized: "\(who): hints left \(s.hintsLeft[c]) of \(s.setup[c].hints)")) }
        }
        return out
    }
}

// MARK: - Reroll / Hint

/// "Reroll (n left)" / "Hint (n left)" for the human on move, plus the computer's
/// reroll note. Only in a handicap game; shown above Undo/Done.
struct HandicapActionsRow: View {
    @ObservedObject var session: GameSession

    fileprivate var mover: EngineColor { session.currentPlayer }
    private var isHumanTurn: Bool { session.aiColor == nil || session.aiColor != mover }
    fileprivate var rerolls: Int { session.rerollsLeft(mover) }
    fileprivate var hints: Int { session.hintsLeft(mover) }
    private var rolled: Bool { session.phase == .picking || session.phase == .moving }

    var body: some View {
        VStack(spacing: 6) {
            if isHumanTurn && (rerolls > 0 || hints > 0) && !session.isTerminal {
                // Side by side when they fit (iPhone portrait, iPad portrait), stacked in
                // a narrow rail (iPad landscape panel, iPhone landscape).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { buttons }
                    VStack(spacing: 8) { buttons }
                }
            }
            if session.hint != nil && rolled {
                Text("Best move shown in blue")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            } else if let c = session.lastComputerReroll, session.aiColor == c {
                Text("Computer used a reroll (\(session.rerollsLeft(c)) left)")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

extension HandicapActionsRow {
    @ViewBuilder fileprivate var buttons: some View {
        if rerolls > 0 {
            Button { session.reroll() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "dice")
                    Text("Reroll (\(rerolls) left)")
                }
                .fixedSize()
            }
            .buttonStyle(ChromeButton(role: .secondary))
            .disabled(!session.canReroll)
            .opacity(session.canReroll ? 1 : 0.4)
            .accessibilityIdentifier("rerollButton")
        }
        if hints > 0 || session.hint != nil {
            Button { session.requestHint() } label: {
                HStack(spacing: 4) {
                    if session.hintPending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "lightbulb")
                    }
                    Text("Hint (\(hints) left)")
                }
                .fixedSize()
            }
            .buttonStyle(ChromeButton(role: .secondary))
            .disabled(!session.canHint)
            .opacity(session.canHint || session.hintPending ? 1 : 0.4)
            .accessibilityIdentifier("hintButton")
        }
    }
}

// MARK: - Review note and record block

/// The review's one-line note for games whose dice were not fair.
struct HandicapReviewNote: View {
    var body: some View {
        Label("Handicap game: win chances assume fair dice", systemImage: "scalemass")
            .font(ChromeType.caption)
            .foregroundStyle(ChromeKit.inkSecondary)
            .accessibilityIdentifier("handicapReviewNote")
    }
}

/// My Record's separate "Handicap games" block (only once at least one exists).
struct HandicapRecordBlock: View {
    let stats: HumanGameStats

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Handicap games")
                .font(ChromeType.headline)
                .foregroundStyle(ChromeTheme.ink)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(stats.wins)W – \(stats.losses)L")
                    .font(ChromeType.title3.bold())
                    .foregroundStyle(ChromeTheme.ink)
                Text(stats.total == 1 ? String(localized: "1 game")
                                      : String(localized: "\(stats.total) games"))
                    .font(ChromeType.subheadline)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            Text("Not counted in your record against the computer.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
        .frame(maxWidth: 352, alignment: .leading)
        .chromeCard(padding: ChromeType.isCompact ? 16 : 24)
        .accessibilityIdentifier("handicapRecord")
    }
}

// MARK: - Tier-2 board cues

/// Board cues for a tier-2 handicap game (#148 P3b), drawn over the empty board and under
/// the checkers. Renders nothing without rules. Per side:
/// - **Safe point**: a small shield in the side's checker colour on the frame strip at the
///   base of that point (its lone checker there can't be pinned).
/// - **Smaller home**: the points of its six-point home quadrant that no longer count are
///   dimmed, and a line in its checker colour runs along the frame under the points that do.
struct HandicapBoardCuesView: View {
    let rules: HandicapRules?
    var flipped = false

    var body: some View {
        Canvas { context, size in
            guard let rules else { return }
            let geo = BoardGeometry(rect: CGRect(origin: .zero, size: size), flipped: flipped)
            for color in [EngineColor.white, .black] {
                drawHome(&context, geo: geo, color: color, size: rules[color].homeSize)
            }
            for color in [EngineColor.white, .black] where rules[color].safePoint > 0 {
                drawSafe(&context, geo: geo, color: color, index: rules.safeSlot(color, boardSize: 24))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Board index of `color`'s own point `p` (1 = its start).
    private func index(_ color: EngineColor, _ p: Int) -> Int { color == .white ? p : 25 - p }

    private func drawHome(_ context: inout GraphicsContext, geo: BoardGeometry, color: EngineColor, size: Int) {
        guard size < HandicapSetup.normalHomeSize else { return }
        let s = geo.scale
        // Own points 19…24 are the home quadrant; the last `size` of them count.
        for p in 19...(24 - size) {
            let pt = geo.point(index(color, p))
            var tri = Path()
            tri.move(to: pt.baselineLeft)
            tri.addLine(to: pt.baselineRight)
            tri.addLine(to: pt.tip)
            tri.closeSubpath()
            context.fill(tri, with: .color(CaramelPalette.homeCueShade))
        }
        let style = CheckerStyle.of(color)
        let counting = ((25 - size)...24).map { geo.point(index(color, $0)) }
        let xs = counting.flatMap { [$0.baselineLeft.x, $0.baselineRight.x] }
        guard let lo = xs.min(), let hi = xs.max(), let first = counting.first else { return }
        let y = first.isTop ? first.baselineLeft.y - geo.frameInset * 0.32
                            : first.baselineLeft.y + geo.frameInset * 0.32
        var line = Path()
        line.move(to: CGPoint(x: lo + 4 * s, y: y))
        line.addLine(to: CGPoint(x: hi - 4 * s, y: y))
        context.stroke(line, with: .color(style.edge), style: StrokeStyle(lineWidth: 6 * s, lineCap: .round))
        context.stroke(line, with: .color(style.fill), style: StrokeStyle(lineWidth: 4 * s, lineCap: .round))
    }

    private func drawSafe(_ context: inout GraphicsContext, geo: BoardGeometry, color: EngineColor, index i: Int) {
        let pt = geo.point(i)
        let s = geo.scale
        let mid = CGPoint(x: (pt.baselineLeft.x + pt.baselineRight.x) / 2,
                          y: pt.isTop ? pt.baselineLeft.y - geo.frameInset * 0.5
                                      : pt.baselineLeft.y + geo.frameInset * 0.5)
        let style = CheckerStyle.of(color)
        let h = geo.frameInset * 0.78
        var outline = context.resolve(Image(systemName: "shield.fill"))
        outline.shading = .color(style.edge)
        context.draw(outline, in: CGRect(x: mid.x - h * 0.5 - 1.2 * s, y: mid.y - h * 0.5 - 1.2 * s,
                                         width: h + 2.4 * s, height: h + 2.4 * s))
        var shield = context.resolve(Image(systemName: "shield.fill"))
        shield.shading = .color(style.fill)
        context.draw(shield, in: CGRect(x: mid.x - h * 0.5, y: mid.y - h * 0.5, width: h, height: h))
    }
}
