import Foundation

// Handicap system, tier 1 (#148, spec `docs/handicap-concept.md` §3/§7).
//
// A handicap gives one side (the *favoured* side) a structural advantage while both
// sides keep playing by the normal house-Plakoto rules. Tier 1 needs no retraining:
// head start, moves first, weighted dice, rerolls and hints. `HandicapSetup` is the
// persisted description (per side); `HandicapGameState` adds the per-game tokens
// (rerolls / hints left) that a save carries so a resumed game keeps its counts.
//
// **Off path.** No setup (or an inactive one) means nothing changes: `GameSession`
// only consults any of this when `handicap != nil`, saves omit the key, and the
// position/dice/turn order are exactly the unhandicapped ones.

/// One side's tier-1 handicaps. All defaults = no handicap for that side.
public struct HandicapItems: Codable, Equatable, Hashable, Sendable {
    /// Checkers that start 6 pips advanced (0…8). Mirrors `pip_headstart` in
    /// `domain/handicap.py` (there given as a bonus kind on the opponent's spec).
    public var headStart: Int
    /// This side always starts; no opening roll-off.
    public var movesFirst: Bool
    /// Weighted-dice strength β (0 = fair). Before this side rolls, each of the 21
    /// distinct rolls is tilted by `exp(β · v(roll))`, `v` = the side's best 1-ply move
    /// value. See `HandicapDice`.
    public var diceTilt: Double
    /// Rerolls per game (0…4).
    public var rerolls: Int
    /// Hints per game (0…5); only meaningful for a human side.
    public var hints: Int

    // ── Tier 2 (#148 P3b): this side's own rules (`SideRules`), defaults = normal. ──

    /// This side may bear off with a higher die (only from its farthest occupied point).
    public var overshoot: Bool
    /// This side's safe point (own numbering, one of `HandicapSetup.safePointCandidates`;
    /// 0 = none): a lone checker of this side there cannot be pinned.
    public var safePoint: Int
    /// This side's checker count (13…17, default 15). More checkers is the advantage.
    public var checkers: Int
    /// This side bears off only from its last `homeSize` points (6 default, 5/4/3).
    public var homeSize: Int

    public init(headStart: Int = 0, movesFirst: Bool = false, diceTilt: Double = 0,
                rerolls: Int = 0, hints: Int = 0, overshoot: Bool = false, safePoint: Int = 0,
                checkers: Int = HandicapSetup.normalCheckers, homeSize: Int = HandicapSetup.normalHomeSize) {
        self.headStart = headStart
        self.movesFirst = movesFirst
        self.diceTilt = diceTilt
        self.rerolls = rerolls
        self.hints = hints
        self.overshoot = overshoot
        self.safePoint = safePoint
        self.checkers = checkers
        self.homeSize = homeSize
    }

    public static let none = HandicapItems()

    /// No handicap on this side.
    public var isEmpty: Bool { self == .none }

    /// Any tier-2 (rule) item on this side.
    public var hasTier2: Bool { sideRules != .normal }

    /// This side's tier-2 rules.
    public var sideRules: SideRules {
        SideRules(overshoot: overshoot, safePoint: safePoint, checkers: checkers, homeSize: homeSize)
    }

    /// The same side with every tier-2 item off.
    public var tier1Only: HandicapItems {
        var t = self
        t.overshoot = false
        t.safePoint = 0
        t.checkers = HandicapSetup.normalCheckers
        t.homeSize = HandicapSetup.normalHomeSize
        return t
    }

    // Decode tolerantly: a missing key is "off" (a later version may add items, and a
    // version-1 setup has no tier-2 keys). An older build ignores the tier-2 keys.
    private enum CodingKeys: String, CodingKey {
        case headStart, movesFirst, diceTilt, rerolls, hints, overshoot, safePoint, checkers, homeSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headStart = try c.decodeIfPresent(Int.self, forKey: .headStart) ?? 0
        movesFirst = try c.decodeIfPresent(Bool.self, forKey: .movesFirst) ?? false
        diceTilt = try c.decodeIfPresent(Double.self, forKey: .diceTilt) ?? 0
        rerolls = try c.decodeIfPresent(Int.self, forKey: .rerolls) ?? 0
        hints = try c.decodeIfPresent(Int.self, forKey: .hints) ?? 0
        overshoot = try c.decodeIfPresent(Bool.self, forKey: .overshoot) ?? false
        safePoint = try c.decodeIfPresent(Int.self, forKey: .safePoint) ?? 0
        checkers = try c.decodeIfPresent(Int.self, forKey: .checkers) ?? HandicapSetup.normalCheckers
        homeSize = try c.decodeIfPresent(Int.self, forKey: .homeSize) ?? HandicapSetup.normalHomeSize
    }

