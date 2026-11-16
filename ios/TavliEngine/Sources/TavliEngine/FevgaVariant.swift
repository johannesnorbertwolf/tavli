import Foundation

/// Fevga (#138) — `domain/fevga_board.py` + `domain/fevga_rules.py`, spec
/// `docs/variants/fevga.md`. Running/blocking game: both colours travel the same
/// rotational direction, one checker holds a point, nothing is hit or pinned.
///
/// **Board.** Physical storage, like Plakoto: points 1...24 hold single-coloured
/// stacks; borne-off checkers sit in the trays (White `25`, Black `0`).
/// **Geometry.** White's path is 1→24 (off at 25). Black starts on 13 and wraps:
/// 13…24, 1…12, off at 0 — so `dst = src + color*die` does **not** hold for Black;
/// the `pathIndex`/`point(atPath:)` hooks give the per-colour path (Black: rotation by 12).
/// **Moves** mirror Python exactly: one `Move` per distinct resulting position, halves
/// in play order, a checker using both distinct dice merged into one half.
public struct FevgaVariant: GameVariant {
    public init() {}

    public var id: String { "fevga" }
    public var modelResourceName: String { "FevgaValue" }
    public var maxPoints: Int { 2 }
    public var randomStartingPlayer: Bool { true }

    public func setUpInitialPosition(on board: GameBoard) {
        board.clear()
        board.setPoint(1, pieces: Array(repeating: .white, count: board.numberOfPieces))
        board.setPoint(13, pieces: Array(repeating: .black, count: board.numberOfPieces))
    }

    public func legalMoves(on board: GameBoard, color: Color, dice: Dice) -> [Move] {
        var gen = FevgaMoveGenerator(board: board, color: color)
        return gen.moves(dice.die1.value, dice.die2.value)
    }

    public func applyHalfMove(_ halfMove: HalfMove, on board: GameBoard) {
        board.points[halfMove.from.position].pop()
        board.points[halfMove.to.position].push(halfMove.color)
    }

    public func undoHalfMove(_ halfMove: HalfMove, on board: GameBoard) {
        board.points[halfMove.to.position].pop()
        board.points[halfMove.from.position].push(halfMove.color)
    }

    /// No opponent checker there (a single checker already holds a point).
    public func isOpen(_ point: Int, for color: Color, on board: GameBoard) -> Bool {
        board.points[point].topColor.map { $0 == color } ?? true
    }

    public func movableCount(at point: Int, for color: Color, on board: GameBoard) -> Int {
        guard (1...board.boardSize).contains(point) else { return 0 }
        let p = board.points[point]
        return p.topColor == color ? p.count : 0
    }

    func borneOff(_ c: Color, _ board: GameBoard) -> Int {
        board.points[c.isWhite ? board.boardSize + 1 : 0].count
    }

    public func hasWon(_ color: Color, on board: GameBoard) -> Bool {
        borneOff(color, board) >= board.numberOfPieces
    }

    /// 2 (mars) if the loser has borne off nothing, else 1.
    public func resultPoints(winner: Color, on board: GameBoard) -> Int {
        borneOff(winner.opponent, board) == 0 ? 2 : 1
    }

    public func makeEncoder(config: GameConfig) -> any BoardEncoding { FevgaEncoder(config: config) }

    // ── Geometry: Black's path is rotated by 12 ──────────────────────────────

    public func pathIndex(of point: Int, for color: Color, boardSize: Int) -> Int {
        if point == bearOffPoint(for: color, boardSize: boardSize) { return boardSize + 1 }
        if color.isWhite || !(1...boardSize).contains(point) { return point }
        return FevgaGeometry.path(ofSlot: point)
    }

    public func point(atPath path: Int, for color: Color, boardSize: Int) -> Int {
        if path >= boardSize + 1 { return bearOffPoint(for: color, boardSize: boardSize) }
        return color.isWhite ? path : FevgaGeometry.slot(ofPath: path)
    }

    public func intermediatePoints(of half: HalfMove, die1: Int, die2: Int, on board: GameBoard) -> [Int] {
        var gen = FevgaMoveGenerator(board: board, color: half.color)
        return gen.intermediatePoints(from: half.from.position, to: half.to.position, die1: die1, die2: die2)
    }
}

