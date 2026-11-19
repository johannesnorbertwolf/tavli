import Foundation

// Handicap system, tier 2 (#148 P3b, spec `docs/handicap-concept.md` §3/§11/§12).
//
// Tier-2 levers change the *rules* of house Plakoto per side. They travel with the
// board as `GameConfig.handicapRules` (nil = the normal game, every code path
// unchanged), so every board copy the session, search, review and move builder make
// with `GameBoard(config: board.config)` plays the same rules. `PlakotoVariant`
// consults them only when set; the move generator is `HandicapMoveGenerator`, a port of
// `domain/handicap_moves.py` `legal_moves_tier2` over `domain/handicap.py`
// `HandicapBoard`. **Keep in sync with the Python** (pinned by `Tier2ParityTests`).

/// One side's tier-2 rules, each describing that side's OWN game (mirrors the
/// per-colour fields of `HandicapBoard`).
public struct SideRules: Codable, Equatable, Hashable, Sendable {
    /// This side may bear off with a higher die (standard-Plakoto rule: only from its
    /// farthest occupied point; own pinned checkers count).
    public var overshoot: Bool
    /// This side's safe point in its own numbering (1 = its start; 0 = none): a lone
    /// checker of this side there cannot be pinned.
    public var safePoint: Int
    /// This side's checker count (13…17; 15 = normal). It wins with all of them off.
    public var checkers: Int
    /// This side bears off only from its last `homeSize` points (6 = normal).
    public var homeSize: Int

    public init(overshoot: Bool = false, safePoint: Int = 0, checkers: Int = 15, homeSize: Int = 6) {
        self.overshoot = overshoot
        self.safePoint = safePoint
        self.checkers = checkers
        self.homeSize = homeSize
    }

    public static let normal = SideRules()
}

/// Both sides' tier-2 rules (`nil` on `GameConfig` = the normal game).
public struct HandicapRules: Codable, Equatable, Hashable, Sendable {
    public var white: SideRules
    public var black: SideRules

    public init(white: SideRules = .normal, black: SideRules = .normal) {
        self.white = white
        self.black = black
    }

    public subscript(color: Color) -> SideRules {
        get { color == .white ? white : black }
        set { if color == .white { white = newValue } else { black = newValue } }
    }

    /// Board index of `color`'s safe point (`-1` = none). White's point p is index p,
    /// Black's is `boardSize + 1 - p` (`HandicapBoard._sync_safe_slots`).
    public func safeSlot(_ color: Color, boardSize: Int) -> Int {
        let p = self[color].safePoint
        guard p > 0 else { return -1 }
        return color.isWhite ? p : boardSize + 1 - p
    }
}

public extension GameConfig {
    /// This config playing under `rules` (`nil` = the normal game).
    func withHandicapRules(_ rules: HandicapRules?) -> GameConfig {
        GameConfig(boardSize: boardSize, piecesPerPlayer: piecesPerPlayer, homeSize: homeSize,
                   dieSides: dieSides, variant: variant, handicapRules: rules)
    }

    /// This config with `setup`'s tier-2 rules — only for house Plakoto, else unchanged.
    func applying(_ setup: HandicapSetup?) -> GameConfig {
        guard let setup, HandicapSetup.supports(variantID: variant.id) else { return self }
        return withHandicapRules(setup.rules)
    }
}

// MARK: - Rules on the board

extension GameBoard {
    /// Whether a `color` checker may land on index `i` under the tier-2 rules: the plain
    /// rule, except a lone opponent checker on the opponent's safe point
    /// (`HandicapBoard.is_open_for`).
    func handicapIsOpen(_ i: Int, for color: Color, rules: HandicapRules) -> Bool {
        let p = points[i]
        guard p.isOpen(for: color) else { return false }
        if p.count == 1, p.topColor == color.opponent {
            return i != rules.safeSlot(color.opponent, boardSize: boardSize)
        }
        return true
    }
}

