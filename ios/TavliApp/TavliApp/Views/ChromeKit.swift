import SwiftUI
import BoardGeometry

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

    /// #191 dark mode: every colour token below (and `ChromeTheme`'s) is a
    /// `Color(light:dark:)` pair. The light value is the original one — light mode is
    /// unchanged — and the dark value is "C3 · Espresso + warm text"
    /// (`design/dark-mode/themes.js`): espresso-black page, warm-brown surfaces,
    /// cream-caramel text, tan secondary text, caramel accent with a dark label.

    /// The page behind every screen and sheet (`#ece6dc`; espresso-black in dark).
    static let pageColor = SwiftUI.Color(light: 0xece6dc, dark: 0x0e0805)

    /// Card surface — a touch brighter than the `#ece6dc` page so cards lift
    /// without borders.
    static let cardColor = SwiftUI.Color(light: 0xf6f0e3, dark: 0x1d130b)
    static let cardShadow = SwiftUI.Color(light: 0x000000, lightOpacity: 0.10, dark: 0x000000, darkOpacity: 0.35)
    /// Dark mode lifts cards with a 1 px warm hairline instead of the (invisible)
    /// shadow; clear in light mode.
    static let cardEdge = SwiftUI.Color(light: 0x000000, lightOpacity: 0, dark: 0xffbe6e, darkOpacity: 0.08)

    /// Secondary ink: the single allowed "dimmed" text color (contrast floor
    /// for captions; replaces the scattered 0.5/0.6 opacities). Dark: solid tan.
    static let inkSecondary = SwiftUI.Color(light: 0x3a2510, lightOpacity: 0.72, dark: 0xcf9f62)

    /// Dimmed text at a given light-mode ink opacity. Light: exactly
    /// `ChromeTheme.ink.opacity(opacity)`; dark: the tan secondary ink, so captions
    /// keep WCAG AA (≥ 4.5:1) on the dark surfaces instead of fading with the alpha.
    static func inkDim(_ opacity: Double) -> SwiftUI.Color {
        SwiftUI.Color(light: 0x3a2510, lightOpacity: opacity, dark: 0xcf9f62)
    }

    /// Icon ink (start-screen icon bar): ink at 75 % in light, warm tan in dark.
    static let iconInk = SwiftUI.Color(light: 0x3a2510, lightOpacity: 0.75, dark: 0xd9ad72)

    /// Label on a `.primary` (solid accent) button: white in light, dark on the
    /// brighter dark-mode caramel so it reads as lit, not muddy.
    static let onAccent = SwiftUI.Color(light: 0xffffff, dark: 0x140a02)

    /// The `.secondary` button tint (accent at 16 %; a warm 11 % veil in dark).
    static let secondaryFill = SwiftUI.Color(light: 0xa87a3e, lightOpacity: 0.16, dark: 0xffbe6e, darkOpacity: 0.11)
    static let secondaryFillPressed = SwiftUI.Color(light: 0xa87a3e, lightOpacity: 0.34, dark: 0xffbe6e, darkOpacity: 0.22)

    /// Choice controls (#189 new-game sheet): the recessed track behind a segmented
    /// choice / unselected chip, and the raised fill of the selected segment.
    static let trackColor = SwiftUI.Color(light: 0xe6dccb, dark: 0x0e0805)
    static let selectedSegmentColor = SwiftUI.Color(light: 0xfdf9f1, dark: 0x2b1c10)
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
            .overlay(
                RoundedRectangle(cornerRadius: ChromeKit.cardRadius)
                    .strokeBorder(ChromeKit.cardEdge, lineWidth: 1)
            )
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
enum ChromeButtonRole {
    case primary, secondary, destructive, quiet
}