/// Black's path index ↔ physical slot (rotation by 12 on a 24-point board).
enum FevgaGeometry {
    static let half = 12
    @inline(__always) static func path(ofSlot s: Int) -> Int { s > half ? s - half : s + half }
    @inline(__always) static func slot(ofPath p: Int) -> Int { p <= half ? p + half : p - half }
}

/// Port of `fevga_legal_moves` (`domain/fevga_rules.py`) in the mover's path
/// coordinates p = 1...24 (25 = off). Depth-first over every play sequence (and
/// prefix), deduplicated by resulting position, filtered by the R1/R2 end-of-move
/// rules, then the dice obligation (most dice; larger die on a one-die play).
struct FevgaMoveGenerator {
    private static let unlockPath = 14
    private static let homeFirst = 19
    private static let mask24 = (1 << 24) - 1
    private static let low12 = (1 << 12) - 1
    private static let startTable = 0x3F
    /// Additive position hash (any fixed random table gives Python's dedup).
    private static let zobrist: [UInt64] = {
        var rng = SplitMix64(seed: 0xFE76A)
        return (0..<26).map { _ in rng.next() }
    }()

    private struct Visit: Hashable { let key: UInt64; let rem: Int }
    private struct Found { let halves: [(Int, Int)]; let firstDie: Int }

    private let board: GameBoard
    private let color: Color
    private let ppp: Int
    private var cnt = [Int](repeating: 0, count: 26)
    private var blocked = [Bool](repeating: false, count: 26)
    private var held = 0
    private var outside = 0
    private var unlocked = 0
    private var beyond = 0
    private var found: [[Found]] = []
    private var foundKeys: [Set<UInt64>] = []
    private var visited = Set<Visit>()
    private var halves: [(Int, Int)] = []

    init(board: GameBoard, color: Color) {
        self.board = board
        self.color = color
        ppp = board.numberOfPieces
        var oppFront = 0
        for p in 1...24 {
            let pt = board.points[slot(p)]
            guard let top = pt.topColor else { continue }
            if top == color {
                cnt[p] = pt.count
                held |= 1 << (p - 1)
            } else {
                blocked[p] = true
                let op = p <= 12 ? p + 12 : p - 12
                if op > oppFront { oppFront = op }
            }
        }
        if board.points[color.isWhite ? 0 : 25].count > 0 { oppFront = 25 }
        beyond = oppFront <= 18 ? (Self.mask24 & ~((1 << oppFront) - 1)) : 0
        for p in 1..<Self.homeFirst { outside += cnt[p] }
        unlocked = board.points[color.isWhite ? 25 : 0].count
        for p in Self.unlockPath...24 { unlocked += cnt[p] }
    }

    @inline(__always) private func slot(_ p: Int) -> Int {
        color.isWhite ? p : FevgaGeometry.slot(ofPath: p)
    }

    @inline(__always) private func physical(_ p: Int) -> Int {
        p == 25 ? (color.isWhite ? 25 : 0) : slot(p)
    }

    private func clean(_ h: Int) -> Bool {
        if h & Self.startTable == Self.startTable { return false }
        if beyond != 0 {
            let rot = ((h & Self.low12) << 12) | (h >> 12)
            let x = rot & beyond
            if (x & (x >> 1) & (x >> 2) & (x >> 3) & (x >> 4) & (x >> 5)) != 0 { return false }
        }
        return true
    }

    /// Sources for the next half-move under the first-checker rule, ascending.
    private func sources() -> [Int] {
        if unlocked == 0 {
            if cnt[1] == ppp { return [1] }
            return (2...24).filter { cnt[$0] > 0 }
        }
        return (1...24).filter { cnt[$0] > 0 }
    }

    private func stepTargets(_ d: Int) -> [(Int, Int)] {
        let srcs = sources()
        var out: [(Int, Int)] = []
        for p in srcs {
            var t = p + d
            if t <= 24 {
                if blocked[t] { continue }
            } else {
                if outside > 0 { continue }
                if t > 25 && p != srcs[0] { continue }
                t = 25
            }
            out.append((p, t))
        }
        return out
    }

    private mutating func step(_ p: Int, _ t: Int) {
        cnt[p] -= 1
        if cnt[p] == 0 { held &= ~(1 << (p - 1)) }
        if t <= 24 {
            if cnt[t] == 0 { held |= 1 << (t - 1) }
            cnt[t] += 1
        }
        if p < Self.homeFirst && Self.homeFirst <= t { outside -= 1 }
        if p < Self.unlockPath && Self.unlockPath <= t { unlocked += 1 }
    }

