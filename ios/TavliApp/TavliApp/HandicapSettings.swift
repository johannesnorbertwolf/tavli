import Foundation
import SwiftUI
import TavliEngine

/// Handicap settings (#148, tier 1). The builder (`HandicapSettingsView`) edits one
/// persisted `HandicapPreferences` value (JSON under `settings.handicap`, off by default);
/// new games resolve it into the engine's per-colour `HandicapSetup` with
/// `HandicapPreferences.setupForNewGame(...)`. Off (the default) = no setup at all, so a
/// player who never opens the builder sees no change anywhere.
///
/// Sides are stored as a **role** so one setting serves both modes: `.a` is "You" vs the
/// computer and "White" for two players; `.b` is "Computer" / "Red". Hints are always the
/// human's against the computer.

/// Which side an item favours.
enum HandicapRole: String, Codable, CaseIterable, Identifiable {
    case a, b
    var id: String { rawValue }

    /// "You" / "Computer" (vs the computer) or "White" / "Red" (two players).
    func label(vsComputer: Bool) -> String {
        switch (self, vsComputer) {
        case (.a, true):  return String(localized: "You")
        case (.b, true):  return String(localized: "Computer")
        case (.a, false): return String(localized: "White")
        case (.b, false): return String(localized: "Red")
        }
    }
}

/// The weighted-dice strengths offered, mapped onto `HandicapSetup.diceTiltSteps`
/// (the engine keeps the β grid in one place).
enum HandicapDiceStrength: Int, CaseIterable, Identifiable {
    case off, slight, moderate, strong, veryStrong
    var id: Int { rawValue }

    var beta: Double { HandicapSetup.diceTiltSteps[min(rawValue, HandicapSetup.diceTiltSteps.count - 1)] }

    init(beta: Double) {
        self = Self.allCases.last { $0.beta <= beta } ?? .off
    }

    var label: String {
        switch self {
        case .off:        return String(localized: "Off")
        case .slight:     return String(localized: "Slight")
        case .moderate:   return String(localized: "Moderate")
        case .strong:     return String(localized: "Strong")
        case .veryStrong: return String(localized: "Very strong")
        }
    }

    /// "slightly" … for "Dice favour White slightly".
    var adverb: String {
        switch self {
        case .off:        return ""
        case .slight:     return String(localized: "slightly")
        case .moderate:   return String(localized: "moderately")
        case .strong:     return String(localized: "strongly")
        case .veryStrong: return String(localized: "very strongly")
        }
    }
}

/// The builder's persisted state.
struct HandicapPreferences: Codable, Equatable {
    var enabled = false
    var headStart = 0
    var headStartSide: HandicapRole = .a
    var movesFirst = false
    var movesFirstSide: HandicapRole = .a
    var dice: Int = 0                     // HandicapDiceStrength raw value
    var diceSide: HandicapRole = .a
    var rerolls = 0
    var rerollsSide: HandicapRole = .a
    var hints = 0
    var hintsSide: HandicapRole = .a      // two players only; vs the computer always "You"
    // Tier 2 (#148 P3b): rule levers. Overshoot, safe point and home size go to one side;
    // the checker count is set per side (more checkers is the advantage).
    var overshoot = false
    var overshootSide: HandicapRole = .a
    var safePoint = 0                     // 0 = off, else one of HandicapSetup.safePointCandidates
    var safePointSide: HandicapRole = .a
    var checkersA = HandicapSetup.normalCheckers
    var checkersB = HandicapSetup.normalCheckers
    var homeSize = HandicapSetup.normalHomeSize
    var homeSizeSide: HandicapRole = .b

    static let storageKey = "settings.handicap"

    var diceStrength: HandicapDiceStrength {
        get { HandicapDiceStrength(rawValue: dice) ?? .off }
        set { dice = newValue.rawValue }
    }

    /// Whether any item is set (independent of the master toggle).
    var hasItems: Bool {
        headStart > 0 || movesFirst || dice > 0 || rerolls > 0 || hints > 0 || hasTier2
    }

    /// Whether any tier-2 (rule) item is set.
    var hasTier2: Bool {
        overshoot || safePoint > 0 || checkersA != HandicapSetup.normalCheckers
            || checkersB != HandicapSetup.normalCheckers || homeSize != HandicapSetup.normalHomeSize
    }

    /// Whether handicaps are on and do something.
    var isActive: Bool { enabled && hasItems }