extension PlakotoVariant {
    /// `isLegalStep` under tier-2 rules: exact die, or (overshoot side) a bear-off with a
    /// larger die when no own checker — movable or pinned — is farther from the slot.
    func handicapIsLegalStep(from: Int, to: Int, color: Color, die: Int, on board: GameBoard,
                             rules: HandicapRules) -> Bool {
        let n = board.boardSize
        let off = bearOffPoint(for: color, boardSize: n)
        let dist = pathIndex(of: to, for: color, boardSize: n) - pathIndex(of: from, for: color, boardSize: n)
        guard (1...n).contains(from), movableCount(at: from, for: color, on: board) > 0,
              board.handicapIsOpen(to, for: color, rules: rules) else { return false }
        if to != off { return dist == die }
        guard board.countCheckersOutsideHome(color) == 0 else { return false }
        if dist == die { return true }
        guard dist < die, rules[color].overshoot else { return false }
        return !HandicapMoveGenerator.hasFartherOwn(board, color: color, than: from)
    }

    /// Midpoints through which a one-checker two-dice half can be played as two legal
    /// steps (exact landings and overshoot bear-offs alike), `die1`/`die2` order.
    func handicapIntermediatePoints(of half: HalfMove, die1: Int, die2: Int, on board: GameBoard,
                                    rules: HandicapRules) -> [Int] {
        let n = board.boardSize
        let color = half.color
        let from = half.from.position, to = half.to.position
        let start = pathIndex(of: from, for: color, boardSize: n)
        let end = pathIndex(of: to, for: color, boardSize: n)
        // A merged half covers both dice: exactly, or (a bear-off) at most.
        let dist = end - start
        guard dist == die1 + die2 || (to == bearOffPoint(for: color, boardSize: n) && dist < die1 + die2)
        else { return [] }
        return twoStepMids(from: from, to: to, color: color, die1: die1, die2: die2, board: board, rules: rules)
    }

    private func twoStepMids(from: Int, to: Int, color: Color, die1: Int, die2: Int,
                               board: GameBoard, rules: HandicapRules) -> [Int] {
        let n = board.boardSize
        let start = pathIndex(of: from, for: color, boardSize: n)
        var mids: [Int] = []
        for (a, b) in [(die1, die2), (die2, die1)] {
            guard start + a <= n else { continue }
            let mid = point(atPath: start + a, for: color, boardSize: n)
            guard !mids.contains(mid),
                  handicapIsLegalStep(from: from, to: mid, color: color, die: a, on: board, rules: rules)
            else { continue }
            let snap = board.captureSnapshot()
            applyHalfMove(HalfMove(from: board.points[from], to: board.points[mid], color: color), on: board)
            let ok = handicapIsLegalStep(from: mid, to: to, color: color, die: b, on: board, rules: rules)
            board.restore(snap)
            if ok { mids.append(mid) }
        }
        return mids
    }
}

// MARK: - Move generation (port of domain/handicap_moves.py)

/// House-Plakoto legal moves under tier-2 rules, as `legal_moves_tier2`: the house
/// generator's structure (pairs + merged single-checker jumps + rule-2 singles; the nested
/// pasch loop with its persistent "shorter sequence" flags) over the rules' open points
/// and home sizes, plus — for an overshoot side — bear-offs with a die larger than the
/// distance (all own checkers home, none farther from the slot, own pinned ones count).
/// Works on a private array copy of the position (board indices, Python's `n`/`color`/
/// `pinned` model); results are deduplicated by their set of halves.
struct HandicapMoveGenerator {
    private let board: GameBoard
    private let color: Color
    private let c: Int          // +1 White, -1 Black (Python colours)
    private let bs: Int
    private let off: Int
    private let over: Bool
    private let homeLo: Int     // own home, board indices homeLo...homeHi
    private let homeHi: Int
    private let oppSafe: Int    // opponent's safe slot (-1 = none)
    private var n: [Int]
    private var col: [Int]
    private var pin: [Bool]

