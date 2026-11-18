import SwiftUI
import TavliEngine

private typealias EngineColor = TavliEngine.Color

/// The handicap builder (#148, concept §4): a master toggle, one card per tier-1 item
/// (favoured-side picker + slider/toggle + a plain one-line explanation) and the live
/// win-chance estimate. Edits the persisted `HandicapPreferences` directly. Sides read
/// "You / Computer" or "White / Red" depending on the mode picked at the top.
struct HandicapSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HandicapPreferences.storageKey) private var raw = ""
    @AppStorage(SettingsKey.matchLength) private var matchLength: MatchLengthSetting = .bestOfThree
    @AppStorage(SettingsKey.variant) private var variantID = GameVariants.defaultID
    @AppStorage(SettingsKey.startingPlayer) private var startingPlayer: StartingPlayerSetting = .openingRoll

    @State private var vsComputer = true
    @StateObject private var model = HandicapEstimateModel()

    private var prefs: HandicapPreferences { HandicapPreferences.decode(raw) }

    private func binding<T>(_ key: WritableKeyPath<HandicapPreferences, T>) -> Binding<T> {
        Binding(get: { prefs[keyPath: key] },
                set: { var p = prefs; p[keyPath: key] = $0; raw = p.encoded })
    }

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    Text("Give one side an advantage so players of different strength get a close game.")
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeKit.inkSecondary)

                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: binding(\.enabled)) {
                            Text("Use handicaps")
                                .font(ChromeType.body.weight(.semibold))
                                .foregroundStyle(ChromeTheme.ink)
                        }
                        .tint(ChromeTheme.doneTint)
                        .accessibilityIdentifier("handicapMaster")
                        Picker("Sides", selection: $vsComputer) {
                            Text("Playing the computer").tag(true)
                            Text("Two players").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .tint(ChromeTheme.undoTint)
                        Text(applicability)
                            .font(ChromeType.caption)
                            .foregroundStyle(appliesNow ? ChromeKit.inkSecondary : ChromeTheme.surrenderTint)
                    }
                    .chromeCard(padding: 20)

                    Group {
                        itemCard(title: "Head start",
                                 caption: "Checkers that start 6 points ahead of the stack.",
                                 side: binding(\.headStartSide)) {
                            stepSlider(value: binding(\.headStart), range: 0...HandicapSetup.maxHeadStart,
                                       label: prefs.headStart == 0 ? String(localized: "Off")
                                         : prefs.headStart == 1 ? String(localized: "1 checker")
                                         : String(localized: "\(prefs.headStart) checkers"))
                        }
                        itemCard(title: "Moves first",
                                 caption: "Always starts the game; no opening roll.",
                                 side: binding(\.movesFirstSide)) {
                            Toggle(isOn: binding(\.movesFirst)) {
                                Text(prefs.movesFirst ? String(localized: "On") : String(localized: "Off"))
                                    .font(ChromeType.callout)
                                    .foregroundStyle(ChromeTheme.ink)
                            }
                            .tint(ChromeTheme.doneTint)
                        }
                        itemCard(title: "Weighted dice",
                                 caption: "Before each roll the dice lean towards rolls that are good for this side. The game says so in its Handicap tag.",
                                 side: binding(\.diceSide)) {
                            stepSlider(value: binding(\.dice), range: 0...(HandicapDiceStrength.allCases.count - 1),
                                       label: prefs.diceStrength.label)
                        }
                        itemCard(title: "Rerolls",
                                 caption: "Roll again after seeing the dice, this many times per game.",
                                 side: binding(\.rerollsSide)) {
                            stepSlider(value: binding(\.rerolls), range: 0...HandicapSetup.maxRerolls,
                                       label: prefs.rerolls == 0 ? String(localized: "Off")
                                                                 : String(localized: "\(prefs.rerolls) per game"))
                        }
                        itemCard(title: "Hints",
                                 caption: "Show the computer's best move (without playing it), this many times per game.",
                                 side: vsComputer ? nil : binding(\.hintsSide),
                                 fixedSide: vsComputer ? String(localized: "You") : nil) {
                            stepSlider(value: binding(\.hints), range: 0...HandicapSetup.maxHints,
                                       label: prefs.hints == 0 ? String(localized: "Off")
                                                               : String(localized: "\(prefs.hints) per game"))
                        }
                    }
                    .disabled(!prefs.enabled)
                    .opacity(prefs.enabled ? 1 : 0.5)

                    HandicapEstimateView(estimate: prefs.isActive ? model.estimate : nil,
                                         computing: model.computing,
                                         unavailable: model.unavailable,
                                         aName: HandicapRole.a.label(vsComputer: vsComputer),
                                         bName: HandicapRole.b.label(vsComputer: vsComputer),
                                         aColor: .white)
                        .chromeCard(padding: 20)
                        .opacity(prefs.isActive ? 1 : 0)
                        .accessibilityHidden(!prefs.isActive)
                }
                .compactPadding(28, compact: 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: refreshEstimate)
        .onChange(of: raw) { _, _ in refreshEstimate() }
        .onChange(of: vsComputer) { _, _ in refreshEstimate() }
    }

    // MARK: - Estimate

    /// Side A is evaluated as White (house Plakoto is colour-symmetric). The start rule
    /// mirrors the app: two players → White starts; vs the computer → the First-move
    /// setting (opening roll = a fair roll-off).
    private func refreshEstimate() {
        guard prefs.isActive, let setup = prefs.setup(humanColor: vsComputer ? .white : nil) else { return }
        let rule: HandicapStartRule
        if !vsComputer {
            rule = .fixed(.white)
        } else {
            switch startingPlayer {
            case .openingRoll: rule = .rollOff
            case .human:       rule = .fixed(.white)
            case .ai:          rule = .fixed(.black)
            }
        }
        model.update(setup: setup, rule: rule)
    }

    // MARK: - Applicability (concept §7)

    private var variant: GameVariantSetting { GameVariantSetting(variantID: variantID) }

    private var appliesNow: Bool {
        !prefs.isActive || HandicapPreferences.applies(variant: variant, length: matchLength,
                                                       vsComputer: vsComputer)
    }

    private var applicability: String {
        let base = String(localized: "Applies to offline games of Plakoto (house rules), single or Best of 3. Not online or Full Tavli.")
        guard prefs.isActive, !appliesNow else { return base }
        if variant != .plakoto {
            return String(localized: "Your next game is \(variant.name), so it will be played without a handicap.")
        }
        return String(localized: "Your next game is Full Tavli, so it will be played without a handicap.")
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Handicap")
                .font(ChromeType.statsTitle)
                .foregroundStyle(ChromeTheme.ink)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(ChromeButton(role: .secondary))
        }
    }

    /// One item: title, favoured-side picker (or a fixed side), the control, a caption.
    private func itemCard<Control: View>(title: LocalizedStringKey, caption: LocalizedStringKey,
                                         side: Binding<HandicapRole>?, fixedSide: String? = nil,
                                         @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(title)
                    .font(ChromeType.body.weight(.semibold))
                    .foregroundStyle(ChromeTheme.ink)
                Spacer(minLength: 8)
                if let side {
                    Picker("For", selection: side) {
                        ForEach(HandicapRole.allCases) { r in
                            Text(r.label(vsComputer: vsComputer)).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(ChromeTheme.undoTint)
                    .frame(maxWidth: 210)
                } else if let fixedSide {
                    Text(fixedSide)
                        .font(ChromeType.callout)
                        .foregroundStyle(ChromeKit.inkSecondary)
                }
            }
            control()
            Text(caption)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 16)
    }

    /// An integer slider with its value label.
    private func stepSlider(value: Binding<Int>, range: ClosedRange<Int>, label: String) -> some View {
        HStack(spacing: 12) {
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .tint(ChromeTheme.undoTint)
            Text(label)
                .font(ChromeType.callout.monospacedDigit())
                .foregroundStyle(ChromeTheme.ink)
                .frame(minWidth: ChromeType.isCompact ? 96 : 120, alignment: .trailing)
        }
    }
}

#Preview {
    HandicapSettingsView()
}
