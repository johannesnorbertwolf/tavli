import Foundation

/// Standard (bkgm) Plakoto (#139) — `domain/plakoto_standard_*.py`, spec
/// `docs/variants/plakoto-standard.md`. Same board, landing, pinning and stack
/// mechanics as `PlakotoVariant` (a pin is stack order, borne-off checkers sit in the
/// trays `0`/`boardSize+1`); differs in move legality (only maximal plays, larger die
/// when only one can be played, larger-die bear-off from the highest point) and in
/// the end of the game (mother-checker rule, draw when both mothers are pinned, 1 or
/// 2 points).
///
/// Moves use the repo notation exactly as Python emits them: a checker using both
/// distinct dice is one merged half `(src, final)`; two checkers give two halves; on
/// doubles one half per die in movement order. Order of the returned list = Python's.
public struct StandardPlakotoVariant: GameVariant {
    public init() {}

    public var id: String { "plakoto_standard" }
    public var modelResourceName: String { "PlakotoStandardValue" }
    public var maxPoints: Int { 2 }
    public var randomStartingPlayer: Bool { true }
    /// The mother rule can end the game (or draw it) after either side's move.
    public var endsOnlyByMoverWin: Bool { false }

    public func setUpInitialPosition(on board: GameBoard) {
        board.clear()
        board.initializeBoard()
    }

    public func legalMoves(on board: GameBoard, color: Color, dice: Dice) -> [Move] {
        var gen = StandardPlakotoMoveGenerator(board: board, color: color)
        return gen.moves(dice.die1.value, dice.die2.value)
    }

    // Plakoto stack ops, addressed by position (never through the half-move's Point
    // references, so a move generated on one board can be replayed on another).
    public func applyHalfMove(_ halfMove: HalfMove, on board: GameBoard) {
        board.points[halfMove.from.position].pop()
        board.points[halfMove.to.position].push(halfMove.color)
    }

    public func undoHalfMove(_ halfMove: HalfMove, on board: GameBoard) {
        board.points[halfMove.to.position].pop()
        board.points[halfMove.from.position].push(halfMove.color)
    }

    public func isOpen(_ point: Int, for color: Color, on board: GameBoard) -> Bool {
        board.points[point].isOpen(for: color)
    }

    // ── End of game (rules 10-11) ────────────────────────────────────────────

    private func startSlot(_ c: Color, _ board: GameBoard) -> Int { c.isWhite ? 1 : board.boardSize }

    private func borneOff(_ c: Color, _ board: GameBoard) -> Int {
        board.points[c.isWhite ? board.boardSize + 1 : 0].count
    }

    /// `c`'s checkers on its own start (its owned stack, or 1 if pinned there).
    func checkersOnStart(_ c: Color, _ board: GameBoard) -> Int {
        let p = board.points[startSlot(c, board)]
        guard let top = p.topColor else { return 0 }
        if top == c { return p.activeCount }
        return p.isCaptured ? 1 : 0
    }

    /// `c`'s start is owned by the opponent with a `c` checker pinned under it.
    func motherPinned(_ c: Color, _ board: GameBoard) -> Bool {
        board.points[startSlot(c, board)].isCaptured(by: c.opponent)
    }

    func isDraw(_ board: GameBoard) -> Bool { motherPinned(.white, board) && motherPinned(.black, board) }

    func motherWin(_ c: Color, _ board: GameBoard) -> Bool {
        motherPinned(c.opponent, board) && !motherPinned(c, board) && checkersOnStart(c, board) == 0
    }

    private func allBorneOff(_ c: Color, _ board: GameBoard) -> Bool {
        borneOff(c, board) >= board.numberOfPieces
    }

    public func hasWon(_ color: Color, on board: GameBoard) -> Bool {
        allBorneOff(color, board) || motherWin(color, board)
    }

    public func isOver(on board: GameBoard) -> Bool {
        isDraw(board) || hasWon(.white, on: board) || hasWon(.black, on: board)
    }

    public func outcome(on board: GameBoard) -> (winner: Color?, points: Int) {
        if isDraw(board) { return (nil, 0) }
        for c in [Color.white, .black] {
            if motherWin(c, board) { return (c, 2) }
            if allBorneOff(c, board) { return (c, borneOff(c.opponent, board) == 0 ? 2 : 1) }
        }
        return (nil, 0)
    }