    // Tolerant decode (missing keys = defaults).
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HandicapPreferences()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        headStart = try c.decodeIfPresent(Int.self, forKey: .headStart) ?? d.headStart
        headStartSide = try c.decodeIfPresent(HandicapRole.self, forKey: .headStartSide) ?? d.headStartSide
        movesFirst = try c.decodeIfPresent(Bool.self, forKey: .movesFirst) ?? d.movesFirst
        movesFirstSide = try c.decodeIfPresent(HandicapRole.self, forKey: .movesFirstSide) ?? d.movesFirstSide
        dice = try c.decodeIfPresent(Int.self, forKey: .dice) ?? d.dice
        diceSide = try c.decodeIfPresent(HandicapRole.self, forKey: .diceSide) ?? d.diceSide
        rerolls = try c.decodeIfPresent(Int.self, forKey: .rerolls) ?? d.rerolls
        rerollsSide = try c.decodeIfPresent(HandicapRole.self, forKey: .rerollsSide) ?? d.rerollsSide
        hints = try c.decodeIfPresent(Int.self, forKey: .hints) ?? d.hints
        hintsSide = try c.decodeIfPresent(HandicapRole.self, forKey: .hintsSide) ?? d.hintsSide
        overshoot = try c.decodeIfPresent(Bool.self, forKey: .overshoot) ?? d.overshoot
        overshootSide = try c.decodeIfPresent(HandicapRole.self, forKey: .overshootSide) ?? d.overshootSide
        safePoint = try c.decodeIfPresent(Int.self, forKey: .safePoint) ?? d.safePoint
        safePointSide = try c.decodeIfPresent(HandicapRole.self, forKey: .safePointSide) ?? d.safePointSide
        checkersA = try c.decodeIfPresent(Int.self, forKey: .checkersA) ?? d.checkersA
        checkersB = try c.decodeIfPresent(Int.self, forKey: .checkersB) ?? d.checkersB
        homeSize = try c.decodeIfPresent(Int.self, forKey: .homeSize) ?? d.homeSize
        homeSizeSide = try c.decodeIfPresent(HandicapRole.self, forKey: .homeSizeSide) ?? d.homeSizeSide
    }

    // MARK: Storage

    static func load() -> HandicapPreferences {
        guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return HandicapPreferences() }
        return decode(raw)
    }

    static func decode(_ raw: String) -> HandicapPreferences {
        (try? JSONDecoder().decode(HandicapPreferences.self, from: Data(raw.utf8))) ?? HandicapPreferences()
    }

    var encoded: String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    // MARK: Resolution

    /// The engine setup for a game. `humanColor` = the human's colour vs the computer,
    /// `nil` for two players. `nil` when off or empty.
    func setup(humanColor: TavliEngine.Color?) -> HandicapSetup? {
        guard isActive else { return nil }
        func color(_ role: HandicapRole) -> TavliEngine.Color {
            if let human = humanColor { return role == .a ? human : human.opponent }
            return role == .a ? .white : .black
        }
        var s = HandicapSetup()
        if headStart > 0 { s[color(headStartSide)].headStart = headStart }
        if movesFirst { s[color(movesFirstSide)].movesFirst = true }
        if dice > 0 { s[color(diceSide)].diceTilt = diceStrength.beta }
        if rerolls > 0 { s[color(rerollsSide)].rerolls = rerolls }
        if hints > 0 {
            let side = humanColor ?? color(hintsSide)   // vs the computer: always the human
            s[side].hints = hints
        }
        if overshoot { s[color(overshootSide)].overshoot = true }
        if safePoint > 0 { s[color(safePointSide)].safePoint = safePoint }
        s[color(.a)].checkers = checkersA
        s[color(.b)].checkers = checkersB
        if homeSize != HandicapSetup.normalHomeSize { s[color(homeSizeSide)].homeSize = homeSize }
        let n = s.normalized
        return n.isActive ? n : nil
    }

    /// Whether a new game of this kind is handicapped (concept §7): house Plakoto only,
    /// offline only, a single game or every game of a best-of-three — never Full Tavli
    /// (online never reaches this). Same rule vs the computer and for two players.
    static func applies(variant: GameVariantSetting, length: MatchLengthSetting, vsComputer: Bool) -> Bool {
        guard HandicapSetup.supports(variantID: variant.rawValue) else { return false }
        return length != .fullTavli
    }

    /// The setup for a new offline game, or `nil` when handicaps are off or don't apply
    /// to this kind of game (then it is simply a normal game).
    static func setupForNewGame(humanColor: TavliEngine.Color?, variant: GameVariantSetting) -> HandicapSetup? {
        let prefs = load()
        guard prefs.isActive,
              applies(variant: variant, length: AppSettings.matchLength, vsComputer: humanColor != nil)
        else { return nil }
        return prefs.setup(humanColor: humanColor)
    }

    /// Short summary for the Settings row: "Off", or e.g. "Head start 2 · Rerolls 1".
    var summary: String {
        guard isActive else { return String(localized: "Off") }
        var parts: [String] = []
        if headStart > 0 { parts.append(String(localized: "Head start \(headStart)")) }
        if movesFirst { parts.append(String(localized: "Moves first")) }
        if dice > 0 { parts.append(String(localized: "Weighted dice")) }
        if rerolls > 0 { parts.append(String(localized: "Rerolls \(rerolls)")) }
        if hints > 0 { parts.append(String(localized: "Hints \(hints)")) }
        if overshoot { parts.append(String(localized: "Overshoot bear-off")) }
        if safePoint > 0 { parts.append(String(localized: "Safe point \(safePoint)")) }
        if checkersA != HandicapSetup.normalCheckers || checkersB != HandicapSetup.normalCheckers {
            parts.append(String(localized: "Checkers \(checkersA)–\(checkersB)"))
        }
        if homeSize != HandicapSetup.normalHomeSize { parts.append(String(localized: "Home \(homeSize) points")) }
        return parts.joined(separator: " · ")
    }
}

