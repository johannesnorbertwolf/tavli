import SwiftUI
import BoardGeometry
import TavliEngine

private typealias SColor = SwiftUI.Color


/// #144 — Full Tavli chrome: the traditional Portes → Fevga → Plakoto session with a
/// running score. Presentation only; the score and leg sequence come from the engine's
/// `FullTavliSession` and every action is a closure supplied by `RootView`.
///
/// - `FullTavliScoreboardView` — compact score + "Game 2 of 3 · Fevga" during play.
/// - `FullTavliLegOverlayView` — the win overlay for a finished leg ("Continue").
/// - `FullTavliTransitionView` — between legs: running score + next game + rules line.
/// - `FullTavliResultView` — the session verdict with a per-leg breakdown.

/// Labels shared by the Full Tavli views: "You"/opponent vs AI, "White"/"Red" two-player.
struct FullTavliNames {
    /// The human's colour vs the AI, or `nil` in a two-player session.
    let localColor: TavliEngine.Color?
    let opponentName: String

    init(session: FullTavliSession, opponentName: String = String(localized: "Computer")) {
        localColor = session.aiColor?.opponent
        self.opponentName = opponentName
    }

    /// Left side of the score line (the human, or White).
    var leftColor: TavliEngine.Color { localColor ?? .white }
    var leftName: String { localColor == nil ? ChromeTheme.displayName(.white) : String(localized: "You") }
    var rightName: String { localColor == nil ? ChromeTheme.displayName(.black) : opponentName }

    /// The side that won a leg, as a short label ("You", "Computer", "White", "Red").
    func sideName(_ color: TavliEngine.Color) -> String {
        color == leftColor ? leftName : rightName
    }
}

/// "Game 2 of 3 · Fevga".
private func legCaption(index: Int, variantID: String) -> String {
    String(localized: "Game \(index + 1) of 3 · \(GameVariantSetting(variantID: variantID).legLabel)")
}

private extension GameVariantSetting {
    /// Short leg name: either Plakoto ruleset is simply "Plakoto" in the sequence.
    var legLabel: String {
        self == .plakotoStandard ? GameVariantSetting.plakoto.shortLabel : shortLabel
    }
}

/// Compact running score shown during every leg: "You 2 – 1 Computer" and which leg is
/// on the board.
struct FullTavliScoreboardView: View {
    let state: FullTavliSession
    /// The leg on the board (0-based) — the session may already count it once over.
    let legIndex: Int
    /// One line — "You 1 – 0 Computer · Game 2 of 3 · Fevga" — when it fits (#109).
    var compact = false

    private var names: FullTavliNames { FullTavliNames(session: state) }

    var body: some View {
        if compact {
            compactBody
        } else {
            regularBody
        }
    }

    private var compactBody: some View {
        let score = HStack(spacing: 6) {
            Text(names.leftName)
            Text("\(state.score(for: names.leftColor)) – \(state.score(for: names.leftColor.opponent))")
                .font(ChromeType.callout.bold().monospacedDigit())
                .foregroundStyle(ChromeTheme.ink)
            Text(names.rightName)
        }
        .lineLimit(1)
        let leg = Text(legCaption(index: legIndex, variantID: state.legVariantIDs[legIndex]))
            .lineLimit(1)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { score; Text(verbatim: "·"); leg }
            VStack(spacing: 2) { score; leg }
        }
        .font(ChromeType.caption)
        .foregroundStyle(ChromeKit.inkSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(ChromeTheme.ink.opacity(0.06))
        .cornerRadius(ChromeKit.buttonRadius)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullTavliScoreboard")
    }

    private var regularBody: some View {
        VStack(spacing: 4) {
            Text("Full Tavli")
                .font(ChromeType.caption2.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(ChromeKit.inkSecondary)
            HStack(spacing: 10) {
                Text(names.leftName)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Text("\(state.score(for: names.leftColor)) – \(state.score(for: names.leftColor.opponent))")
                    .font(ChromeType.title3.bold().monospacedDigit())
                    .foregroundStyle(ChromeTheme.ink)
                Text(names.rightName)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            Text(legCaption(index: legIndex, variantID: state.legVariantIDs[legIndex]))
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(ChromeTheme.ink.opacity(0.06))
        .cornerRadius(ChromeKit.buttonRadius)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fullTavliScoreboard")
    }
}

/// Game-over overlay for one leg: the leg's verdict and points, the running score,
/// and "Continue" to the between-legs screen (or the final result after leg 3). Built
/// on the shared `GameOverCard`, like the single-game and best-of-three overlays.
struct FullTavliLegOverlayView: View {
    /// The session, already including this leg's result.
    let state: FullTavliSession
    let legIndex: Int
    /// This leg's result (`nil` winner = draw).
    let result: MatchGameResult?
    let variant: any GameVariant
    let onContinue: () -> Void
    let onExit: () -> Void
    /// Winner wording shared with the other overlays and the status card.
    let naming: WinnerNaming
    /// `nil` hides Review (no model for the leg, or nothing reviewable).
    var onReview: (() -> Void)? = nil
    var onHistory: () -> Void = {}

    private var names: FullTavliNames { FullTavliNames(session: state) }

    private var title: String {
        guard let result else { return String(localized: "Game over") }
        guard let w = result.winner else { return ResultCopy.drawTitle }
        return naming.title(w)
    }

    private var subtitle: String? {
        guard let result else { return nil }
        if result.isDraw { return ResultCopy.drawSubtitle }
        return ResultCopy.pointsSubtitle(points: result.points, variant: variant)
    }

    var body: some View {
        GameOverCard(
            title: title,
            subtitle: subtitle,
            score: GameOverScore(leftName: names.leftName,
                                 left: state.score(for: names.leftColor),
                                 right: state.score(for: names.leftColor.opponent),
                                 rightName: names.rightName,
                                 caption: legCaption(index: legIndex,
                                                     variantID: state.legVariantIDs[legIndex])),
            primary: GameOverAction(
                label: state.isComplete ? String(localized: "See final result")
                                        : String(localized: "Continue"),
                icon: state.isComplete ? "flag.checkered" : "arrow.right",
                action: onContinue,
                identifier: "fullTavliContinue"),
            onReview: onReview,
            onHistory: onHistory,
            exit: GameOverAction(label: String(localized: "Back to menu"), icon: "house",
                                 action: onExit))
    }
}

/// The score card shared by the transition and result screens: the big running score
/// plus one row per leg (variant, winner, points; "–" for a leg not yet played).
private struct FullTavliScoreCard: View {
    let state: FullTavliSession

    private var names: FullTavliNames { FullTavliNames(session: state) }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                Text(names.leftName)
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeKit.inkSecondary)
                // Same digits as the in-game scoreboard (system face, lining
                // figures) — the display serif's old-style numerals read "o — ɪ".
                Text(verbatim: "\(state.score(for: names.leftColor)) – \(state.score(for: names.leftColor.opponent))")
                    .font(ChromeType.scoreDisplay.monospacedDigit())
                    .foregroundStyle(ChromeTheme.ink)
                Text(names.rightName)
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            VStack(spacing: 8) {
                ForEach(0..<FullTavliSession.legCount, id: \.self) { i in
                    legRow(i)
                }
            }
        }
        .frame(maxWidth: 420)
        .chromeCard(padding: ChromeType.isCompact ? 16 : 24)
    }

