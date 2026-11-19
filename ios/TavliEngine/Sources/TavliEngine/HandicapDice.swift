import Foundation

/// Weighted dice and the reroll policy (#148, tier 1). Pure functions over the value
/// net; `GameSession` runs them off the main actor.
///
/// **Keep in sync with the Python harness** (`domain/handicap.py` `tilted_roll_probs` /
/// `weighted_faces`, `ai/handicap_sweep.py` `wants_reroll`, `ai/agent.py` `roll_values`):
/// the 21 rolls in `diceOutcomes` order (= Python `ROLLS`) with weights 1/36 (doubles)
/// and 2/36; a roll's value is the mover's best 1-ply move value, a roll with no legal
/// move is a pass valued `1 − opponent's static value`; the tilt is
/// `p'(r) ∝ p(r)·exp(β·v(r))`, drawn by inverse CDF of `u = (int(6 u1) + u2) / 6` over
/// the 36 ordered outcomes (β = 0 is exactly `(face(u1), face(u2))`, the fair dice); the
/// reroll rule is `v(roll) < E_p[v] − 0.02` with `p` the side's own (tilted) distribution,
/// repeated while tokens remain. (The Swift has no bear-off database, so its race values
/// are the net's own.)
public enum HandicapDice {
    /// The AI rerolls when its roll's value is this far below a fresh fair roll's
    /// expected value (`rerolls` policy in the harness).
    public static let rerollMargin: Float = 0.02

    /// The 21 distinct rolls (`d1 <= d2`) in the canonical order, with their fair
    /// probabilities (doubles 1/36, the rest 2/36).
    public static var outcomes: [(d1: Int, d2: Int, p: Double)] {
        diceOutcomes.map { ($0.d1, $0.d2, ($0.d1 == $0.d2 ? 1.0 : 2.0) / 36.0) }
    }

    /// Per-roll 1-ply value for `color` to move on `board` (21 entries, `outcomes`
    /// order): the win probability of `color`'s best move, or `1 − value(opponent to
    /// move)` when the roll has no legal move. Leaves `board` unchanged.
    public static func rollValues(agent: Agent, board: GameBoard, color: Color) throws -> [Float] {
        let variant = board.variant
        let dice = Dice(numberOfSides: board.config.dieSides)
        var values: [Float] = []
        values.reserveCapacity(diceOutcomes.count)
        for o in diceOutcomes {
            dice.set(o.d1, o.d2)
            let moves = variant.legalMoves(on: board, color: color, dice: dice)
            if moves.isEmpty {
                values.append(1 - (try agent.winProbability(board, color: color.opponent)))
            } else {
                values.append(try agent.evaluateMoves(board, moves, color: color).max() ?? 0)
            }
        }
        return values
    }

    /// The tilted roll distribution `p'(r) ∝ p(r)·exp(β·v(r))` (21 entries, sums to 1).
    /// `β == 0` returns the fair probabilities exactly.
    public static func tilt(values: [Float], beta: Double) -> [Double] {
        let fair = outcomes.map(\.p)
        guard beta != 0, values.count == fair.count else { return fair }
        // Subtract the max exponent for numerical stability (cancels on normalising).
        let exps = values.map { beta * Double($0) }
        let top = exps.max() ?? 0
        let raw = zip(fair, exps).map { $0 * Foundation.exp($1 - top) }
        let total = raw.reduce(0, +)
        return total > 0 ? raw.map { $0 / total } : fair
    }

    /// A fair die face from a uniform in [0, 1) (`face` in `domain/handicap.py`).
    public static func face(_ u: Double) -> Int { 1 + min(Int(u * 6), 5) }

    /// Ordered dice faces for uniforms `u1`, `u2` in [0, 1) — Python `weighted_faces`:
    /// inverse CDF of `u = (int(6 u1) + u2) / 6` over the 36 ordered outcomes in
    /// lexicographic order, each weighted by its unordered roll's tilt `exp(β·v)`.
    /// `β == 0` (or no values) is the fair path `(face(u1), face(u2))`.
    public static func weightedFaces(u1: Double, u2: Double, values: [Float]?, beta: Double) -> (Int, Int) {
        guard beta != 0, let values, values.count == diceOutcomes.count else {
            return (face(u1), face(u2))
        }
        let vmax = Double(values.max() ?? 0)
        let tilt = values.map { Foundation.exp(beta * (Double($0) - vmax)) }
        var cum: [Double] = []
        cum.reserveCapacity(36)
        var total = 0.0
        for a in 1...6 {
            for b in 1...6 {
                total += tilt[outcomeIndex(a, b)!]
                cum.append(total)
            }
        }
        let target = (Double(Int(u1 * 6)) + u2) / 6 * total
        var k = 35
        for (i, c) in cum.enumerated() where target < c { k = i; break }
        return (1 + k / 6, 1 + k % 6)
    }

