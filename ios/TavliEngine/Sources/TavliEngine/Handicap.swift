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

    public init(headStart: Int = 0, movesFirst: Bool = false, diceTilt: Double = 0,
                rerolls: Int = 0, hints: Int = 0) {
        self.headStart = headStart
        self.movesFirst = movesFirst
        self.diceTilt = diceTilt
        self.rerolls = rerolls
        self.hints = hints
    }

    public static let none = HandicapItems()

    /// No handicap on this side.
    public var isEmpty: Bool { self == .none }

    // Decode tolerantly: a missing key is "off" (a later version may add items).
    private enum CodingKeys: String, CodingKey { case headStart, movesFirst, diceTilt, rerolls, hints }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headStart = try c.decodeIfPresent(Int.self, forKey: .headStart) ?? 0
        movesFirst = try c.decodeIfPresent(Bool.self, forKey: .movesFirst) ?? false
        diceTilt = try c.decodeIfPresent(Double.self, forKey: .diceTilt) ?? 0
        rerolls = try c.decodeIfPresent(Int.self, forKey: .rerolls) ?? 0
        hints = try c.decodeIfPresent(Int.self, forKey: .hints) ?? 0
    }

    /// Clamped into the supported ranges.
    public var clamped: HandicapItems {
        HandicapItems(headStart: min(max(headStart, 0), HandicapSetup.maxHeadStart),
                      movesFirst: movesFirst,
                      diceTilt: diceTilt.isFinite ? max(diceTilt, 0) : 0,
                      rerolls: min(max(rerolls, 0), HandicapSetup.maxRerolls),
                      hints: min(max(hints, 0), HandicapSetup.maxHints))
    }
}

/// A complete tier-1 handicap description, per side. Codable + versioned; persisted in
/// `GameSave.handicap` (inside `HandicapGameState`) and `HumanGameRecord.handicap`.
public struct HandicapSetup: Codable, Equatable, Hashable, Sendable {
    /// The schema this build writes. A newer version still decodes (unknown items are
    /// ignored), so an old reader plays the items it knows.
    public static let currentVersion = 1

    public static let maxHeadStart = 8
    public static let maxRerolls = 4
    public static let maxHints = 5
    /// The weighted-dice strengths the app offers, Off → Very strong. The **one place**
    /// the β grid lives (retune after measurement). Matches the harness grid
    /// (`KINDS["weighted_dice"]`: 1, 2, 4, 8, 16; β ≈ 1 barely registers, so the app
    /// starts at 2).
    public static let diceTiltSteps: [Double] = [0, 2, 4, 8, 16]
    /// Pips a head-start checker starts ahead (`pip_headstart`: 6).
    public static let headStartPips = 6
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

    /// Lay out the handicapped starting position: the variant's initial position, then
    /// each side's head-start checkers moved 6 pips forward from its start point.
    /// Reproduces `HandicappedPlakotoRules.initial_board` (`domain/handicap.py`,
    /// `pip_headstart`): White's start point 1 → point 7, Black's 24 → point 18.
    /// **Keep in sync with the Python** (pinned by `HandicapTests`).
    public func setUpInitialPosition(on board: GameBoard) {
        board.variant.setUpInitialPosition(on: board)
        let n = normalized
        let size = board.boardSize
        for color in Color.allCases {
            let m = min(n[color].headStart, board.numberOfPieces - 1)
            guard m > 0 else { continue }
            let start = color == .white ? 1 : size
            let ahead = color == .white ? start + Self.headStartPips : start - Self.headStartPips
            let remaining = board.points[start].pieces.count - m
            board.setPoint(start, pieces: Array(repeating: color, count: remaining))
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
