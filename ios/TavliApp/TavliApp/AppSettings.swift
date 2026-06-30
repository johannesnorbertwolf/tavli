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

/// How many games a session plays (#145). `.single` is one game; `.bestOfThree` is a
/// best-of-three match (first to two games). Defaults to `.bestOfThree` — the most
/// common social format — on both the offline (vs-AI) start screen and the online lobby.
enum MatchLengthSetting: String, CaseIterable, Identifiable {
    case single, bestOfThree

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single:      return String(localized: "Single game")
        case .bestOfThree: return String(localized: "Best of 3")
        }
    }

    /// Games a side must win to take the match (single → 1, best-of-three → 2).
    var targetWins: Int {
        switch self {
        case .single:      return 1
        case .bestOfThree: return 2
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
    static let aiStrength          = "settings.aiStrength"
    static let matchLength         = "settings.matchLength"
    static let onlineMatchLength   = "settings.onlineMatchLength"
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
    /// idle thinking window; both sides' plies are ranked at 2-ply in the background
    /// (#108). The user can disable it to save CPU/battery.
    static var inPlayAnalysisEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.inPlayAnalysis) as? Bool ?? true
    }

    /// AI-strength dial (#108), 0…1: **1.0 (default) = full strength** (unchanged 2-ply
    /// argmax), lower = weaker. Anything below 1.0 drops the *play* search to 1-ply and
    /// adds selection noise that grows toward 0 (see `searchConfig`).
    static var aiStrength: Double {
        UserDefaults.standard.object(forKey: SettingsKey.aiStrength) as? Double ?? 1.0
    }

    /// Largest selection-noise σ, reached at the weakest setting. Tuned so even the
    /// weakest opponent only seldom passes up its best 1-ply move (#108); raise to make
    /// the weak end weaker.
    static let aiSigmaMax: Float = 0.10

    /// The search configuration a new or resumed session should use, mapping `aiStrength`
    /// onto the engine knobs: full strength is the unchanged 2-ply argmax; below that the
    /// search drops to 1-ply and `selectionNoise` rises linearly to `aiSigmaMax` at the
    /// weakest. Only `maxDepth`/`selectionNoise` change — the analysis ranking reads the
    /// other (standard) fields and stays full-strength regardless.
    static var searchConfig: SearchConfig {
        var c = SearchConfig.standard
        let best = aiStrength >= 1.0
        c.maxDepth = best ? 2 : 1
        c.selectionNoise = best ? 0 : aiSigmaMax * Float(1.0 - aiStrength)
        return c
    }

    /// How many games an offline (vs-AI) session plays (#145). Default `.bestOfThree`.
    static var matchLength: MatchLengthSetting {
        raw(SettingsKey.matchLength).flatMap(MatchLengthSetting.init) ?? .bestOfThree
    }

    /// How many games a newly-invited online match plays (#145). Default `.bestOfThree`.
    static var onlineMatchLength: MatchLengthSetting {
        raw(SettingsKey.onlineMatchLength).flatMap(MatchLengthSetting.init) ?? .bestOfThree
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
