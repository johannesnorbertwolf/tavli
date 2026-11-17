import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// The remembered new-game setup (#189): what the start screen's play button starts
/// and the new-game sheet edits. Built from the four `@AppStorage` values the views
/// hold, so both stay live.
struct NewGameSetup {
    var variant: GameVariantSetting
    var level: Int
    var playAs: PreferredColorSetting
    var length: MatchLengthSetting

    var isFullTavli: Bool { length == .fullTavli }

    /// Whether the computer can play this setup: the variant's model is bundled, or for
    /// Full Tavli every leg's model (its Plakoto leg follows the variant, #144).
    var aiAvailable: Bool {
        isFullTavli
            ? FullTavliSession(preferredVariantID: variant.rawValue, aiColor: .black).isAIAvailable()
            : AppSettings.aiAvailable(variant)
    }

    /// The play button's subtitle: "Level 6 · Plakoto · Best of 3", or "Level 6 · Full
    /// Tavli" (Full Tavli ignores the variant).
    var summary: String {
        let parts = isFullTavli
            ? [AILevelCopy.name(level), length.label]
            : [AILevelCopy.name(level), variant.setupLabel, length.label]
        return parts.joined(separator: " · ")
    }

    /// "Computer is still learning …" (the no-model explanation, start screen + sheet).
    var unavailableMessage: String {
        isFullTavli
            ? String(localized: "TavTav is still learning some of the Full Tavli games. Play Full Tavli with two players for now.")
            : String(localized: "TavTav is still learning \(variant.name). Play it with two players for now.")
    }
}