    public func resultPoints(winner: Color, on board: GameBoard) -> Int {
        let (w, pts) = outcome(on: board)
        return w == winner ? pts : 0
    }

    public func makeEncoder(config: GameConfig) -> any BoardEncoding { PlakotoStdEncoder(config: config) }

    // ── Merged-half split (exact rules, incl. the larger-die bear-off) ───────

    public func intermediatePoints(of half: HalfMove, die1: Int, die2: Int, on board: GameBoard) -> [Int] {
        var gen = StandardPlakotoMoveGenerator(board: board, color: half.color)
        return gen.intermediatePoints(from: half.from.position, to: half.to.position, die1: die1, die2: die2)
    }
}

/// Port of `domain/plakoto_standard_moves.legal_moves`, in the mover's perspective
/// coordinates p (1...N points, N+1 off). Precomputes `mov`/`opn`/`pinOurs` once;
/// the open set never changes during the mover's turn.
struct StandardPlakotoMoveGenerator {
    private let board: GameBoard
    private let color: Color
    private let n: Int
    private let off: Int
    private let homeLo: Int
    private var mov: [Int]
    private var opn: [Bool]
    private var pinOurs: [Bool]
    private var outside = 0

    init(board: GameBoard, color: Color) {
        self.board = board
        self.color = color
        n = board.boardSize
        off = n + 1
        homeLo = n - board.homeSize + 1
        mov = [Int](repeating: 0, count: off + 1)
        opn = [Bool](repeating: false, count: off + 1)
        pinOurs = [Bool](repeating: false, count: off + 1)
        let white = color.isWhite
        for p in 1..<off {
            let pt = board.points[white ? p : off - p]
            guard let owner = pt.topColor else { opn[p] = true; continue }
            let k = pt.activeCount
            if owner == color {
                mov[p] = k
                opn[p] = true
                if p < homeLo { outside += k }
            } else if pt.isCaptured {
                pinOurs[p] = true
                if p < homeLo { outside += 1 }
            } else if k == 1 {
                opn[p] = true
            }
        }
    }

    @inline(__always) private func idx(_ p: Int) -> Int { color.isWhite ? p : off - p }

    private func canStep(_ p: Int, _ d: Int, _ outside: Int) -> Bool {
        let t = p + d
        if t <= n { return opn[t] }
        if outside > 0 { return false }
        if t == off { return true }
        // Larger die: only from the highest occupied point (all own checkers are home).
        var q = homeLo
        while q < p {
            if mov[q] > 0 || pinOurs[q] { return false }
            q += 1
        }
        return true
    }

    private func half(_ s: Int, _ e: Int) -> HalfMove {
        HalfMove(from: board.points[idx(s)], to: board.points[idx(e)], color: color)
    }

    mutating func moves(_ d1: Int, _ d2: Int) -> [Move] {
        if d1 == d2 { return doubles(d1) }

        var twoKeys = Set<Int>()
        var two: [Move] = []
        var singles1: [Int] = []   // sources playable with d1
        var singles2: [Int] = []
        for (a, b) in [(d1, d2), (d2, d1)] {
            for p in 1..<off {
                guard mov[p] > 0, canStep(p, a, outside) else { continue }
                if a == d1 { singles1.append(p) } else { singles2.append(p) }
                let t = min(p + a, off)
                mov[p] -= 1
                if t <= n { mov[t] += 1 }
                let out2 = (p < homeLo && homeLo <= t) ? outside - 1 : outside
                for q in 1..<off {
                    guard mov[q] > 0, canStep(q, b, out2) else { continue }
                    let u = min(q + b, off)
                    if q == t || u == p {
                        let (s, e) = q == t ? (p, u) : (q, t)
                        let key = s * 64 + e
                        if twoKeys.insert(key).inserted { two.append(Move([half(s, e)])) }
                    } else {
                        let first = (p, t) <= (q, u)
                        let (a1, a2, b1, b2) = first ? (p, t, q, u) : (q, u, p, t)
                        let key = 1 << 30 | ((a1 * 64 + a2) * 64 + b1) * 64 + b2
                        if twoKeys.insert(key).inserted { two.append(Move([half(p, t), half(q, u)])) }
                    }
                }
                mov[p] += 1
                if t <= n { mov[t] -= 1 }
            }
        }
        if !two.isEmpty { return two }
        let (big, small) = d1 > d2 ? (d1, d2) : (d2, d1)
        let bigSingles = big == d1 ? singles1 : singles2
        let die = bigSingles.isEmpty ? small : big
        let sources = die == d1 ? singles1 : singles2
        return sources.map { Move([half($0, min($0 + die, off))]) }
    }

