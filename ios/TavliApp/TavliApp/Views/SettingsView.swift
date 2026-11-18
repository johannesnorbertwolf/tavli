import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// In-app settings screen (#77). Presented as a sheet from the start screen and the
/// in-game chrome. Every control binds directly to `@AppStorage`, so changes persist
/// immediately and any view observing the same key updates live. Defaults are the
/// `AppSettings` accessors' (each `@AppStorage` default here must match its accessor).
///
/// Sections (#174): **Game** (play as, auto-roll), **Advanced** (first move, analyze
/// during play), **Display** (appearance, #191). Variant, match length and the AI level live in the
/// new-game sheet only (#189, `NewGameSheet`).
///
/// Styled to the Caramel chrome (background, `ChromeType` fonts, `ChromeTheme` tints)
/// rather than a stock `Form`, to match the rest of the app (cf. `StatsPanelView`).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.preferredColor) private var preferredColor: PreferredColorSetting = .white
    @AppStorage(SettingsKey.startingPlayer) private var startingPlayer: StartingPlayerSetting = .openingRoll
    @AppStorage(SettingsKey.autoRoll) private var autoRoll = true
    @AppStorage(SettingsKey.aiAnimation) private var aiAnimation = true
    @AppStorage(SettingsKey.showWinProbability) private var showWinProbability = false
    @AppStorage(SettingsKey.inPlayAnalysis) private var inPlayAnalysis = false
    @AppStorage(SettingsKey.appearance) private var appearance: AppearanceSetting = .system

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    section("Game") {
                        choiceRow("Play as",
                                  selection: $preferredColor,
                                  options: PreferredColorSetting.allCases,
                                  label: \.label,
                                  caption: "The colour you play against the computer. Random picks a side for each new game.")
                        toggleRow("Auto-roll",
                                  isOn: $autoRoll,
                                  caption: "Dice roll automatically at the start of your turn.")
                    }

                    section("Advanced") {
                        choiceRow("First move",
                                  selection: $startingPlayer,
                                  options: StartingPlayerSetting.allCases,
                                  label: \.label,
                                  caption: "The opening roll decides who starts, unless you force a side.")
                        toggleRow("Analyze during play",
                                  isOn: $inPlayAnalysis,
                                  caption: "Work out each move's best play as you go, so the post-game review opens instantly. Off by default — it shares the computer's processing power, so the computer can be slower to move. Uses a little more battery.")
                    }

                    section("Display") {
                        choiceRow("Appearance",
                                  selection: $appearance,
                                  options: AppearanceSetting.allCases,
                                  label: \.label,
                                  caption: "System follows your device's light or dark mode.")
                        toggleRow("Animate computer moves",
                                  isOn: $aiAnimation,
                                  caption: "Slow dice roll and one-by-one checker hops on the computer's turn.")
                        toggleRow("Win-probability bar",
                                  isOn: $showWinProbability,
                                  caption: "Show your live chance of winning during the game.")
                    }

                    // #148: the one handicap entry, a card of its own at the end
                    // (builder in HandicapSettingsView).
                    HandicapSettingsRow()
                }
                .compactPadding(28, compact: 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Settings")
                .font(ChromeType.statsTitle)
                .foregroundStyle(ChromeTheme.ink)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(ChromeButton(role: .secondary))
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(ChromeType.headline)
                .foregroundStyle(ChromeKit.inkSecondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 20)
    }

    // MARK: - Rows

    /// A titled segmented choice over a set of options, with a caption beneath.
    private func choiceRow<T: Hashable & Identifiable>(_ title: LocalizedStringKey,
                                                       selection: Binding<T>,
                                                       options: [T],
                                                       label: KeyPath<T, String>,
                                                       caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ChromeType.body.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option[keyPath: label]).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .tint(ChromeTheme.undoTint)
            Text(caption)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
    }

    /// A titled on/off toggle with a caption beneath.
    private func toggleRow(_ title: LocalizedStringKey,
                           isOn: Binding<Bool>,
                           caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: isOn) {
                Text(title)
                    .font(ChromeType.body.weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
            }
            .tint(ChromeTheme.doneTint)
            Text(caption)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
    }
}

#Preview {
    SettingsView()
}