    /// The expected value of a fresh roll under `probabilities` (default fair).
    public static func expectedValue(_ values: [Float], probabilities: [Double]? = nil) -> Float {
        let p = probabilities ?? outcomes.map(\.p)
        return Float(zip(p, values).reduce(0.0) { $0 + $1.0 * Double($1.1) })
    }

    /// The index into `outcomes` of the roll `(d1, d2)` (either order).
    public static func outcomeIndex(_ d1: Int, _ d2: Int) -> Int? {
        let lo = min(d1, d2), hi = max(d1, d2)
        return diceOutcomes.firstIndex { $0.d1 == lo && $0.d2 == hi }
    }

    /// The computer's reroll rule (harness `wants_reroll`): reroll when the current
    /// roll's value is below the expectation of a fresh roll under the side's own roll
    /// distribution (tilted by its `beta`, fair at 0) by more than `rerollMargin`.
    public static func shouldReroll(values: [Float], d1: Int, d2: Int, beta: Double = 0) -> Bool {
        guard values.count == diceOutcomes.count, let i = outcomeIndex(d1, d2) else { return false }
        let expected = expectedValue(values, probabilities: tilt(values: values, beta: beta))
        return values[i] < expected - rerollMargin
    }
}

// MARK: - Win-chance estimate (concept §5)

/// How the starter of a handicap game is decided, for the position estimate. Mirrors
/// the app: the opening roll-off is a fair coin (the starter then rolls fresh dice),
/// a forced starter (Settings "First move", two-player house Plakoto's White) is fixed.
public enum HandicapStartRule: Equatable, Sendable {
    case rollOff
    case fixed(Color)
}

/// The measured dice-lever table (`HandicapTable.json`, concept §5): per harness cell
/// label — `weighted_dice:4`, `rerolls:2`, combos joined with `+` as in
/// `docs/handicap-e1-tier1.json` — the shift in log-odds for the **favoured** side
/// (`logit(favoured win rate)`; the harness reports the handicapped side's rate, and
/// both dice kinds are bonus kinds, so favoured rate = 1 − rate). `nil` = not measured
/// yet. Generated by `ios/scripts/make_handicap_table.py`.
public struct HandicapTable: Codable, Equatable, Sendable {
    public struct Cell: Codable, Equatable, Sendable {
        public var logOddsShift: Double?
        public init(logOddsShift: Double?) { self.logOddsShift = logOddsShift }
    }
    public var version: Int
    public var cells: [String: Cell]

    public init(version: Int = 1, cells: [String: Cell] = [:]) {
        self.version = version
        self.cells = cells
    }

    /// An empty table: every dice lever unmeasured.
    public static let unmeasured = HandicapTable()

    public static func decode(_ data: Data) -> HandicapTable? {
        try? JSONDecoder().decode(HandicapTable.self, from: data)
    }

    /// The harness cell label for one lever (`weighted_dice:4`, `rerolls:2`).
    public static func label(_ kind: String, _ intensity: Double) -> String {
        intensity.rounded() == intensity ? "\(kind):\(Int(intensity))" : "\(kind):\(intensity)"
    }

    /// The measured shift for one side's dice levers: an exact measured cell for the
    /// whole set (a combo, either order), else the sum of the singles, else `nil` when
    /// any single is unmeasured. Also returns the unmeasured lever kinds.
    func shift(for labels: [String]) -> (shift: Double, unmeasured: [String]) {
        guard !labels.isEmpty else { return (0, []) }
        if labels.count > 1 {
            for perm in Self.permutations(labels) {
                if let d = cells[perm.joined(separator: "+")]?.logOddsShift { return (d, []) }
            }
        }
        var total = 0.0
        var missing: [String] = []
        for l in labels {
            if let d = cells[l]?.logOddsShift { total += d }
            else { missing.append(String(l.split(separator: ":")[0])) }
        }
        return (total, missing)
    }

    /// Every ordering of `items` (the harness joins combo labels in its own lever order).
    static func permutations(_ items: [String]) -> [[String]] {
        guard items.count > 1 else { return [items] }
        var out: [[String]] = []
        for (i, x) in items.enumerated() {
            var rest = items
            rest.remove(at: i)
            for p in permutations(rest) { out.append([x] + p) }
        }
        return out
    }