    init(board: GameBoard, color: Color, rules: HandicapRules) {
        self.board = board
        self.color = color
        c = color.isWhite ? 1 : -1
        bs = board.boardSize
        off = color.isWhite ? bs + 1 : 0
        over = rules[color].overshoot
        let h = rules[color].homeSize
        homeLo = color.isWhite ? bs - h + 1 : 1
        homeHi = color.isWhite ? bs : h
        oppSafe = rules.safeSlot(color.opponent, boardSize: bs)
        n = [Int](repeating: 0, count: bs + 2)
        col = [Int](repeating: 0, count: bs + 2)
        pin = [Bool](repeating: false, count: bs + 2)
        for i in 0...(bs + 1) {
            let p = board.points[i]
            guard let top = p.topColor else { continue }
            col[i] = top.isWhite ? 1 : -1
            n[i] = p.activeCount
            pin[i] = p.isCaptured
        }
    }

    /// Whether `color` has a checker (own stack, or pinned under an opponent) on a point
    /// farther from its bear-off slot than `src` (`_farther_own`), on a live board.
    static func hasFartherOwn(_ board: GameBoard, color: Color, than src: Int) -> Bool {
        let range = color.isWhite ? Array(1..<max(src, 1)) : Array((src + 1)..<(board.boardSize + 1))
        for i in range {
            let p = board.points[i]
            guard let top = p.topColor else { continue }
            if top == color || (p.isCaptured && p.pieces[0] == color) { return true }
        }
        return false
    }

    // ── board model ──

    private func isHome(_ i: Int) -> Bool { homeLo <= i && i <= homeHi }
    private func isOffBoard(_ i: Int) -> Bool { i == 0 || i == bs + 1 }

    private func isOpen(_ i: Int) -> Bool {
        if n[i] == 0 || col[i] == c { return true }
        if n[i] != 1 || pin[i] { return false }
        return i != oppSafe
    }

    private func movableAt(_ i: Int) -> Int { n[i] > 0 && col[i] == c ? n[i] : 0 }

    private func countOutside() -> Int {
        var total = 0
        for i in 1...bs where !isHome(i) {
            if n[i] > 0 && col[i] == c { total += n[i] }
            if pin[i] && col[i] == -c { total += 1 }
        }
        return total
    }

    private typealias Undo = (Int, Int, Int, Bool, Int, Int, Int, Bool)

    private mutating func applyHalf(_ src: Int, _ dst: Int) -> Undo {
        let u: Undo = (src, n[src], col[src], pin[src], dst, n[dst], col[dst], pin[dst])
        n[src] -= 1
        if n[src] == 0 {
            if pin[src] { col[src] = -col[src]; n[src] = 1; pin[src] = false } else { col[src] = 0 }
        }
        if isOffBoard(dst) {
            n[dst] += 1; col[dst] = c
        } else if n[dst] == 0 {
            n[dst] = 1; col[dst] = c; pin[dst] = false
        } else if col[dst] == c {
            n[dst] += 1
        } else {
            col[dst] = c; n[dst] = 1; pin[dst] = true
        }
        return u
    }

    private mutating func undoHalf(_ u: Undo) {
        n[u.0] = u.1; col[u.0] = u.2; pin[u.0] = u.3
        n[u.4] = u.5; col[u.4] = u.6; pin[u.4] = u.7
    }

    private func farther(_ src: Int) -> Bool {
        let r = c == 1 ? Array(1..<max(src, 1)) : Array((src + 1)..<(bs + 1))
        for i in r where n[i] > 0 && (col[i] == c || (pin[i] && col[i] == -c)) { return true }
        return false
    }

    // ── halves ──

    private struct H: Equatable { let src: Int; let dst: Int; let over: Bool }

    /// The house generator's exact halves for die `d`, then (overshoot side) the
    /// overshoot bear-offs.
    private func halves(_ d: Int) -> [H] {
        var out: [H] = []
        if c == 1 {
            if bs + 2 - d > 1 { for i in 1..<(bs + 2 - d) { out.append(H(src: i, dst: i + d, over: false)) } }
            if over { for i in max(1, bs + 2 - d)..<(bs + 1) { out.append(H(src: i, dst: bs + 1, over: true)) } }
        } else {
            if d <= bs { for i in d...bs { out.append(H(src: i, dst: i - d, over: false)) } }
            if over && min(d, bs + 1) > 1 { for i in 1..<min(d, bs + 1) { out.append(H(src: i, dst: 0, over: true)) } }
        }
        return out
    }