/// The bundled measured dice-lever table (`HandicapTable.json`), or "all unmeasured".
enum HandicapTableResource {
    static let table: HandicapTable = {
        guard let url = Bundle.main.url(forResource: "HandicapTable", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let t = HandicapTable.decode(data) else { return .unmeasured }
        return t
    }()
}

/// Display copy for a resolved `HandicapSetup` (the in-game tag and its sheet).
enum HandicapCopy {
    /// Name a colour as the game names it ("You" / "Computer" vs the computer).
    static func name(_ c: TavliEngine.Color, aiColor: TavliEngine.Color?) -> String {
        if let ai = aiColor { return c == ai ? String(localized: "Computer") : String(localized: "You") }
        return c == .white ? String(localized: "White") : String(localized: "Red")
    }

    /// One line per active item, e.g. "You: head start 2".
    static func lines(_ setup: HandicapSetup, aiColor: TavliEngine.Color?) -> [String] {
        var out: [String] = []
        for c in [TavliEngine.Color.white, .black] {
            let i = setup[c]
            let who = name(c, aiColor: aiColor)
            if i.headStart > 0 {
                out.append(i.headStart == 1 ? String(localized: "\(who): 1 checker starts 6 points ahead")
                                            : String(localized: "\(who): \(i.headStart) checkers start 6 points ahead"))
            }
            if i.movesFirst { out.append(String(localized: "\(who): moves first")) }
            if i.diceTilt > 0 { out.append(diceLine(c, beta: i.diceTilt, aiColor: aiColor)) }
            if i.rerolls > 0 {
                out.append(i.rerolls == 1 ? String(localized: "\(who): 1 reroll per game")
                                          : String(localized: "\(who): \(i.rerolls) rerolls per game"))
            }
            if i.hints > 0 {
                out.append(i.hints == 1 ? String(localized: "\(who): 1 hint per game")
                                        : String(localized: "\(who): \(i.hints) hints per game"))
            }
            // Tier 2 (#148 P3b): this side's own rules.
            if i.overshoot { out.append(String(localized: "\(who): may bear off with a higher die")) }
            if i.safePoint > 0 {
                out.append(String(localized: "\(who): safe point \(i.safePoint) (a lone checker there can't be pinned)"))
            }
            if i.checkers != HandicapSetup.normalCheckers {
                out.append(String(localized: "\(who): plays with \(i.checkers) checkers"))
            }
            if i.homeSize != HandicapSetup.normalHomeSize {
                out.append(String(localized: "\(who): bears off from the last \(i.homeSize) points only"))
            }
        }
        return out
    }

    /// "Dice favour White slightly" (the disclosure for weighted dice, concept §3).
    static func diceLine(_ c: TavliEngine.Color, beta: Double, aiColor: TavliEngine.Color?) -> String {
        let who = name(c, aiColor: aiColor)
        let adverb = HandicapDiceStrength(beta: beta).adverb
        if aiColor != nil && c != aiColor {
            return String(localized: "Dice favour you \(adverb)")
        }
        return String(localized: "Dice favour \(who) \(adverb)")
    }
}