    /// The tier-2 cells of `setup` (#148 E3) as harness labels grouped by the sweep's
    /// *handicapped* colour (spec `side`), whose opponent the cell's `logOddsShift`
    /// favours. Mapping from the app's per-side items (each describing its side's own
    /// rules): overshoot / safe point → the side holding it is favoured (spec side =
    /// its opponent); smaller home → the side with it is the spec side; fewer than 15
    /// checkers → that side is the favoured one (`HandicapSpec.target` = −side), more
    /// than 15 → that side is the spec side. (The measured checker shifts are negative:
    /// more checkers is the advantage.)
    public static func tier2Groups(_ setup: HandicapSetup) -> [Color: [String]] {
        let s = setup.normalized
        var groups: [Color: [String]] = [:]
        for side in Color.allCases {
            let items = s[side]
            // Fixed order like the harness: overshoot, safe_point, checkers, smaller_house.
            if items.overshoot { groups[side.opponent, default: []].append("overshoot:1") }
            if items.safePoint > 0 { groups[side.opponent, default: []].append("safe_point:\(items.safePoint)") }
            if items.checkers < HandicapSetup.normalCheckers {
                groups[side.opponent, default: []].append("checkers:\(items.checkers)")
            } else if items.checkers > HandicapSetup.normalCheckers {
                groups[side, default: []].append("checkers:\(items.checkers)")
            }
            if items.homeSize < HandicapSetup.normalHomeSize {
                groups[side, default: []].append("smaller_house:\(items.homeSize)")
            }
        }
        return groups
    }
}

/// The builder's live estimate.
public struct HandicapEstimate: Equatable, Sendable {
    /// White's estimated win chance, combining every lever that has a number.
    public var whiteWinChance: Double
    /// Dice levers that are active but not measured yet (excluded from the number), by
    /// harness kind: `"weighted_dice"`, `"rerolls"`.
    public var unmeasured: [String]
    /// Hints are active (never in the number; the line says "approx.").
    public var approximate: Bool
}

public enum HandicapEstimator {
    /// Per head-start checker, the relative boost to the same side's dice-lever shift
    /// (fitted on E1's head-start × dice combos: ≈ 1.4× at m = 4).
    public static let headStartDiceInteraction = 0.1

    /// The position levers' estimate (head start ± moves first): White's win chance
    /// from the handicap start position, averaging the net's best 1-ply move value over
    /// the starter's 21 opening rolls (weighted). With "moves first" the favoured side
    /// starts; otherwise `rule` decides (the roll-off averages both starters).
    public static func positionWhiteWinChance(setup: HandicapSetup, agent: Agent,
                                              rule: HandicapStartRule) throws -> Double {
        // Tier-2 levers are not in the net's view (its handicap inputs are zero, §11):
        // the position estimate is the normal 15/15 start with the head start only.
        let setup = setup.tier1Only
        let board = GameBoard(config: GameConfig(variant: agent.variant))
        setup.setUpInitialPosition(on: board)
        func white(ifStarts starter: Color) throws -> Double {
            let values = try HandicapDice.rollValues(agent: agent, board: board, color: starter)
            let p = Double(HandicapDice.expectedValue(values))
            return starter == .white ? p : 1 - p
        }
        if let forced = setup.forcedStarter { return try white(ifStarts: forced) }
        switch rule {
        case .fixed(let c): return try white(ifStarts: c)
        case .rollOff: return 0.5 * (try white(ifStarts: .white)) + 0.5 * (try white(ifStarts: .black))
        }
    }

    /// Combine levers by adding log-odds (concept §5): the position estimate plus each
    /// measured dice lever's shift (positive for White's levers, negative for Black's),
    /// plus the tier-2 levers' measured shifts (`HandicapTable.tier2Groups`).
    /// Unmeasured dice levers are listed, not guessed; hints only flag "approx.".
    public static func combine(positionWhite: Double, setup: HandicapSetup,
                               table: HandicapTable) -> HandicapEstimate {
        let s = setup.normalized
        let p0 = max(min(positionWhite, 1 - 1e-6), 1e-6)
        var logit = log(p0 / (1 - p0))
        var unmeasured: [String] = []
        for color in Color.allCases {
            let sign: Double = color == .white ? 1 : -1
            let items = s[color]
            var labels: [String] = []
            if items.diceTilt > 0 { labels.append(HandicapTable.label("weighted_dice", items.diceTilt)) }
            if items.rerolls > 0 { labels.append(HandicapTable.label("rerolls", Double(items.rerolls))) }
            let (shift, missing) = table.shift(for: labels)
            if missing.isEmpty {
                // E1: a head start amplifies the same side's dice levers (combos with
                // m = 4 measured 1.36–1.52× the dice shift on top of the head start).
                logit += sign * shift * (1 + headStartDiceInteraction * Double(items.headStart))
            } else {
                for kind in missing where !unmeasured.contains(kind) { unmeasured.append(kind) }
            }
        }
        // Tier 2 (#148 E3): one exact measured cell per handicapped colour when the
        // whole group was measured as a combo (any order), else the sum of the singles.
        // Each group shifts toward the spec side's opponent.
        for (specSide, labels) in HandicapTable.tier2Groups(s) {
            let (shift, missing) = table.shift(for: labels)
            if missing.isEmpty {
                logit += (specSide == .black ? 1 : -1) * shift
            } else {
                for kind in missing where !unmeasured.contains(kind) { unmeasured.append(kind) }
            }
        }
        let p = 1 / (1 + exp(-logit))
        return HandicapEstimate(whiteWinChance: p, unmeasured: unmeasured,
                                approximate: s.white.hints > 0 || s.black.hints > 0)
    }
}