    private mutating func unstep(_ p: Int, _ t: Int) {
        if t <= 24 {
            cnt[t] -= 1
            if cnt[t] == 0 { held &= ~(1 << (t - 1)) }
        }
        if cnt[p] == 0 { held |= 1 << (p - 1) }
        cnt[p] += 1
        if p < Self.homeFirst && Self.homeFirst <= t { outside += 1 }
        if p < Self.unlockPath && Self.unlockPath <= t { unlocked -= 1 }
    }

    private mutating func rec(_ depth: Int, _ key: UInt64, _ firstDie: Int, _ rem: [Int]) {
        if clean(held), foundKeys[depth].insert(key).inserted {
            found[depth].append(Found(halves: halves, firstDie: firstDie))
        }
        if rem.isEmpty { return }
        var tried: [Int] = []
        for (i, d) in rem.enumerated() {
            if tried.contains(d) { continue }
            tried.append(d)
            var nrem = rem
            nrem.remove(at: i)
            let remCode = nrem.reduce(0) { $0 * 8 + $1 }
            for (p, t) in stepTargets(d) {
                let nkey = key &- Self.zobrist[p] &+ Self.zobrist[t]
                if !visited.insert(Visit(key: nkey, rem: remCode)).inserted { continue }
                step(p, t)
                halves.append((p, t))
                rec(depth + 1, nkey, firstDie == 0 ? d : firstDie, nrem)
                halves.removeLast()
                unstep(p, t)
            }
        }
    }

    mutating func moves(_ die1: Int, _ die2: Int) -> [Move] {
        var d1 = die1, d2 = die2
        let doubles = d1 == d2
        let maxDepth = doubles ? 4 : 2
        if !doubles && d1 < d2 { swap(&d1, &d2) }   // d1 = larger die, explored first
        found = Array(repeating: [], count: maxDepth + 1)
        foundKeys = Array(repeating: [], count: maxDepth + 1)
        visited.removeAll()
        rec(0, 0, 0, doubles ? [d1, d1, d1, d1] : [d1, d2])

        var m = maxDepth
        while m > 0 && found[m].isEmpty { m -= 1 }
        if m == 0 { return [] }
        var cands = found[m]
        if m == 1 && !doubles {
            let larger = cands.filter { $0.firstDie == d1 }
            if !larger.isEmpty { cands = larger }
        }
        return cands.map { c in
            var hs = c.halves
            if !doubles && m == 2 && hs[1].0 == hs[0].1 { hs = [(hs[0].0, hs[1].1)] }
            return Move(hs.map {
                HalfMove(from: board.points[physical($0.0)], to: board.points[physical($0.1)], color: color)
            })
        }
    }

    /// Midpoints (board indices, `die1`/`die2` order) through which the merged half
    /// `from → to` is a legal two-hop play (first-checker and bear-off rules).
    mutating func intermediatePoints(from: Int, to: Int, die1: Int, die2: Int) -> [Int] {
        let pf = color.isWhite ? from : FevgaGeometry.path(ofSlot: from)
        let pt = to == (color.isWhite ? 25 : 0) ? 25 : (color.isWhite ? to : FevgaGeometry.path(ofSlot: to))
        var mids: [Int] = []
        for (a, b) in [(die1, die2), (die2, die1)] {
            guard pf + a <= 24, stepTargets(a).contains(where: { $0 == (pf, pf + a) }) else { continue }
            step(pf, pf + a)
            let ok = stepTargets(b).contains { $0 == (pf + a, pt) }
            unstep(pf, pf + a)
            if ok, !mids.contains(slot(pf + a)) { mids.append(slot(pf + a)) }
        }
        return mids
    }
}

/// `fevga_v1` (`ai/fevga_encoder.py`): 24 points in the mover's path order × (owner
/// bit + 15 unary), borne-off own/opp, 20 smart features — 406 floats. A position and
/// its colour-swapped twin (rotation by 12) encode identically for their movers.
public struct FevgaEncoder: BoardEncoding {
    private let ppp: Int
    private let pointSize: Int
    private let rawSize: Int