    private func legRow(_ i: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(i + 1).")
                .font(ChromeType.body.monospacedDigit())
                .foregroundStyle(ChromeKit.inkSecondary)
            Text(GameVariantSetting(variantID: state.legVariantIDs[i]).name)
                .font(ChromeType.body.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
            Spacer(minLength: 12)
            Text(outcome(i))
                .font(ChromeType.callout)
                .foregroundStyle(i < state.results.count ? ChromeTheme.ink : ChromeKit.inkSecondary)
        }
    }

    /// "You · 2 points", "Computer · 1 point", "Draw", or "–" for a leg still to play.
    private func outcome(_ i: Int) -> String {
        guard i < state.results.count else { return "–" }
        let r = state.results[i]
        guard let w = r.winner else { return ResultCopy.drawTitle }
        let side = names.sideName(w)
        return r.points == 1 ? String(localized: "\(side) · 1 point")
                             : String(localized: "\(side) · \(r.points) points")
    }
}

/// Between legs: the running score, the next game's name and a one-line rules
/// reminder, and "Start <variant>". Also where a session resumed between legs lands.
struct FullTavliTransitionView: View {
    let state: FullTavliSession
    let onStartNext: () -> Void
    let onExit: () -> Void

    private var next: GameVariantSetting? {
        state.currentVariant.map(GameVariantSetting.init(variant:))
    }

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Text("Full Tavli")
                        .font(ChromeType.wordmark)
                        .compactSingleLine()
                        .foregroundStyle(CaramelPalette.frameText)
                    FullTavliScoreCard(state: state)
                    if let next, let index = state.currentLegIndex {
                        VStack(spacing: 10) {
                            Text("Next: game \(index + 1) of 3")
                                .font(ChromeType.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(ChromeKit.inkSecondary)
                            Text(next.name)
                                .font(ChromeType.title2.bold())
                                .foregroundStyle(ChromeTheme.ink)
                            Text(next.rulesReminder)
                                .font(ChromeType.callout)
                                .foregroundStyle(ChromeKit.inkSecondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: 392)
                        .chromeCard(padding: ChromeType.isCompact ? 16 : 24)
                        Button(action: onStartNext) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.right")
                                Text("Start \(next.legLabel)")
                            }
                        }
                        .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                        .frame(maxWidth: 392)
                        .accessibilityIdentifier("fullTavliStartNext")
                    }
                    Button(action: onExit) {
                        HStack(spacing: 6) {
                            Image(systemName: "house")
                            Text("Back to menu")
                        }
                    }
                    .buttonStyle(ChromeButton(role: .secondary))
                }
                .compactPadding(40, compact: 16)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// After the third leg: the session verdict (or a drawn session) and the per-leg
/// breakdown, with a new session or the way back to the menu.
struct FullTavliResultView: View {
    let state: FullTavliSession
    let onPlayAgain: () -> Void
    let onExit: () -> Void

    private var names: FullTavliNames { FullTavliNames(session: state) }

    private var title: String {
        guard let w = state.winner else { return String(localized: "Drawn session") }
        if let local = names.localColor {
            return w == local ? String(localized: "You won the Full Tavli!")
                              : String(localized: "\(names.opponentName) won the Full Tavli")
        }
        return String(localized: "\(ChromeTheme.displayName(w)) wins the Full Tavli!")
    }

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Text(title)
                        .font(ChromeType.winTitle)
                        .foregroundStyle(CaramelPalette.frameText)
                        .multilineTextAlignment(.center)
                    if state.isDrawn {
                        Text("Equal points after three games — the session is drawn.")
                            .font(ChromeType.callout)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .multilineTextAlignment(.center)
                    }
                    FullTavliScoreCard(state: state)
                    Button(action: onPlayAgain) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text("New Full Tavli")
                        }
                    }
                    .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                    .frame(maxWidth: 392)
                    Button(action: onExit) {
                        HStack(spacing: 6) {
                            Image(systemName: "house")
                            Text("Back to menu")
                        }
                    }
                    .buttonStyle(ChromeButton(role: .secondary))
                }
                .compactPadding(40, compact: 16)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("fullTavliResult")
    }
}
