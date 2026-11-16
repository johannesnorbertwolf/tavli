import Foundation

/// Portes (#137) — `domain/portes_board.py` + `domain/portes_move_generation.py`,
/// spec `docs/variants/portes.md`: backgammon without cube or triple win.
///
/// **Board state (bar + borne-off) in the shared `GameBoard`.** Python keeps a signed
/// slot array where slot 0 is White's bar and slot 25 Black's bar, and only *counts*
/// borne-off checkers. The Swift port keeps the same indices, so every half-move pair
/// is identical to Python's (`[0, d]` = White enters with `d`, `[s, 25]` = White bears
/// off). The two end stacks hold both kinds of off-board checker, told apart by colour
/// (a colour's bar and its off tray are at opposite ends, so they never share a stack):
///
///     points[0]  = [Black borne-off …, White bar …]   (bottom → top)
///     points[25] = [White borne-off …, Black bar …]
///
/// So `captureStacks`/`restoreStacks`, replay, review/drill boards and saves (which
/// only store move pairs) carry the full position with no extra fields. A hit is
/// remembered for undo on the board's LIFO `undoLog` (captured by `captureSnapshot`).
/// **Moves** mirror Python exactly: one per distinct resulting position, never merged
/// (a checker using both dice is two halves, as an intermediate hit matters).
public struct PortesVariant: GameVariant {
    public init() {}

    public var id: String { "portes" }
    public var modelResourceName: String { "PortesValue" }
    public var maxPoints: Int { 2 }
    public var randomStartingPlayer: Bool { true }

    /// White's bar / Black's off tray, and Black's bar / White's off tray.
    static func barIndex(_ c: Color) -> Int { c.isWhite ? 0 : 25 }
    static func offIndex(_ c: Color) -> Int { c.isWhite ? 25 : 0 }

    public static func barCount(_ c: Color, on board: GameBoard) -> Int {
        board.points[barIndex(c)].countForColor(c)
    }

    public static func borneOffCount(_ c: Color, on board: GameBoard) -> Int {
        board.points[offIndex(c)].countForColor(c)
    }

    /// Lay out a position from per-colour counts (tests / fixtures). `white`/`black`
    /// map board point → count; bar counts go in `whiteBar`/`blackBar`.
    public static func setPosition(on board: GameBoard, white: [Int: Int], black: [Int: Int],
                                   whiteBar: Int = 0, blackBar: Int = 0,
                                   whiteOff: Int = 0, blackOff: Int = 0) {
        board.clear()
        for (i, k) in white where k > 0 { board.setPoint(i, pieces: Array(repeating: .white, count: k)) }
        for (i, k) in black where k > 0 { board.setPoint(i, pieces: Array(repeating: .black, count: k)) }
        board.setPoint(0, pieces: Array(repeating: .black, count: blackOff) + Array(repeating: .white, count: whiteBar))
        board.setPoint(25, pieces: Array(repeating: .white, count: whiteOff) + Array(repeating: .black, count: blackBar))
    }

    public func setUpInitialPosition(on board: GameBoard) {
        Self.setPosition(on: board, white: [1: 2, 12: 5, 17: 3, 19: 5], black: [24: 2, 13: 5, 8: 3, 6: 5])
    }

    public func legalMoves(on board: GameBoard, color: Color, dice: Dice) -> [Move] {
        var gen = PortesMoveGenerator(board: board, color: color)
        return gen.moves(dice.die1.value, dice.die2.value)
    }

    public func applyHalfMove(_ halfMove: HalfMove, on board: GameBoard) {
        let c = halfMove.color
        let src = halfMove.from.position, dst = halfMove.to.position
        board.points[src].pop()                     // a bar checker is on top of its tray
        if dst == Self.offIndex(c) {
            board.points[dst].pieces.insert(c, at: 0)   // borne-off checkers sit below the bar
            board.undoLog.append(false)
            return
        }
        let target = board.points[dst]
        if let top = target.topColor, top != c {
            target.pop()                                    // hit a blot →
            board.points[Self.barIndex(top)].push(top)      // its owner's bar
            board.undoLog.append(true)
        } else {
            board.undoLog.append(false)
        }
        target.push(c)
    }

    public func undoHalfMove(_ halfMove: HalfMove, on board: GameBoard) {
        let c = halfMove.color
        let src = halfMove.from.position, dst = halfMove.to.position
        let hit = board.undoLog.popLast() ?? false
        if dst == Self.offIndex(c) {
            board.points[dst].pieces.removeFirst()
        } else {
            board.points[dst].pop()
            if hit {
                let opp = c.opponent
                board.points[Self.barIndex(opp)].pop()
                board.points[dst].push(opp)
            }
        }
        board.points[src].push(c)
    }