    /// Clamped into the supported ranges (an unknown safe point is dropped).
    public var clamped: HandicapItems {
        HandicapItems(headStart: min(max(headStart, 0), HandicapSetup.maxHeadStart),
                      movesFirst: movesFirst,
                      diceTilt: diceTilt.isFinite ? max(diceTilt, 0) : 0,
                      rerolls: min(max(rerolls, 0), HandicapSetup.maxRerolls),
                      hints: min(max(hints, 0), HandicapSetup.maxHints),
                      overshoot: overshoot,
                      safePoint: HandicapSetup.safePointCandidates.contains(safePoint) ? safePoint : 0,
                      checkers: min(max(checkers, HandicapSetup.checkerRange.lowerBound),
                                    HandicapSetup.checkerRange.upperBound),
                      homeSize: min(max(homeSize, HandicapSetup.homeSizes.last!), HandicapSetup.normalHomeSize))
    }
}

/// A complete tier-1 handicap description, per side. Codable + versioned; persisted in
/// `GameSave.handicap` (inside `HandicapGameState`) and `HumanGameRecord.handicap`.
public struct HandicapSetup: Codable, Equatable, Hashable, Sendable {
    /// The schema this build writes. A newer version still decodes (unknown items are
    /// ignored), so an old reader plays the items it knows. Version 2 (#148 P3b) adds the
    /// tier-2 items (overshoot, safe point, checkers, home size); a version-1 build ignores
    /// them and would replay such a game under the normal rules.
    public static let currentVersion = 2

    /// Capped at 4 by E1 (docs/handicap-e1-tier1.md): the head start's effect saturates
    /// (m = 4: +8.0 pp, 6: +9.2, 8: +7.6) and the net's start-position estimate is within
    /// 1 pp up to m = 4 but 3–5 pp off beyond.
    public static let maxHeadStart = 4
    public static let maxRerolls = 4
    public static let maxHints = 5
    /// The weighted-dice strengths the app offers, Off → Very strong. The **one place**
    /// the β grid lives. Calibrated by E1 (gold_v11, 1-ply, 1 000 pairs/cell): β 0.3 / 0.6 /
    /// 1.2 / 2.0 give the favoured side +3.7 / +6.2 / +13.6 / +22.0 pp. The first-order
    /// estimate ΔP ≈ β·Σ Var(v) is ≈ +13.5 pp per unit β for small β.
    public static let diceTiltSteps: [Double] = [0, 0.3, 0.6, 1.2, 2.0]
    /// Pips a head-start checker starts ahead (`pip_headstart`: 6).
    public static let headStartPips = 6
    /// Tier 2: safe-point candidates in the side's own numbering (`SAFE_POINT_CANDIDATES`:
    /// the opponent's home and the near outer board; 1 would be mother protection).
    public static let safePointCandidates = [2, 4, 6, 8, 10, 12]
    /// Tier 2: checker counts a side may play with (`MIN_CHECKERS…MAX_CHECKERS`).
    public static let checkerRange = 13...17
    public static let normalCheckers = 15
    /// Tier 2: home sizes, normal first.
    public static let homeSizes = [6, 5, 4, 3]
    public static let normalHomeSize = 6
    /// The only variant handicaps apply to (house Plakoto).
    public static let supportedVariantID = "plakoto"

    public var version: Int
    public var white: HandicapItems
    public var black: HandicapItems

    public init(white: HandicapItems = .none, black: HandicapItems = .none,
                version: Int = HandicapSetup.currentVersion) {
        self.version = version
        self.white = white
        self.black = black
    }

    public subscript(color: Color) -> HandicapItems {
        get { color == .white ? white : black }
        set { if color == .white { white = newValue } else { black = newValue } }
    }

    /// Any handicap on either side.
    public var isActive: Bool { !white.isEmpty || !black.isEmpty }

    /// Clamped ranges; "moves first" on both sides cancels out (the normal start rule
    /// applies), so it is dropped from both.
    public var normalized: HandicapSetup {
        var s = HandicapSetup(white: white.clamped, black: black.clamped, version: version)
        if s.white.movesFirst && s.black.movesFirst {
            s.white.movesFirst = false
            s.black.movesFirst = false
        }
        return s
    }

    /// The side that must start ("moves first"), or `nil` for the normal start rule.
    public var forcedStarter: Color? {
        let n = normalized
        if n.white.movesFirst { return .white }
        if n.black.movesFirst { return .black }
        return nil
    }

    /// The starter of a game under `setup`: the "moves first" side, else `defaultStarter`
    /// (the opening roll's winner, a forced first move, or a best-of-three game's
    /// alternating starter — "moves first" overrides the alternation every game).
    public static func startingPlayer(for setup: HandicapSetup?, default defaultStarter: Color) -> Color {
        setup?.forcedStarter ?? defaultStarter
    }

    /// Any tier-2 (rule) item on either side.
    public var hasTier2: Bool { white.hasTier2 || black.hasTier2 }

    /// The tier-2 rules the game is played under, or `nil` when there are none (the
    /// normal rules and move generator).
    public var rules: HandicapRules? {
        let n = normalized
        guard n.hasTier2 else { return nil }
        return HandicapRules(white: n.white.sideRules, black: n.black.sideRules)
    }

    /// The same setup with every tier-2 item off (the net's position estimate, which
    /// must not see the tier-2 rules: §11).
    public var tier1Only: HandicapSetup {
        HandicapSetup(white: white.tier1Only, black: black.tier1Only, version: version)
    }

