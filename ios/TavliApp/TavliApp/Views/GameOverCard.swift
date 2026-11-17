import SwiftUI
import TavliEngine

/// A button on the card: label, SF Symbol, action and an accessibility identifier.
struct GameOverAction {
    let label: String
    let icon: String
    let action: () -> Void
    var identifier: String? = nil
}

/// The running score line: "You  1 – 0  TavTav" + a caption ("Game 1 of 3").
struct GameOverScore {
    let leftName: String
    let left: Int
    let right: Int
    let rightName: String
    let caption: String
}

/// The one game-over surface (win / draw, best-of-three, Full Tavli leg): a single
/// centred solid card (`.chromeCard()`, ink text, normal `ChromeButton` roles) over
/// the caller's dim scrim, so nothing behind it — status text, dice, checkers — can
/// collide with the verdict. Every overlay builds on this, so they look identical.
/// Presentation only: the copy and every action come from the caller.
///
/// Layout, top to bottom: TavTav avatar (iPad only), verdict, subtitle (points /
/// draw reason), optional score block, optional extra content (the vs-AI record),
/// the primary action (full width), Review / History, then an optional exit.
/// ≤ 440 pt wide on iPad; full width minus a gutter on a phone, scrolling only when
/// it can't fit (iPhone landscape).
struct GameOverCard<Extra: View>: View {
    let title: String
    var subtitle: String? = nil
    var score: GameOverScore? = nil
    /// TavTav's persona (smirk if it won); `nil` for human-vs-human. iPad only.
    var mascot: TavTavPersona? = nil
    let primary: GameOverAction
    /// `nil` hides Review (no model, online, or nothing reviewable).
    var onReview: (() -> Void)? = nil
    var onHistory: (() -> Void)? = nil
    /// "Back to menu" (or similar), shown last as a quiet action.
    var exit: GameOverAction? = nil
    @ViewBuilder var extra: Extra

    @Environment(\.chromeMode) private var chromeMode
    private var compact: Bool { chromeMode.isCompact }

    var body: some View {
        FitOrScroll(enabled: compact) {
            card
                .padding(.horizontal, 16)
                .padding(.vertical, compact ? 8 : 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        VStack(spacing: compact ? 12 : 20) {
            if let mascot, !compact {
                TavTavAvatar(persona: mascot, size: 96)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(ChromeType.winTitle)
                    .foregroundStyle(ChromeTheme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("gameOverTitle")
                if let subtitle {
                    Text(subtitle)
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let score {
                scoreBlock(score)
            }
            extra
            VStack(spacing: 10) {
                Button(action: primary.action) {
                    HStack(spacing: 6) {
                        Image(systemName: primary.icon)
                        Text(primary.label)
                    }
                }
                .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                .accessibilityIdentifier(primary.identifier ?? "gameOverPrimary")
                secondaryRow
                if let exit {
                    Button(action: exit.action) {
                        HStack(spacing: 6) {
                            Image(systemName: exit.icon)
                            Text(exit.label)
                        }
                    }
                    .buttonStyle(ChromeButton(role: .quiet))
                    .accessibilityIdentifier(exit.identifier ?? "gameOverExit")
                }
            }
        }
        .frame(maxWidth: 440)
        .chromeCard(padding: compact ? 16 : 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gameOverCard")
    }

    /// Review / History side by side, sharing the width (stacked if they can't fit).
    @ViewBuilder
    private var secondaryRow: some View {
        if onReview != nil || onHistory != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { secondaryButtons }
                VStack(spacing: 10) { secondaryButtons }
            }
        }
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        if let onReview {
            Button(action: onReview) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Review game")
                }
            }
            .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            .accessibilityIdentifier("gameOverReview")
        }
        if let onHistory {
            Button(action: onHistory) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("History")
                }
            }
            .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
        }
    }

    /// Same type as the in-game scoreboard: names in callout, the digits bold lining
    /// figures (`title3`, monospaced).
    private func scoreBlock(_ s: GameOverScore) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Text(s.leftName)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Text(verbatim: "\(s.left) – \(s.right)")
                    .font(ChromeType.title3.bold().monospacedDigit())
                    .foregroundStyle(ChromeTheme.ink)
                Text(s.rightName)
                    .font(ChromeType.callout)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(s.caption)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(ChromeTheme.ink.opacity(0.06))
        .cornerRadius(ChromeKit.buttonRadius)
        .accessibilityElement(children: .combine)
    }
}

extension GameOverCard where Extra == EmptyView {
    init(title: String, subtitle: String? = nil, score: GameOverScore? = nil,
         mascot: TavTavPersona? = nil, primary: GameOverAction,
         onReview: (() -> Void)? = nil, onHistory: (() -> Void)? = nil,
         exit: GameOverAction? = nil) {
        self.init(title: title, subtitle: subtitle, score: score, mascot: mascot,
                  primary: primary, onReview: onReview, onHistory: onHistory,
                  exit: exit, extra: { EmptyView() })
    }
}

/// Winner wording shared by every overlay and the status card: vs the AI or online
/// "You win" / "<opponent> wins" ("TavTav wins", or the Game Center name); in a
/// two-player game "White wins" / "Red wins".
struct WinnerNaming {
    /// The local player's colour (vs AI / online), or `nil` in a two-player game.
    let localColor: TavliEngine.Color?
    /// "TavTav" vs the AI, the opponent's display name online.
    let opponentName: String

    /// "You win" / "TavTav wins" / "Red wins".
    func title(_ winner: TavliEngine.Color) -> String {
        guard let localColor else {
            return String(localized: "\(ChromeTheme.displayName(winner)) wins")
        }
        return winner == localColor ? String(localized: "You win")
                                    : String(localized: "\(opponentName) wins")
    }

    /// "You win a double game" / "TavTav wins a double game" / "Red wins a double game".
    func doubleTitle(_ winner: TavliEngine.Color) -> String {
        guard let localColor else {
            return String(localized: "\(ChromeTheme.displayName(winner)) wins a double game")
        }
        return winner == localColor ? String(localized: "You win a double game")
                                    : String(localized: "\(opponentName) wins a double game")
    }
}