    /// Points 1...24: empty, own, or a single opponent blot (a hit). Own off tray: yes.
    public func isOpen(_ point: Int, for color: Color, on board: GameBoard) -> Bool {
        if point == Self.offIndex(color) { return true }
        guard (1...board.boardSize).contains(point) else { return false }
        let p = board.points[point]
        return p.topColor == nil || p.topColor == color || p.count == 1
    }

    public func movableCount(at point: Int, for color: Color, on board: GameBoard) -> Int {
        if point == Self.barIndex(color) { return Self.barCount(color, on: board) }
        guard (1...board.boardSize).contains(point) else { return 0 }
        let p = board.points[point]
        return p.topColor == color ? p.count : 0
    }

    public func hasWon(_ color: Color, on board: GameBoard) -> Bool {
        Self.borneOffCount(color, on: board) >= board.numberOfPieces
    }

    /// 2 ("diplo") if the loser has borne off none, else 1. No triple.
    public func resultPoints(winner: Color, on board: GameBoard) -> Int {
        Self.borneOffCount(winner.opponent, on: board) == 0 ? 2 : 1
    }

    public func makeEncoder(config: GameConfig) -> any BoardEncoding { PortesEncoder() }

    /// Portes never merges a two-dice move into one half.
    public func intermediatePoints(of half: HalfMove, die1: Int, die2: Int, on board: GameBoard) -> [Int] { [] }

    /// The Python signed slot array (`p[i] > 0` White, `< 0` Black; `p[0]` White's bar,
    /// `p[25]` = −Black's bar) and `(whiteOff, blackOff)`.
    public static func signedSlots(_ board: GameBoard) -> (p: [Int], whiteOff: Int, blackOff: Int) {
        var p = [Int](repeating: 0, count: 26)
        for i in 1...24 {
            let pt = board.points[i]
            if let top = pt.topColor { p[i] = top.isWhite ? pt.count : -pt.count }
        }
        p[0] = barCount(.white, on: board)
        p[25] = -barCount(.black, on: board)
        return (p, borneOffCount(.white, on: board), borneOffCount(.black, on: board))
    }
}

/// Port of `domain/portes_move_generation.legal_moves`: a mover-relative array `q`
/// (own > 0, opponent < 0; r = pips to bear off, 25 = own bar), DFS over the die
/// order(s), leaves recorded by resulting position.
struct PortesMoveGenerator {
    private struct Entry { let die: Int; let halves: [(Int, Int)] }

    private let board: GameBoard
    private let color: Color
    private var q = [Int](repeating: 0, count: 26)
    private var found: [Entry] = []
    private var foundKeys = Set<[Int8]>()
    private var best = 0
    private var halves: [(Int, Int)] = []

    init(board: GameBoard, color: Color) {
        self.board = board
        self.color = color
        let p = PortesVariant.signedSlots(board).p
        if color.isWhite {
            for r in 0...25 { q[r] = p[25 - r] }
        } else {
            for r in 0...25 { q[r] = -p[r] }
        }
        q[0] = 0
    }

    private mutating func record(_ dieIfSingle: Int) {
        let n = halves.count
        if n < best { return }
        if n > best { best = n; found.removeAll(); foundKeys.removeAll() }
        var key = q.map { Int8($0) }
        key.append(Int8(n == 1 ? dieIfSingle : 0))
        if foundKeys.insert(key).inserted { found.append(Entry(die: dieIfSingle, halves: halves)) }
    }

    private func steps(_ d: Int, _ outside: Int, _ maxSrc: Int) -> [(Int, Int)] {
        var res: [(Int, Int)] = []
        var src = min(maxSrc, 24)
        while src >= 1 {
            defer { src -= 1 }
            if q[src] <= 0 { continue }
            let dst = src - d
            if dst >= 1 {
                if q[dst] >= -1 { res.append((src, dst)) }
            } else if outside == 0 {
                if dst == 0 {
                    res.append((src, 0))
                } else {
                    var ok = true
                    var k = src + 1
                    while k <= 6 { if q[k] > 0 { ok = false; break }; k += 1 }
                    if ok { res.append((src, dst)) }
                }
            }
        }
        return res
    }

    private mutating func rec(_ seq: [Int], _ idx: Int, _ outside: Int, _ maxSrc: Int, _ doubles: Bool) {
        let d = seq[idx]
        var moved = false
        let srcs: [(Int, Int)]
        if q[25] > 0 {
            let dst = 25 - d
            srcs = q[dst] >= -1 ? [(25, dst)] : []
        } else {
            srcs = steps(d, outside, maxSrc)
        }
        for (src, dst) in srcs {
            q[src] -= 1
            var hit = false
            if dst >= 1 {
                if q[dst] == -1 { q[dst] = 1; hit = true } else { q[dst] += 1 }
            }
            let newOutside = (src > 6 && dst <= 6) ? outside - 1 : outside
            halves.append((src, dst))
            if idx + 1 < seq.count {
                rec(seq, idx + 1, newOutside, doubles ? src : 25, doubles)
            } else {
                record(d)
            }
            halves.removeLast()
            if dst >= 1 {
                if hit { q[dst] = -1 } else { q[dst] -= 1 }
            }
            q[src] += 1
            moved = true
        }
        if !moved && idx > 0 { record(idx == 1 ? seq[0] : 0) }
    }