    private func valid(_ h: H) -> Bool { n[h.src] > 0 && col[h.src] == c && isOpen(h.dst) }

    private func outsideDelta(_ src: Int, _ dst: Int) -> Int {
        if isHome(src) { return 0 }
        if isHome(dst) || isOffBoard(dst) { return -1 }
        return 0
    }

    private func homeOK(_ h: H, _ outside: Int) -> Bool {
        if !isOffBoard(h.dst) { return true }
        if outside != 0 { return false }
        return !(h.over && farther(h.src))
    }

    private mutating func pairOKInOrder(_ first: H, _ second: H, _ outside: Int) -> Bool {
        if !homeOK(first, outside) { return false }
        let after = outside + outsideDelta(first.src, first.dst)
        if !isOffBoard(second.dst) { return true }
        if after != 0 { return false }
        if !second.over { return true }
        let u = applyHalf(first.src, first.dst)
        let ok = !farther(second.src)
        undoHalf(u)
        return ok
    }

    // ── entry ──

    mutating func moves(_ d1: Int, _ d2: Int) -> [[(Int, Int)]] {
        let raw = d1 == d2 ? pasch(d1) : normal(d1, d2)
        var seen = Set<[Int]>()
        var out: [[(Int, Int)]] = []
        for m in raw {
            let key = m.map { $0.0 * 64 + $0.1 }.sorted()
            if seen.insert(key).inserted { out.append(m) }
        }
        return out
    }

    private mutating func normal(_ d1: Int, _ d2: Int) -> [[(Int, Int)]] {
        let outside = countOutside()
        var moves: [[(Int, Int)]] = []
        let h1s = halves(d1), h2s = halves(d2)

        for h1 in h1s where valid(h1) {
            for h2 in h2s where valid(h2) {
                if h1.dst == h2.src || h2.dst == h1.src { continue }
                if !(pairOKInOrder(h1, h2, outside) || pairOKInOrder(h2, h1, outside)) { continue }
                if h1.src == h2.src && (n[h1.src] < 2 || col[h1.src] != c) { continue }
                moves.append([(h1.src, h1.dst), (h2.src, h2.dst)])
            }
        }

        // Merged single-checker jumps landing on the board or exactly on the slot.
        for h in halves(d1 + d2) where !h.over && valid(h) {
            let mid1 = h.src + c * d1, mid2 = h.src + c * d2
            if !(isOpen(mid1) || isOpen(mid2)) { continue }
            if !mergedExactOK(h, outside, mid1, mid2) { continue }
            moves.append([(h.src, h.dst)])
        }

        // Merged jumps whose second leg overshoots.
        if over {
            for src in 1...bs where n[src] > 0 && col[src] == c {
                for (da, db) in [(d1, d2), (d2, d1)] {
                    let mid = src + c * da
                    guard 1 <= mid && mid <= bs else { continue }
                    let final = mid + c * db
                    if (c == 1 && final <= bs + 1) || (c == -1 && final >= 0) { continue }
                    if !isOpen(mid) { continue }
                    if outside + outsideDelta(src, mid) != 0 { continue }
                    let u = applyHalf(src, mid)
                    let ok = !farther(mid)
                    undoHalf(u)
                    if ok { moves.append([(src, off)]); break }
                }
            }
        }

        rule2(&moves, h1s, d2, outside)
        rule2(&moves, h2s, d1, outside)
        return moves
    }

    private mutating func mergedExactOK(_ h: H, _ outside: Int, _ mid1: Int, _ mid2: Int) -> Bool {
        if !isOffBoard(h.dst) || outside == 0 { return true }
        for mid in [mid1, mid2] {
            if pairOKInOrder(H(src: h.src, dst: mid, over: false), H(src: mid, dst: h.dst, over: false), outside) {
                return true
            }
        }
        return false
    }

