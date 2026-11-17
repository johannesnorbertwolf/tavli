import SwiftUI
import TavliEngine

/// #143 — the game-variant choice, used by
/// the online lobby: a segmented picker over the four variants, then the selected
/// variant's full name and one-paragraph rules summary. With `showsAIAvailability`
/// a variant whose Core ML model isn't bundled yet is flagged "Computer not available yet"
/// (it stays playable two-player). Bound to the persisted `@AppStorage` setting by the
/// caller.
struct VariantPickerView: View {
    @Binding var selection: GameVariantSetting
    /// Flag variants without a bundled model (vs-AI surfaces only; online needs no model).
    var showsAIAvailability = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Game", selection: $selection) {
                ForEach(GameVariantSetting.allCases) { option in
                    Text(option.shortLabel).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(ChromeTheme.undoTint)
            HStack(spacing: 8) {
                Text(selection.name)
                    .font(ChromeType.body.weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
                if showsAIAvailability && !AppSettings.aiAvailable(selection) {
                    AIUnavailableBadge()
                }
            }
            Text(selection.summary)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Small capsule marking a variant whose AI model isn't bundled yet (#143).
struct AIUnavailableBadge: View {
    var body: some View {
        Text("Computer not available yet")
            .font(ChromeType.caption2.weight(.bold))
            .foregroundStyle(ChromeTheme.surrenderTint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(ChromeTheme.surrenderTint.opacity(0.12))
            .clipShape(Capsule())
    }
}

/// How an evaluation in `[0, 1]` is shown for a variant (#143). Plakoto's network
/// outputs a win probability ("Win chance 63%"); a variant with 2-point wins outputs
/// normalized expected points, shown as **equity** in points ("Equity +0.52",
/// range ±maxPoints) — calling it a win chance would be wrong.
struct EvalScale {
    let variant: any GameVariant

    init(variant: any GameVariant) { self.variant = variant }
    init(variantID: String) { self.variant = GameConfig(variantID: variantID).variant }

    var isEquity: Bool { variant.reportsEquity }

    /// "Win chance" / "Equity".
    var title: String {
        isEquity ? String(localized: "Equity") : String(localized: "Win chance")
    }

    /// A value for display: "63%" or "+0.52".
    func value(_ v: Double) -> String {
        isEquity ? String(format: "%+.2f", variant.equity(fromValue: v))
                 : "\(Int((v * 100).rounded()))%"
    }

    /// A non-negative gap between two values: "12%" or "0.48".
    func gap(_ d: Double) -> String {
        isEquity ? String(format: "%.2f", d * 2 * Double(variant.maxPoints))
                 : "\(Int((d * 100).rounded()))%"
    }

    /// "−12% win chance" / "−0.48 equity" — the cost of a move vs the best.
    func lossLabel(_ d: Double) -> String {
        isEquity ? String(localized: "−\(gap(d)) equity")
                 : String(localized: "−\(gap(d)) win chance")
    }
}

/// Verdict copy for a finished game (#143): draws and 2-point wins.
enum ResultCopy {
    /// Subtitle under the verdict for a variant with 2-point results ("2 points —
    /// double game"), or `nil` for Plakoto / a draw.
    static func pointsSubtitle(points: Int?, variant: any GameVariant) -> String? {
        guard variant.maxPoints > 1, let points, points > 0 else { return nil }
        return points >= 2 ? String(localized: "Double game · 2 points")
                           : String(localized: "Single game · 1 point")
    }

    static var drawTitle: String { String(localized: "Draw") }
    static var drawSubtitle: String { String(localized: "Both mother checkers are pinned — nobody scores.") }
}
