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
/// - `FullTavliInfoCard` — the start-screen card describing the sequence.

/// Labels shared by the Full Tavli views: "You"/opponent vs AI, "White"/"Red" two-player.
struct FullTavliNames {
    /// The human's colour vs the AI, or `nil` in a two-player session.
    let localColor: TavliEngine.Color?
    let opponentName: String

    init(session: FullTavliSession, opponentName: String = String(localized: "TavTav")) {
        localColor = session.aiColor?.opponent
        self.opponentName = opponentName
    }

    /// Left side of the score line (the human, or White).
    var leftColor: TavliEngine.Color { localColor ?? .white }
    var leftName: String { localColor == nil ? ChromeTheme.displayName(.white) : String(localized: "You") }
    var rightName: String { localColor == nil ? ChromeTheme.displayName(.black) : opponentName }

    /// "You win!" / "TavTav wins" / "Red wins" for a decided game or session.
    func winTitle(_ winner: TavliEngine.Color) -> String {
        if let localColor {
            return winner == localColor ? String(localized: "You win!")
                                        : String(localized: "\(opponentName) wins")
        }
        return String(localized: "\(ChromeTheme.displayName(winner)) wins")
    }

    /// The side that won a leg, as a short label ("You", "TavTav", "White", "Red").
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

/// Compact running score shown during every leg: "You 2 – 1 TavTav" and which leg is
/// on the board.
struct FullTavliScoreboardView: View {
    let state: FullTavliSession
    /// The leg on the board (0-based) — the session may already count it once over.
    let legIndex: Int
    /// One line — "You 1 – 0 TavTav · Game 2 of 3 · Fevga" — when it fits (#109).
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

/// Game-over takeover for one leg: the leg's verdict and points, the running score,
/// and "Continue" to the between-legs screen (or the final result after leg 3).
/// Mirrors `WinOverlayView`'s styling.
struct FullTavliLegOverlayView: View {
    /// The session, already including this leg's result.
    let state: FullTavliSession
    let legIndex: Int
    /// This leg's result (`nil` winner = draw).
    let result: MatchGameResult?
    let variant: any GameVariant
    let onContinue: () -> Void
    let onExit: () -> Void
    var onReview: (() -> Void)? = nil
    var onHistory: () -> Void = {}

    private var names: FullTavliNames { FullTavliNames(session: state) }

    private var mascot: TavTavPersona? {
        guard let ai = state.aiColor, let winner = result?.winner else { return nil }
        return winner == ai ? .smirk : .friendly
    }

    private var title: String {
        guard let result else { return String(localized: "Game over") }
        guard let w = result.winner else { return ResultCopy.drawTitle }
        return names.winTitle(w)
    }

    private var subtitle: String? {
        guard let result else { return nil }
        if result.isDraw { return ResultCopy.drawSubtitle }
        return ResultCopy.pointsSubtitle(points: result.points, variant: variant)
    }

    @Environment(\.chromeMode) private var chromeMode

    var body: some View {
        FitOrScroll(enabled: chromeMode.isCompact) {
            content
                .padding(.horizontal, chromeMode.isCompact ? 16 : 0)
                .padding(.vertical, chromeMode.isCompact ? 12 : 0)
        }
    }

    private var content: some View {
        VStack(spacing: chromeMode.isCompact ? 14 : 28) {
            if let mascot, !chromeMode.isCompact {
                TavTavAvatar(persona: mascot, size: 108)
            }
            Text(title)
                .font(ChromeType.winTitle)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(ChromeType.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 6) {
                Text("\(names.leftName) \(state.score(for: names.leftColor)) – \(state.score(for: names.leftColor.opponent)) \(names.rightName)")
                    .font(ChromeType.title2.bold().monospacedDigit())
                    .foregroundStyle(.white)
                Text(legCaption(index: legIndex, variantID: state.legVariantIDs[legIndex]))
                    .font(ChromeType.headline)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Image(systemName: state.isComplete ? "flag.checkered" : "arrow.right")
                    Text(state.isComplete ? String(localized: "See final result")
                                          : String(localized: "Continue"))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }
            .buttonStyle(ChromeButton(role: .primary))
            .accessibilityIdentifier("fullTavliContinue")
            AdaptiveRow(spacing: 14) {
                if let onReview {
                    Button(action: onReview) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                            Text("Review game")
                        }
                    }
                    .buttonStyle(ChromeButton(role: .scrim))
                }
                Button(action: onHistory) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("History")
                    }
                }
                .buttonStyle(ChromeButton(role: .scrim))
            }
            Button(action: onExit) {
                HStack(spacing: 6) {
                    Image(systemName: "house")
                    Text("Back to menu")
                }
            }
            .buttonStyle(ChromeButton(role: .scrim))
        }
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
                Text("\(state.score(for: names.leftColor)) – \(state.score(for: names.leftColor.opponent))")
                    .font(ChromeType.statsTitle.bold().monospacedDigit())
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

    /// "You · 2 points", "TavTav · 1 point", "Draw", or "–" for a leg still to play.
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

    private var mascot: TavTavPersona? {
        guard let ai = state.aiColor, let w = state.winner else { return nil }
        return w == ai ? .smirk : .friendly
    }

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    if let mascot, !ChromeType.isCompact {   // no mascot on iPhone (#109)
                        TavTavAvatar(persona: mascot, size: 108)
                    }
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

/// Start-screen card for Full Tavli mode (in place of the variant picker): the three
/// legs in order, each flagged "AI not available yet" when its model isn't bundled.
struct FullTavliInfoCard: View {
    /// The session the start buttons would create (its Plakoto leg per the preference).
    let preview: FullTavliSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Full Tavli")
                .font(ChromeType.body.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
            Text("The traditional session: three games in a row, points add up across all three. The higher total wins; equal totals are a draw.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(preview.legVariantIDs.enumerated()), id: \.offset) { i, id in
                let setting = GameVariantSetting(variantID: id)
                HStack(spacing: 8) {
                    Text("\(i + 1).")
                        .font(ChromeType.callout.monospacedDigit())
                        .foregroundStyle(ChromeKit.inkSecondary)
                    Text(setting.name)
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeTheme.ink)
                    if !AppSettings.aiAvailable(setting) {
                        AIUnavailableBadge()
                    }
                }
            }
            Text("The Plakoto rules follow your game choice in Settings.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