    mutating func moves(_ d1: Int, _ d2: Int) -> [Move] {
        var outside = 0
        for r in 7...25 where q[r] > 0 { outside += q[r] }
        if d1 == d2 {
            rec([d1, d1, d1, d1], 0, outside, 25, true)
        } else {
            rec([d1, d2], 0, outside, 25, false)
            rec([d2, d1], 0, outside, 25, false)
        }
        if found.isEmpty { return [] }
        var entries = found
        if best == 1 && d1 != d2 {
            let big = max(d1, d2)
            let larger = entries.filter { $0.die == big }
            if !larger.isEmpty { entries = larger }
        }
        let white = color.isWhite
        return entries.map { e in
            Move(e.halves.map { s, t in
                let tt = t > 0 ? t : 0
                return HalfMove(from: board.points[white ? 25 - s : s],
                                to: board.points[white ? 25 - tt : tt], color: color)
            })
        }
    }
}

/// `portes_v1` (`ai/portes_encoder.py`): 24 own-relative points × (owner bit + 15
/// unary), bars, borne-off, 18 smart features — 414 floats, mover's perspective.
public struct PortesEncoder: BoardEncoding {
    public init() {}

    public var inputSize: Int { 414 }

    private struct Side { var pip = 0, blots = 0, made = 0, prime = 0, homeMade = 0, back = 0, exposed = 0, top = 0 }

    private static func side(_ a: [Int], _ b: [Int]) -> Side {
        var s = Side()
        var run = 0
        for r in 1...24 {
            let k = a[r]
            if k > 0 {
                s.pip += k * r
                s.top = r
                if r >= 19 { s.back += k }
                if k >= 2 {
                    s.made += 1
                    if r <= 6 { s.homeMade += 1 }
                    run += 1
                    if run > s.prime { s.prime = run }
                    continue
                }
                s.blots += 1
                let lo = 26 - r
                let hi = min(lo + 5, 25)
                if lo <= hi {
                    for t in lo...hi where b[t] != 0 { s.exposed += 1; break }
                }
            }
            run = 0
        }
        if a[25] > 0 { s.pip += 25 * a[25]; s.top = 25 }
        return s
    }

    public func encode(_ board: GameBoard, isWhitesTurn: Bool) -> [Float] {
        let (p, whiteOff, blackOff) = PortesVariant.signedSlots(board)
        var white = [Int](repeating: 0, count: 26)
        var black = [Int](repeating: 0, count: 26)
        for r in 1...24 {
            if p[25 - r] > 0 { white[r] = p[25 - r] }
            if p[r] < 0 { black[r] = -p[r] }
        }
        white[25] = p[0]
        black[25] = -p[25]
        let (own, opp) = isWhitesTurn ? (white, black) : (black, white)

        var out = [Float](repeating: 0, count: 414)
        for r in 1...24 {
            let base = (r - 1) * 16
            var k = own[r]
            if k > 0 {
                out[base] = 1
            } else {
                k = opp[25 - r]
            }
            for j in 0..<k { out[base + 1 + j] = 1 }
        }
        for (j, k) in [(0, own[25]), (5, opp[25])] where k > 0 {
            let base = 384 + j
            for i in 0..<min(k, 4) { out[base + i] = 1 }
            if k > 4 { out[base + 4] = Float(Double(k - 4) / 11.0) }
        }
        let ownOff = isWhitesTurn ? whiteOff : blackOff
        let oppOff = isWhitesTurn ? blackOff : whiteOff
        out[394] = Float(Double(ownOff) / 15.0)
        out[395] = Float(Double(oppOff) / 15.0)

        let a = Self.side(own, opp)
        let b = Self.side(opp, own)
        let vals: [Double] = [
            Double(a.pip) / 375, Double(b.pip) / 375, 0.5 + Double(b.pip - a.pip) / 750,
            Double(a.blots) / 15, Double(b.blots) / 15,
            Double(a.made) / 7, Double(b.made) / 7,
            Double(a.prime) / 7, Double(b.prime) / 7,
            Double(a.homeMade) / 6, Double(b.homeMade) / 6,
            Double(a.back) / 15, Double(b.back) / 15,
            Double(own[25]) / 15, Double(opp[25]) / 15,
            a.top + b.top < 25 ? 1 : 0,
            Double(a.exposed) / 15, Double(b.exposed) / 15,
        ]
        for (i, v) in vals.enumerated() { out[396 + i] = Float(v) }
        return out
    }
}
