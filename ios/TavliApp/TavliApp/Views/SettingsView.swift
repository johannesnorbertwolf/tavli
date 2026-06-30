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
    @AppStorage(SettingsKey.autoRoll) private var autoRoll = false
    @AppStorage(SettingsKey.aiAnimation) private var aiAnimation = true
    @AppStorage(SettingsKey.showWinProbability) private var showWinProbability = false
    @AppStorage(SettingsKey.inPlayAnalysis) private var inPlayAnalysis = false
    @AppStorage(SettingsKey.aiStrength) private var aiStrength = 1.0

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    section("Gameplay") {
                        sliderRow("TavTav's strength",
                                  value: $aiStrength,
                                  minLabel: "Relaxed",
                                  maxLabel: "Best",
                                  caption: "How strongly TavTav plays. Best is the full-strength engine; lower down it looks less far ahead and slips up more often. Takes effect on TavTav's next move.")
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
                                  caption: "iPad rolls for you, or enter your own dice each turn. The AI always rolls its own.")
                            .onChange(of: diceMode) { _, mode in
                                // The two modes are mutually exclusive: switching to
                                // manual dice turns off auto-roll.
                                if mode == .manual { autoRoll = false }
                            }
                        autoRollRow
                    }

                    section("Display") {
                        toggleRow("Animate AI moves",
                                  isOn: $aiAnimation,
                                  caption: "Slow dice roll and one-by-one checker hops on the AI's turn.")
                        toggleRow("Win-probability bar",
                                  isOn: $showWinProbability,
                                  caption: "Show your live chance of winning during the game.")
                        toggleRow("Analyze during play",
                                  isOn: $inPlayAnalysis,
                                  caption: "Work out each move's best play as you go, so the post-game review opens instantly. Off by default — it shares the AI's compute, so the AI can be slower to move. Uses a little more battery.")
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

    /// A titled slider (#108) with min/max end labels and a caption beneath.
    private func sliderRow(_ title: LocalizedStringKey,
                           value: Binding<Double>,
                           minLabel: LocalizedStringKey,
                           maxLabel: LocalizedStringKey,
                           caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ChromeType.body.weight(.semibold))
                .foregroundStyle(ChromeTheme.ink)
            HStack(spacing: 12) {
                Text(minLabel)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                Slider(value: value, in: 0...1)
                    .tint(ChromeTheme.undoTint)
                Text(maxLabel)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            Text(caption)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
    }

    /// Auto-roll toggle (#116): disabled and annotated when manual-dice mode is on.
    private var autoRollRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $autoRoll) {
                Text("Auto-roll")
                    .font(ChromeType.body.weight(.semibold))
                    .foregroundStyle(diceMode == .manual ? ChromeKit.inkSecondary : ChromeTheme.ink)
            }
            .tint(ChromeTheme.doneTint)
            .disabled(diceMode == .manual)
            if diceMode == .manual {
                Text("Not available with manual dice entry.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            } else {
                Text("Dice roll automatically at the start of your turn.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .opacity(diceMode == .manual ? 0.5 : 1)
    }
}

#Preview {
    SettingsView()
}
