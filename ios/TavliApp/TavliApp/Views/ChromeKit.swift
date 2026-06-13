import SwiftUI

/// #101 — the chrome's shared visual language: flat tinted surfaces, soft
/// shadows, one button system, one card style. Everything outside the board
/// (picker, game chrome, overlays, sheets, debug pane) builds on these; the
/// board, dice and checkers keep their own Canvas styling. The palette stays
/// caramel (`ChromeTheme` / `CaramelPalette`); typography comes from
/// `ChromeType` (#92). Targets are sized for older players: every button
/// renders at ≥ 44 pt and secondary text never drops below 0.7 ink opacity.
enum ChromeKit {
    static let cardRadius: CGFloat = 16
    static let buttonRadius: CGFloat = 12

    /// Card surface — a touch brighter than the `#ece6dc` page so cards lift
    /// without borders.
    static let cardColor = SwiftUI.Color(hex: 0xf6f0e3)
    static let cardShadow = SwiftUI.Color.black.opacity(0.10)

    /// Secondary ink: the single allowed "dimmed" text color (contrast floor
    /// for captions; replaces the scattered 0.5/0.6 opacities).
    static let inkSecondary = ChromeTheme.ink.opacity(0.72)
}

// ── Cards ───────────────────────────────────────────────────────────────────

/// Flat card: padded content on the card surface with a soft drop shadow.
private struct ChromeCard: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ChromeKit.cardColor)
            .cornerRadius(ChromeKit.cardRadius)
            .shadow(color: ChromeKit.cardShadow, radius: 10, x: 0, y: 3)
    }
}

extension View {
    func chromeCard(padding: CGFloat = 20) -> some View {
        modifier(ChromeCard(padding: padding))
    }
}

// ── Buttons ─────────────────────────────────────────────────────────────────

/// The one chrome button language. Roles map to intent, not screen:
/// `.primary` — the single most important action on a surface (solid amber).
/// `.secondary` — everyday actions (flat caramel tint).
/// `.destructive` — game-ending actions (flat brick tint, brick label).
/// `.quiet` — low-emphasis inline actions (no fill).
/// `.scrim` — secondary actions on the dark win-overlay scrim.
enum ChromeButtonRole {
    case primary, secondary, destructive, quiet, scrim
}

struct ChromeButton: ButtonStyle {
    var role: ChromeButtonRole = .secondary
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ChromeType.callout.bold())
            .lineLimit(1)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)          // ≥ 44 pt tall with 19 pt text
            .background(fill(pressed: configuration.isPressed))
            .foregroundStyle(label)
            .cornerRadius(ChromeKit.buttonRadius)
            .contentShape(RoundedRectangle(cornerRadius: ChromeKit.buttonRadius))
    }

    private func fill(pressed: Bool) -> SwiftUI.Color {
        switch role {
        case .primary:
            return ChromeTheme.undoTint.opacity(pressed ? 0.8 : 1)
        case .secondary:
            return ChromeTheme.undoTint.opacity(pressed ? 0.34 : 0.16)
        case .destructive:
            return ChromeTheme.surrenderTint.opacity(pressed ? 0.30 : 0.14)
        case .quiet:
            return ChromeTheme.ink.opacity(pressed ? 0.08 : 0)
        case .scrim:
            return SwiftUI.Color.white.opacity(pressed ? 0.32 : 0.16)
        }
    }

    private var label: SwiftUI.Color {
        switch role {
        case .primary:      return .white
        case .secondary:    return ChromeTheme.ink
        case .destructive:  return ChromeTheme.surrenderTint
        case .quiet:        return ChromeKit.inkSecondary
        case .scrim:        return .white
        }
    }
}
