import SwiftUI
import TavliEngine

/// Persisted user settings (#77). Backed by `UserDefaults` via `@AppStorage` in the
/// views that consume them; this file defines the option enums, the storage keys,
/// and static accessors for the non-view contexts (e.g. `RootView`'s cold-launch
/// auto-resume, which runs in `init` before `@AppStorage` is live).
///
/// **Defaults reproduce the pre-settings behaviour** (#77 AC: no change on first
/// launch): preferred color unset (the per-game White/Black pick is preserved),
/// opening-roll ceremony, auto dice, AI animation on, win-probability bar off. Each
/// `@AppStorage` declaration in a view must carry the same default as the matching
/// accessor here so view bindings and these reads agree.
///
/// Later additions set their own sensible default rather than "no change": in-play
/// analysis (#146) defaults **on** so reviews open instantly out of the box.

/// Which color the human plays. `.ask` keeps the per-game White/Black choice on the
/// start screen; a fixed color skips that choice and is used for every new game.
enum PreferredColorSetting: String, CaseIterable, Identifiable {
    case ask, white, black

    var id: String { rawValue }

    /// The engine color to play, or `nil` when the player still chooses per game.
    var engineColor: TavliEngine.Color? {
        switch self {
        case .ask:   return nil
        case .white: return .white
        case .black: return .black
        }
    }

    var label: String {
        switch self {
        case .ask:   return String(localized: "Ask")
        case .white: return String(localized: "White")
        case .black: return String(localized: "Red")
        }
    }
}

/// Who moves first in a new game. `.openingRoll` runs the dice ceremony (#33); the
/// fixed options skip it and seed the starting player directly.
enum StartingPlayerSetting: String, CaseIterable, Identifiable {
    case openingRoll, human, ai

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openingRoll: return String(localized: "Opening roll")
        case .human:       return String(localized: "I start")
        case .ai:          return String(localized: "TavTav starts")
        }
    }

    /// The starting player for a new game given the human's color, or `nil` when the
    /// opening-roll ceremony should resolve it instead.
    func startingPlayer(humanColor: TavliEngine.Color) -> TavliEngine.Color? {
        switch self {
        case .openingRoll: return nil
        case .human:       return humanColor
        case .ai:          return humanColor.opponent
        }
    }
}

/// How the human's dice are produced. The AI always rolls its own dice regardless
/// (it rolls internally in `GameSession.maybeStartAITurn`), so this only affects
/// the human's turn.
enum DiceModeSetting: String, CaseIterable, Identifiable {
    case auto, manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:   return String(localized: "Random")
        case .manual: return String(localized: "Enter manually")
        }
    }
}

/// `UserDefaults` keys for the persisted settings.
enum SettingsKey {
    static let preferredColor     = "settings.preferredColor"
    static let startingPlayer     = "settings.startingPlayer"
    static let diceMode           = "settings.diceMode"
    static let autoRoll           = "settings.autoRoll"
    static let aiAnimation        = "settings.aiAnimationEnabled"
    static let showWinProbability = "settings.showWinProbability"
    static let inPlayAnalysis      = "settings.inPlayAnalysis"
}

/// Static, non-reactive reads of the persisted settings, for contexts where
/// `@AppStorage` isn't available (static funcs / initialisers). Views should bind
/// to `@AppStorage` instead, so the UI updates live as settings change.
enum AppSettings {
    static var preferredColor: PreferredColorSetting {
        raw(SettingsKey.preferredColor).flatMap(PreferredColorSetting.init) ?? .ask
    }

    static var startingPlayer: StartingPlayerSetting {
        raw(SettingsKey.startingPlayer).flatMap(StartingPlayerSetting.init) ?? .openingRoll
    }

    static var diceMode: DiceModeSetting {
        raw(SettingsKey.diceMode).flatMap(DiceModeSetting.init) ?? .auto
    }

    /// Whether the human's dice roll automatically at the start of their turn
    /// (default off). Mutually exclusive with `diceMode == .manual`.
    static var autoRoll: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.autoRoll) as? Bool ?? false
    }

    static var aiAnimationEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.aiAnimation) as? Bool ?? true
    }

    static var showWinProbability: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.showWinProbability) as? Bool ?? false
    }

    /// Whether to compute each ply's 2-ply analysis during play (#146), so the
    /// post-game review opens instantly. Default **on** — the work fits the human's
    /// idle thinking window and the AI's plies are captured for free from its search;
    /// the user can disable it to save CPU/battery.
    static var inPlayAnalysisEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.inPlayAnalysis) as? Bool ?? true
    }

    /// The animation timings a new or resumed session should use, honouring the
    /// AI-animation setting (`.standard` when on, `.off` when off).
    static var animationTimings: AnimationTimings {
        aiAnimationEnabled ? .standard : .off
    }

    private static func raw(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }
}