    /// Whether either side's dice are tilted.
    public var hasWeightedDice: Bool { white.diceTilt > 0 || black.diceTilt > 0 }
    /// Whether either side has rerolls.
    public var hasRerolls: Bool { white.rerolls > 0 || black.rerolls > 0 }
    /// Whether the dice were not fair for the whole game (weighted dice or rerolls):
    /// the review's win chances, which assume fair dice, then carry a note.
    public var altersDice: Bool { hasWeightedDice || hasRerolls }
    /// Whether any item needs the value net during play (dice, rerolls, hints).
    public var needsEvaluator: Bool {
        hasWeightedDice || hasRerolls || white.hints > 0 || black.hints > 0
    }

    /// Handicaps only apply to house Plakoto.
    public static func supports(variantID: String) -> Bool { variantID == supportedVariantID }

    /// Lay out the handicapped starting position: each side's start stack holds its
    /// checker count (15, or its tier-2 count), then its head-start checkers move 6 pips
    /// forward. Reproduces `HandicappedPlakotoRules.initial_board` (`domain/handicap.py`,
    /// `pip_headstart` + `checkers`): White's start point 1 → point 7, Black's 24 → 18.
    /// The board's config must carry `rules` (`GameConfig.applying(_:)`) for the game to
    /// be played under them. **Keep in sync with the Python** (pinned by `HandicapTests`).
    public func setUpInitialPosition(on board: GameBoard) {
        board.variant.setUpInitialPosition(on: board)
        let n = normalized
        let size = board.boardSize
        for color in Color.allCases {
            let count = n[color].checkers
            let m = min(n[color].headStart, count - 1)
            let start = color == .white ? 1 : size
            board.setPoint(start, pieces: Array(repeating: color, count: count - m))
            guard m > 0 else { continue }
            let ahead = color == .white ? start + Self.headStartPips : start - Self.headStartPips
            board.setPoint(ahead, pieces: Array(repeating: color, count: m))
        }
    }

    // Tolerant decode: items default to "off"; version defaults to 1.
    private enum CodingKeys: String, CodingKey { case version, white, black }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        white = try c.decodeIfPresent(HandicapItems.self, forKey: .white) ?? .none
        black = try c.decodeIfPresent(HandicapItems.self, forKey: .black) ?? .none
    }
}

/// A count per side (tokens left).
public struct SideCounts: Codable, Equatable, Hashable, Sendable {
    public var white: Int
    public var black: Int

    public init(white: Int = 0, black: Int = 0) {
        self.white = white
        self.black = black
    }

    public subscript(color: Color) -> Int {
        get { color == .white ? white : black }
        set { if color == .white { white = newValue } else { black = newValue } }
    }
}

/// A live handicap game: the setup plus the tokens left. This is what `GameSave`
/// persists under the optional `handicap` key (no schema bump: an old reader ignores
/// the key and loads the game unhandicapped; a save without it is byte-identical to
/// before).
public struct HandicapGameState: Codable, Equatable, Sendable {
    public var setup: HandicapSetup
    public var rerollsLeft: SideCounts
    public var hintsLeft: SideCounts

    /// A fresh game: every token available.
    public init(setup: HandicapSetup) {
        let s = setup.normalized
        self.setup = s
        self.rerollsLeft = SideCounts(white: s.white.rerolls, black: s.black.rerolls)
        self.hintsLeft = SideCounts(white: s.white.hints, black: s.black.hints)
    }

    public init(setup: HandicapSetup, rerollsLeft: SideCounts, hintsLeft: SideCounts) {
        self.setup = setup.normalized
        self.rerollsLeft = rerollsLeft
        self.hintsLeft = hintsLeft
    }

    private enum CodingKeys: String, CodingKey { case setup, rerollsLeft, hintsLeft }

    /// Tolerant: missing token counts mean "all left"; counts are clamped to the setup.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = HandicapGameState(setup: try c.decode(HandicapSetup.self, forKey: .setup))
        setup = fresh.setup
        let r = try c.decodeIfPresent(SideCounts.self, forKey: .rerollsLeft) ?? fresh.rerollsLeft
        let h = try c.decodeIfPresent(SideCounts.self, forKey: .hintsLeft) ?? fresh.hintsLeft
        rerollsLeft = SideCounts(white: min(max(r.white, 0), fresh.rerollsLeft.white),
                                 black: min(max(r.black, 0), fresh.rerollsLeft.black))
        hintsLeft = SideCounts(white: min(max(h.white, 0), fresh.hintsLeft.white),
                               black: min(max(h.black, 0), fresh.hintsLeft.black))
    }
}

public extension GameRecord {
    /// The config this game is replayed under: its variant plus any tier-2 rules (#148).
    var replayConfig: GameConfig { GameConfig(variantID: variantID).applying(handicap) }

    /// Lay out this game's starting position: the variant's, plus any handicap head
    /// start (#148). Every replay from the start (review, notation, resume) goes
    /// through this so a head-start game reconstructs exactly.
    func setUpInitialPosition(on board: GameBoard) {
        if let handicap {
            handicap.setUpInitialPosition(on: board)
        } else {
            board.variant.setUpInitialPosition(on: board)
        }
    }
}