struct ChromeButton: ButtonStyle {
    var role: ChromeButtonRole = .secondary
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ChromeType.callout.bold())
            .lineLimit(1)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .modifier(ChromeButtonPadding())
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
            return pressed ? ChromeKit.secondaryFillPressed : ChromeKit.secondaryFill
        case .destructive:
            return ChromeTheme.surrenderTint.opacity(pressed ? 0.30 : 0.14)
        case .quiet:
            return ChromeTheme.ink.opacity(pressed ? 0.08 : 0)
        }
    }

    private var label: SwiftUI.Color {
        switch role {
        case .primary:      return ChromeKit.onAccent
        case .secondary:    return ChromeTheme.ink
        case .destructive:  return ChromeTheme.surrenderTint
        case .quiet:        return ChromeKit.inkSecondary
        }
    }
}

/// The button's insets: 18 × 12 (≥ 44 pt tall with 19 pt text) on iPad; on a compact
/// screen (#109) a little tighter horizontally, with an explicit 44 pt floor because
/// the scaled-down text alone no longer guarantees it.
private struct ChromeButtonPadding: ViewModifier {
    func body(content: Content) -> some View {
        if ChromeType.isCompact {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
        } else {
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
    }
}

extension View {
    /// The `.secondary` `ChromeButton` look for labels that aren't `Button`s (a `Menu`
    /// label, #109), so a menu reads as one more button in the bar.
    func chromeSecondaryButtonSurface() -> some View {
        self
            .font(ChromeType.callout.bold())
            .lineLimit(1)
            .modifier(ChromeButtonPadding())
            .background(ChromeKit.secondaryFill)
            .foregroundStyle(ChromeTheme.ink)
            .cornerRadius(ChromeKit.buttonRadius)
            .contentShape(RoundedRectangle(cornerRadius: ChromeKit.buttonRadius))
    }

    /// Compact screens only (#109): keep a large display line (wordmark, win title)
    /// on one line by letting it shrink, instead of clipping a long DE/NL string.
    @ViewBuilder
    func compactSingleLine(minimumScale: CGFloat = 0.5) -> some View {
        if ChromeType.isCompact {
            self.lineLimit(1).minimumScaleFactor(minimumScale)
        } else {
            self
        }
    }

    /// Compact screens only (#109): the given padding instead of the iPad one.
    @ViewBuilder
    func compactPadding(_ regular: CGFloat, compact: CGFloat) -> some View {
        self.padding(ChromeType.isCompact ? compact : regular)
    }
}

// ── Compact layout (#109) ───────────────────────────────────────────────────

extension ChromeLayout {
    /// The layout for a `GeometryReader`: its size plus its safe-area insets is the
    /// container (the reader itself sits inside the safe area).
    init(_ proxy: GeometryProxy) {
        let i = proxy.safeAreaInsets
        self.init(container: CGSize(width: proxy.size.width + i.leading + i.trailing,
                                    height: proxy.size.height + i.top + i.bottom),
                  safeArea: SafeAreaInsets(top: i.top, leading: i.leading,
                                           bottom: i.bottom, trailing: i.trailing))
    }
}

private struct ChromeModeKey: EnvironmentKey {
    static let defaultValue: ChromeMode = .regular
}

extension EnvironmentValues {
    /// The chrome arrangement of the enclosing board screen (#109), so overlays and
    /// sub-views can tighten up without measuring again. `.regular` unless a screen
    /// sets it from its `ChromeLayout`.
    var chromeMode: ChromeMode {
        get { self[ChromeModeKey.self] }
        set { self[ChromeModeKey.self] = newValue }
    }
}

/// A row that falls back to a column when it doesn't fit the width — on compact
/// screens only (#109); on iPad it is exactly an `HStack`.
struct AdaptiveRow<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if ChromeType.isCompact {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: spacing) { content }
                VStack(spacing: spacing) { content }
            }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

/// Shows `content` as is when it fits the height, else inside a vertical
/// `ScrollView` (#109) — the safety net for tall stacks (win overlays, the landscape
/// rail) on a short phone screen. A plain pass-through when `enabled` is false.
struct FitOrScroll<Content: View>: View {
    var enabled: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        if enabled {
            ViewThatFits(in: .vertical) {
                content
                ScrollView(.vertical, showsIndicators: false) {
                    content.frame(maxWidth: .infinity)
                }
            }
        } else {
            content
        }
    }
}