    private mutating func doubles(_ d: Int) -> [Move] {
        var best = 0
        var found: [[(Int, Int)]] = []
        var seq: [(Int, Int)] = []
        seq.reserveCapacity(4)

        func rec(_ start: Int, _ outside: Int) {
            var extended = false
            var p = start
            while p < off {
                defer { p += 1 }
                guard mov[p] > 0, canStep(p, d, outside) else { continue }
                extended = true
                let t = min(p + d, off)
                mov[p] -= 1
                if t <= n { mov[t] += 1 }
                seq.append((p, t))
                if seq.count == 4 {
                    if best < 4 { best = 4; found.removeAll() }
                    found.append(seq)
                } else {
                    rec(p, (p < homeLo && homeLo <= t) ? outside - 1 : outside)
                }
                seq.removeLast()
                mov[p] += 1
                if t <= n { mov[t] -= 1 }
            }
            if !extended && !seq.isEmpty {
                if seq.count > best { best = seq.count; found.removeAll() }
                if seq.count == best { found.append(seq) }
            }
        }
        rec(1, outside)
        return found.map { s in Move(s.map { half($0.0, $0.1) }) }
    }

    /// Midpoints (board indices, `die1`/`die2` order) through which the merged half
    /// `from → to` is a legal two-hop play under this position's rules.
    mutating func intermediatePoints(from: Int, to: Int, die1: Int, die2: Int) -> [Int] {
        let pf = color.isWhite ? from : off - from
        let pt = color.isWhite ? to : off - to
        var mids: [Int] = []
        for (a, b) in [(die1, die2), (die2, die1)] {
            let m = pf + a
            guard m <= n, mov[pf] > 0, canStep(pf, a, outside) else { continue }
            mov[pf] -= 1; mov[m] += 1
            let out2 = (pf < homeLo && homeLo <= m) ? outside - 1 : outside
            let ok = canStep(m, b, out2) && min(m + b, off) == pt
            mov[pf] += 1; mov[m] -= 1
            if ok, !mids.contains(idx(m)) { mids.append(idx(m)) }
        }
        return mids
    }
}

/// `plakoto_std_v1` (`ai/plakoto_std_encoder.py`): the full `unary_v3` vector
/// followed by 8 mother / borne-off features from the mover's perspective (494 floats).
public struct PlakotoStdEncoder: BoardEncoding {
    private let base: BoardEncoder
    private let boardSize: Int
    private let piecesPerPlayer: Int

    public init(config: GameConfig = GameConfig(variant: GameVariants.plakotoStandard)) {
        base = BoardEncoder(config: config)
        boardSize = config.boardSize
        piecesPerPlayer = config.piecesPerPlayer
    }

    public var inputSize: Int { base.inputSize + 8 }

    public func encode(_ board: GameBoard, isWhitesTurn: Bool) -> [Float] {
        var out = base.encode(board, isWhitesTurn: isWhitesTurn)
        let bs = out.count
        out.append(contentsOf: repeatElement(0, count: 8))
        let our: Color = isWhitesTurn ? .white : .black
        let inv = 1.0 / Float(piecesPerPlayer)
        for (k, c) in [our, our.opponent].enumerated() {
            let p = board.points[c.isWhite ? 1 : boardSize]
            var onStart = 0
            var pinned = false
            if let top = p.topColor {
                if top == c { onStart = p.activeCount } else if p.isCaptured { onStart = 1; pinned = true }
            }
            out[bs + k] = onStart > 0 ? 1 : 0
            out[bs + 2 + k] = pinned ? 1 : 0
            out[bs + 4 + k] = Float(onStart) * inv
            out[bs + 6 + k] = board.points[c.isWhite ? boardSize + 1 : 0].count > 0 ? 1 : 0
        }
        return out
    }
}