    public init(config: GameConfig = GameConfig(variant: GameVariants.fevga)) {
        ppp = config.piecesPerPlayer
        pointSize = 1 + ppp
        rawSize = 24 * pointSize
    }

    public var inputSize: Int { rawSize + 2 + 20 }

    @inline(__always) private static func rot(_ a: [Int]) -> [Int] {
        var r = [Int](repeating: 0, count: 25)
        for q in 1...12 { r[q] = a[q + 12]; r[q + 12] = a[q] }
        return r
    }

    private static func longestRun(_ held: [Int], from lo: Int = 1) -> Int {
        var best = 0, cur = 0
        var q = lo
        while q <= 24 {
            if held[q] != 0 { cur += 1; if cur > best { best = cur } } else { cur = 0 }
            q += 1
        }
        return best
    }

    private static func rear(_ a: [Int]) -> Int {
        for p in 1...24 where a[p] != 0 { return p }
        return 25
    }

    private struct Side {
        var pip = 0, onStart = 0, held = 0, run = 0, runFront = 0, blk6 = 0, blk12 = 0, home = 0
        var unlocked = false, contact = false
    }

    private static func side(_ own: [Int], _ opp: [Int], _ borneOwn: Int) -> Side {
        var s = Side()
        let ownInOpp = rot(own)
        let oppRear = rear(rot(opp))
        let r = rear(own)
        for p in 1...24 where own[p] != 0 {
            s.pip += own[p] * (25 - p)
            s.held += 1
            if p >= 19 { s.home += own[p] }
        }
        s.onStart = own[1]
        s.unlocked = borneOwn != 0 || (14...24).contains { own[$0] != 0 }
        s.run = min(longestRun(ownInOpp), 6)
        s.runFront = oppRear < 24 ? min(longestRun(ownInOpp, from: oppRear + 1), 6) : 0
        if r + 1 <= 24 {
            for p in (r + 1)...min(r + 6, 24) where opp[p] != 0 { s.blk6 += 1 }
            for p in (r + 1)...min(r + 12, 24) where opp[p] != 0 { s.blk12 += 1 }
            s.contact = ((r + 1)...24).contains { opp[$0] != 0 }
        }
        return s
    }

    public func encode(_ board: GameBoard, isWhitesTurn: Bool) -> [Float] {
        let us: Color = isWhitesTurn ? .white : .black
        var out = [Float](repeating: 0, count: inputSize)
        var mine = [Int](repeating: 0, count: 25)
        var theirs = [Int](repeating: 0, count: 25)
        for p in 1...24 {
            let pt = board.points[isWhitesTurn ? p : FevgaGeometry.slot(ofPath: p)]
            let k = pt.count
            guard k > 0 else { continue }
            let base = (p - 1) * pointSize
            if pt.topColor == us { mine[p] = k } else { theirs[p] = k; out[base] = 1 }
            for j in 0..<k { out[base + 1 + j] = 1 }
        }
        let boUs = board.points[us.isWhite ? 25 : 0].count
        let boThem = board.points[us.isWhite ? 0 : 25].count
        let dp = Double(ppp)
        out[rawSize] = Float(Double(boUs) / dp)
        out[rawSize + 1] = Float(Double(boThem) / dp)

        let a = Self.side(mine, theirs, boUs)
        let b = Self.side(Self.rot(theirs), Self.rot(mine), boThem)
        let pipScale = Double(ppp * 24)
        let f = rawSize + 2
        let vals: [Double] = [
            Double(a.pip) / pipScale, Double(b.pip) / pipScale,
            0.5 + Double(a.pip - b.pip) / (2.0 * pipScale),
            Double(a.onStart) / dp, Double(b.onStart) / dp,
            a.unlocked ? 1 : 0, b.unlocked ? 1 : 0,
            Double(a.held) / dp, Double(b.held) / dp,
            Double(a.run) / 6, Double(b.run) / 6,
            Double(a.runFront) / 6, Double(b.runFront) / 6,
            Double(a.blk6) / 6, Double(a.blk12) / 12,
            Double(b.blk6) / 6, Double(b.blk12) / 12,
            Double(a.home) / dp, Double(b.home) / dp,
            (a.contact || b.contact) ? 0 : 1,
        ]
        for (i, v) in vals.enumerated() { out[f + i] = Float(v) }
        return out
    }
}
