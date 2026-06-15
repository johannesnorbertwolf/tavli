import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// In-app settings screen (#77). Presented as a sheet from the start screen and the
/// in-game chrome. Every control binds directly to `@AppStorage`, so changes persist
/// immediately and any view observing the same key updates live. Defaults match the
/// app's pre-settings behaviour (see `AppSettings`), so the screen is purely additive.
///
/// Styled to the Caramel chrome (background, `ChromeType` fonts, `ChromeTheme` tints)
/// rather than a stock `Form`, to match the rest of the app (cf. `StatsPanelView`).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.preferredColor) private var preferredColor: PreferredColorSetting = .ask
    @AppStorage(SettingsKey.startingPlayer) private var startingPlayer: StartingPlayerSetting = .openingRoll
    @AppStorage(SettingsKey.diceMode) private var diceMode: DiceModeSetting = .auto
    @AppStorage(SettingsKey.aiAnimation) private var aiAnimation = true
    @AppStorage(SettingsKey.showWinProbability) private var showWinProbability = false

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    section("Gameplay") {
                        choiceRow("Play as",
                                  selection: $preferredColor,
                                  options: PreferredColorSetting.allCases,
                                  label: \.label,
                                  caption: "Pick a colour to always play, or choose at the start of every game.")
                        choiceRow("First move",
                                  selection: $startingPlayer,
                                  options: StartingPlayerSetting.allCases,
                                  label: \.label,
                                  caption: "The opening roll decides who starts, unless you force a side.")
                        choiceRow("Dice",
                                  selection: $diceMode,
                                  options: DiceModeSetting.allCases,
                                  label: \.label,
                                  caption: "Roll automatically, or enter your own dice each turn. The AI always rolls its own.")
                    }

                    section("Display") {
                        toggleRow("Animate AI moves",
                                  isOn: $aiAnimation,
                                  caption: "Slow dice roll and one-by-one checker hops on the AI's turn.")
                        toggleRow("Win-probability bar",
                                  isOn: $showWinProbability,
                                  caption: "Show your live chance of winning during the game.")
                    }
                }
                .padding(28)
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