    private mutating func rule2(_ moves: inout [[(Int, Int)]], _ hs: [H], _ other: Int, _ outside: Int) {
        for hm in hs where valid(hm) {
            if !homeOK(hm, outside) { continue }
            let delta = outsideDelta(hm.src, hm.dst)
            let u = applyHalf(hm.src, hm.dst)
            let newOutside = outside + delta
            var playable = false
            for oh in halves(other) where valid(oh) && homeOK(oh, newOutside) {
                playable = true
                break
            }
            undoHalf(u)
            if !playable { moves.append([(hm.src, hm.dst)]) }
        }
    }

    // ── pasch ──

    private func pasch(_ d: Int) -> [[(Int, Int)]] {
        let delta = c * d
        let (firstStart, lastStart) = c == 1 ? (1, bs + 1) : (bs, 0)   // last exclusive
        var movable = (0...(bs + 1)).map { movableAt($0) }
        let open = (0...(bs + 1)).map { isOpen($0) }
        let ownPinned = (0...(bs + 1)).map { pin[$0] && col[$0] == -c && n[$0] > 0 }
        let outsideCount = countOutside()
        let overSide = over

        func dest(_ p: Int) -> (Int, Bool) {
            let t = p + delta
            if c == 1 { return t <= bs + 1 ? (t, false) : (off, true) }
            return t >= 0 ? (t, false) : (off, true)
        }
        func fartherP(_ p: Int) -> Bool {
            let r = c == 1 ? Array(1..<max(p, 1)) : Array((p + 1)..<(bs + 1))
            for i in r where movable[i] > 0 || ownPinned[i] { return true }
            return false
        }
        func canStep(_ p: Int, _ outside: Int) -> Bool {
            let (t, ov) = dest(p)
            if ov && !overSide { return false }
            if t == off {
                if outside > 0 { return false }
                if ov && fartherP(p) { return false }
            }
            return movable[p] > 0 && open[t]
        }
        func outDelta(_ p: Int) -> Int { outsideDelta(p, dest(p).0) }
        func mv(_ ps: [Int]) -> [(Int, Int)] { ps.map { ($0, dest($0).0) } }

        var possible: [[(Int, Int)]] = []
        var secondOK = false, thirdOK = false, fourthOK = false
        var first = firstStart
        while first != lastStart {
            defer { first += c }
            if !canStep(first, outsideCount) { continue }
            let out1 = outsideCount + outDelta(first)
            let t1 = dest(first).0
            movable[first] -= 1; movable[t1] += 1
            var second = first
            while second != lastStart {
                defer { second += c }
                if !canStep(second, out1) { continue }
                secondOK = true
                let out2 = out1 + outDelta(second)
                let t2 = dest(second).0
                movable[second] -= 1; movable[t2] += 1
                var third = second
                while third != lastStart {
                    defer { third += c }
                    if !canStep(third, out2) { continue }
                    thirdOK = true
                    let out3 = out2 + outDelta(third)
                    let t3 = dest(third).0
                    movable[third] -= 1; movable[t3] += 1
                    var fourth = third
                    while fourth != lastStart {
                        defer { fourth += c }
                        if !canStep(fourth, out3) { continue }
                        fourthOK = true
                        possible.append(mv([first, second, third, fourth]))
                    }
                    if !fourthOK { possible.append(mv([first, second, third])) }
                    movable[third] += 1; movable[t3] -= 1
                }
                if !thirdOK { possible.append(mv([first, second])) }
                movable[second] += 1; movable[t2] -= 1
            }
            if !secondOK { possible.append(mv([first])) }
            movable[first] += 1; movable[t1] -= 1
        }
        return possible
    }

    /// The legal moves as engine `Move`s on `board`.
    mutating func findMoves(dice: Dice) -> [Move] {
        moves(dice.die1.value, dice.die2.value).map { m in
            Move(m.map { HalfMove(from: board.points[$0.0], to: board.points[$0.1], color: color) })
        }
    }
}