/// #189 — "Play the computer": the new-game sheet, opened from the start screen's adjust
/// button. Variant (segmented + one-line rules reminder; dimmed for Full Tavli, which
/// plays all three), Level 1–8 (number chips + one-line description), Play as (White ·
/// Random · Red tiles with checker icons), Length (Single game · Best of 3 · Full Tavli
/// + caption) and a big Play. Every choice is persisted via `@AppStorage` as it is made
/// (defaults equal the `AppSettings` accessors), so the start screen's play button and
/// "Two players" reuse them. `onPlay` starts the game (the caller dismisses first).
struct NewGameSheet: View {
    let onPlay: () -> Void

    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.variant) private var variant: GameVariantSetting = .plakoto
    @AppStorage(SettingsKey.aiLevel) private var level = AILevel.max
    @AppStorage(SettingsKey.preferredColor) private var playAs: PreferredColorSetting = .white
    @AppStorage(SettingsKey.matchLength) private var length: MatchLengthSetting = .bestOfThree

    private var isCompact: Bool { ChromeType.isCompact }
    private var setup: NewGameSetup {
        NewGameSetup(variant: variant, level: level, playAs: playAs, length: length)
    }

    var body: some View {
        ZStack {
            ChromeKit.cardColor.ignoresSafeArea()
            FitOrScroll {
                VStack(alignment: .leading, spacing: isCompact ? 18 : 24) {
                    header
                    variantSection
                    levelSection
                    playAsSection
                    lengthSection
                    playButton
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, isCompact ? 20 : 32)
                .padding(.top, isCompact ? 20 : 28)
                .padding(.bottom, isCompact ? 12 : 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .center) {
            Text("Play the computer")
                .font(ChromeType.title2.bold())
                .foregroundStyle(ChromeTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(ChromeType.title3.weight(.medium))
                    .foregroundStyle(ChromeTheme.ink.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var variantSection: some View {
        SheetSection("Variant") {
            SegmentedChoice(options: GameVariantSetting.allCases,
                            selection: $variant,
                            label: \.shortLabel)
                .disabled(setup.isFullTavli)
                .opacity(setup.isFullTavli ? 0.45 : 1)
            caption(setup.isFullTavli
                    ? String(localized: "Full Tavli plays all three variants in turn.")
                    : variant.rulesReminder)
        }
    }

    private var levelSection: some View {
        SheetSection("Level") {
            HStack(spacing: isCompact ? 6 : 8) {
                ForEach(Array(AILevel.range), id: \.self) { n in
                    levelChip(n)
                }
            }
            caption("\(AILevelCopy.name(level)) · \(AILevelCopy.description(level))")
        }
    }

    private func levelChip(_ n: Int) -> some View {
        let selected = n == level
        return Button { level = n } label: {
            Text("\(n)")
                .font(ChromeType.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(selected ? SColor.white : ChromeTheme.ink)
                .frame(maxWidth: .infinity, minHeight: isCompact ? 44 : 50)
                .background(selected ? ChromeTheme.undoTint : ChromeKit.trackColor)
                .cornerRadius(ChromeKit.buttonRadius - 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AILevelCopy.name(n))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var playAsSection: some View {
        SheetSection("Play as") {
            HStack(spacing: isCompact ? 10 : 12) {
                ForEach(PreferredColorSetting.allCases) { option in
                    playAsTile(option)
                }
            }
        }
    }

    private func playAsTile(_ option: PreferredColorSetting) -> some View {
        let selected = option == playAs
        return Button { playAs = option } label: {
            VStack(spacing: isCompact ? 6 : 8) {
                PlayAsChecker(setting: option, size: isCompact ? 26 : 30)
                Text(option.label)
                    .font(ChromeType.callout.weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, isCompact ? 10 : 14)
            .background(selected ? ChromeKit.selectedSegmentColor : ChromeKit.trackColor)
            .cornerRadius(ChromeKit.buttonRadius)
            .overlay(
                RoundedRectangle(cornerRadius: ChromeKit.buttonRadius)
                    .stroke(ChromeTheme.undoTint, lineWidth: selected ? 2 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var lengthSection: some View {
        SheetSection("Length") {
            SegmentedChoice(options: MatchLengthSetting.allCases,
                            selection: $length,
                            label: \.label)
            caption(length.caption)
        }
    }

    @ViewBuilder
    private var playButton: some View {
        VStack(spacing: 10) {
            if !setup.aiAvailable {
                Text(setup.unavailableMessage)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            Button(action: onPlay) {
                Text("Play")
                    .font(ChromeType.title3.bold())
                    .padding(.vertical, isCompact ? 6 : 8)
            }
            .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
            .disabled(!setup.aiAvailable)
            .opacity(setup.aiAvailable ? 1 : 0.45)
            .accessibilityIdentifier("newGamePlay")
        }
        .padding(.top, isCompact ? 2 : 6)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(ChromeType.caption)
            .foregroundStyle(ChromeKit.inkSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled block of the sheet: a quiet label above its control(s).
private struct SheetSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ChromeType.callout)
                .foregroundStyle(ChromeKit.inkSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A Caramel segmented choice (#189): a recessed track with the selected option raised
/// on a light pill — the mockup's look, which the system segmented picker can't take.
private struct SegmentedChoice<T: Hashable & Identifiable>: View {
    let options: [T]
    @Binding var selection: T
    let label: KeyPath<T, String>

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(option[keyPath: label])
                        .font(ChromeType.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(ChromeTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(
                            RoundedRectangle(cornerRadius: ChromeKit.buttonRadius - 3)
                                .fill(selected ? ChromeKit.selectedSegmentColor : SColor.clear)
                                .shadow(color: selected ? ChromeKit.cardShadow : .clear,
                                        radius: 2, x: 0, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(ChromeKit.trackColor)
        .cornerRadius(ChromeKit.buttonRadius)
    }
}

/// A checker icon for a Play-as choice (#189): ivory for White, red for Red, split
/// half-and-half for Random.
struct PlayAsChecker: View {
    let setting: PreferredColorSetting
    var size: CGFloat

    var body: some View {
        ZStack {
            switch setting {
            case .white:  Circle().fill(ChromeTheme.checkerColor(.white))
            case .black:  Circle().fill(ChromeTheme.checkerColor(.black))
            case .random:
                HStack(spacing: 0) {
                    Rectangle().fill(ChromeTheme.checkerColor(.white))
                    Rectangle().fill(ChromeTheme.checkerColor(.black))
                }
                .clipShape(Circle())
            }
            Circle().stroke(ChromeTheme.ink.opacity(0.45), lineWidth: max(1.5, size / 14))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    Text("Start")
        .sheet(isPresented: .constant(true)) { NewGameSheet(onPlay: {}) }
}
