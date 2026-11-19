import Foundation

/// The rules seam (#136): everything that differs between Tavli variants (Plakoto,
/// Portes, Fevga, …) sits behind this protocol, so the shared infrastructure —
/// `GameSession`, `MoveBuilder`, the `Agent` search, `GameReview`, persistence and
/// online play — never calls a specific variant's rule code or encoder directly.
/// Mirrors the Python `RuleSet` ABC in `domain/`.
///
/// **Board state.** Every variant uses the shared `GameBoard`: a stack of checker
/// colours per point (bottom → top) over indices `0...boardSize+1`, where `0` and
/// `boardSize+1` are the bear-off trays. That container is variant-neutral — a pin
/// (Plakoto) is just stack order, Portes/Fevga stacks are single-coloured — and the
/// *meaning* of a position (who owns a point, what is open, who has won, which way a
/// colour moves) is decided only by the variant. A variant that needs extra state
/// (e.g. Portes' bar counts) adds it to `GameBoard` and handles it in its own
/// `applyHalfMove`/`undoHalfMove`/`setUpInitialPosition`.
///
/// **Hot path.** The AI search calls `legalMoves`/`apply`/`undo`/`hasWon`/the encoder
/// millions of times through `any GameVariant`. Each call is one witness-table hop —
/// negligible next to move generation's allocations and the Core ML prediction per
/// leaf — so the existential is kept rather than making `Agent` generic.
public protocol GameVariant: Sendable {
    /// Stable identifier persisted in saves / online payloads (`"plakoto"`). Never
    /// change an existing id: old saves resolve their variant by it.
    var id: String { get }

    /// Base name of the bundled Core ML value model for this variant (no extension),
    /// e.g. `"PlakotoValue"` → `PlakotoValue.mlmodelc` / `.mlpackage`.
    var modelResourceName: String { get }

    /// Put the variant's starting position on `board` (mutates in place).
    func setUpInitialPosition(on board: GameBoard)

    /// Every legal full move for `color` under `dice` at `board`'s position. An empty
    /// result is a forced pass. Must be deterministic (the session maps search
    /// results back to the live move list by index).
    func legalMoves(on board: GameBoard, color: Color, dice: Dice) -> [Move]

    /// Apply / reverse one half-move in place. `undoHalfMove` must exactly restore
    /// the position `applyHalfMove` started from.
    func applyHalfMove(_ halfMove: HalfMove, on board: GameBoard)
    func undoHalfMove(_ halfMove: HalfMove, on board: GameBoard)

    /// Apply / reverse a full move. Default: its half-moves in order / reverse order.
    func apply(_ move: Move, on board: GameBoard)
    func undo(_ move: Move, on board: GameBoard)

    /// Whether `color` has won at this position.
    func hasWon(_ color: Color, on board: GameBoard) -> Bool

    /// Whether a `color` checker may land on board index `point`.
    func isOpen(_ point: Int, for color: Color, on board: GameBoard) -> Bool

    /// Points the `winner` scores for a finished game: 1 = single, 2 = double win.
    func resultPoints(winner: Color, on board: GameBoard) -> Int

    /// The value-network input encoding for this variant, for boards of `config`.
    func makeEncoder(config: GameConfig) -> any BoardEncoding

    // ── Outcome seam (mirrors `RuleSet.max_points` / `is_over` / `outcome` /
    //    `terminal_value` / `random_starting_player`; defaults reproduce Plakoto) ──

    /// Largest result a game can have (1 = win/loss only, 2 = gammons count double).
    var maxPoints: Int { get }
    /// `true`: the starter is picked uniformly at random (distributionally the
    /// opening roll). `false`: the caller's fixed starter (Plakoto).
    var randomStartingPlayer: Bool { get }
    /// `true` iff the game can only end by a win of the side that just moved (the
    /// default `isOver`), so a search leaf may test `hasWon(mover)` only — the cheap
    /// path. Variants overriding `isOver` (draws, standard Plakoto's mother rule)
    /// return `false` and get the full `isOver` at every leaf, as `ai/agent.py` does.
    var endsOnlyByMoverWin: Bool { get }
    /// The game has ended (a win for either side, or a draw).
    func isOver(on board: GameBoard) -> Bool
    /// `(winner, points)` of a finished game; `winner == nil` is a draw (0 points).
    /// Only meaningful when `isOver(on:)`.
    func outcome(on board: GameBoard) -> (winner: Color?, points: Int)
    /// Value in [0, 1] of the finished game for `perspective`:
    /// `0.5 + signedPoints / (2 * maxPoints)` (1/0 for Plakoto, 0.5 for a draw).
    func terminalValue(on board: GameBoard, perspective: Color) -> Float

    // ── Geometry hooks (shared helpers must not assume `dst = src + color*die`) ──

    /// `color`'s path index of board point `point`: pips travelled from its start
    /// side, `1...boardSize` on the board, `0` = its entry bar (Portes), and
    /// `boardSize + 1` = borne off. Default: White `point`, Black `boardSize+1-point`.
    func pathIndex(of point: Int, for color: Color, boardSize: Int) -> Int
    /// Inverse of `pathIndex`: the board point at path index `path` for `color`.
    func point(atPath path: Int, for color: Color, boardSize: Int) -> Int
    /// Board index a `color` checker is borne off to (default White `boardSize+1`, Black 0).
    func bearOffPoint(for color: Color, boardSize: Int) -> Int
    /// Checkers of `color` that can be picked up from board index `point` right now
    /// (default: `Point.movablePieces`, i.e. the owner stack minus a pinned checker).
    func movableCount(at point: Int, for color: Color, on board: GameBoard) -> Int
    /// For a single-half `Move` that one checker plays with *both* (distinct) dice in
    /// the merged notation: the intermediate points through which it can be legally
    /// played as two single-die hops, in `die1`, `die2` order (deduplicated). Empty =
    /// not a merged two-dice move (`MoveBuilder` then leaves it whole). Default: the
    /// Plakoto rule — exact distance `die1 + die2` along the path, landable midpoint.
    func intermediatePoints(of half: HalfMove, die1: Int, die2: Int, on board: GameBoard) -> [Int]

    /// Whether a `color` checker may play `from → to` (board indices) with the single die
    /// `die` **right now**, as one step of a turn: the variant's per-play rules at this
    /// exact position (bar first, bear-off only with every checker home, larger-die
    /// bear-off, Fevga's first-checker lock, …). The dice obligation over the whole turn
    /// (most dice, larger die) is *not* checked — the legal-move list enforces that.
    /// `MoveBuilder` uses it so a legal move's half-moves are accepted only in an order
    /// that is itself a legal sequence of plays. Default: the Plakoto rule — exact
    /// distance, movable source, open target, bear-off only when all checkers are home.
    func isLegalStep(from: Int, to: Int, color: Color, die: Int, on board: GameBoard) -> Bool
}

public extension GameVariant {
    var maxPoints: Int { 1 }
    var randomStartingPlayer: Bool { false }
    var endsOnlyByMoverWin: Bool { true }

    func isOver(on board: GameBoard) -> Bool {
        hasWon(.white, on: board) || hasWon(.black, on: board)
    }

    func outcome(on board: GameBoard) -> (winner: Color?, points: Int) {
        if hasWon(.white, on: board) { return (.white, resultPoints(winner: .white, on: board)) }
        if hasWon(.black, on: board) { return (.black, resultPoints(winner: .black, on: board)) }
        return (nil, 0)
    }

    func terminalValue(on board: GameBoard, perspective: Color) -> Float {
        let (winner, points) = outcome(on: board)
        guard let winner else { return 0.5 }
        let signed = Double(winner == perspective ? points : -points)
        return Float(0.5 + signed / (2.0 * Double(maxPoints)))
    }

    /// Who moves first: `fallback` unless `randomStartingPlayer` (then a fair coin).
    func startingPlayer(default fallback: Color) -> Color {
        guard randomStartingPlayer else { return fallback }
        return Bool.random() ? .white : .black
    }

    func pathIndex(of point: Int, for color: Color, boardSize: Int) -> Int {
        color.isWhite ? point : boardSize + 1 - point
    }

    func point(atPath path: Int, for color: Color, boardSize: Int) -> Int {
        color.isWhite ? path : boardSize + 1 - path
    }

    func bearOffPoint(for color: Color, boardSize: Int) -> Int {
        color.isWhite ? boardSize + 1 : 0
    }

    func movableCount(at point: Int, for color: Color, on board: GameBoard) -> Int {
        board.points[point].movablePieces(for: color)
    }

    func isLegalStep(from: Int, to: Int, color: Color, die: Int, on board: GameBoard) -> Bool {
        let n = board.boardSize
        guard pathIndex(of: to, for: color, boardSize: n) - pathIndex(of: from, for: color, boardSize: n) == die,
              movableCount(at: from, for: color, on: board) > 0,
              isOpen(to, for: color, on: board) else { return false }
        if to == bearOffPoint(for: color, boardSize: n) { return board.countCheckersOutsideHome(color) == 0 }
        return true
    }

    func intermediatePoints(of half: HalfMove, die1: Int, die2: Int, on board: GameBoard) -> [Int] {
        let n = board.boardSize
        let from = pathIndex(of: half.from.position, for: half.color, boardSize: n)
        let to = pathIndex(of: half.to.position, for: half.color, boardSize: n)
        guard to - from == die1 + die2 else { return [] }
        var mids: [Int] = []
        for step in [die1, die2] {
            let mid = point(atPath: from + step, for: half.color, boardSize: n)
            guard !mids.contains(mid), isOpen(mid, for: half.color, on: board) else { continue }
            mids.append(mid)
        }
        return mids
    }
}

public extension GameVariant {
    func apply(_ move: Move, on board: GameBoard) {
        for hm in move.halfMoves { applyHalfMove(hm, on: board) }
    }

    func undo(_ move: Move, on board: GameBoard) {
        for hm in move.halfMoves.reversed() { undoHalfMove(hm, on: board) }
    }

    /// The winner at this position, if any (WHITE checked first, as `Game` always has).
    /// `nil` both while the game is running and for a draw — see `isOver`/`outcome`.
    func winner(on board: GameBoard) -> Color? {
        isOver(on: board) ? outcome(on: board).winner : nil
    }
}

/// A value-network board encoding. One per variant (each variant's network has its
/// own input layout); `encode` must match the Python encoder bit-for-bit.
public protocol BoardEncoding: Sendable {
    /// Length of the vector `encode` returns (the model's input width).
    var inputSize: Int { get }
    /// Encode `board` from the perspective of the side to move.
    func encode(_ board: GameBoard, isWhitesTurn: Bool) -> [Float]
}

extension BoardEncoder: BoardEncoding {}

/// Plakoto — the original (and so far only) variant. A thin adapter over the
/// parity-validated port: `GameBoard`'s stack ops + `hasWon`, `PossibleMoves`, and
/// the `unary_v3` `BoardEncoder`, all unchanged.
public struct PlakotoVariant: GameVariant {
    public init() {}

    public var id: String { "plakoto" }
    public var modelResourceName: String { "PlakotoValue" }

    public func setUpInitialPosition(on board: GameBoard) {
        board.clear()
        board.initializeBoard()
    }

    public func legalMoves(on board: GameBoard, color: Color, dice: Dice) -> [Move] {
        if let rules = board.config.handicapRules {   // tier-2 handicap (#148)
            var gen = HandicapMoveGenerator(board: board, color: color, rules: rules)
            return gen.findMoves(dice: dice)
        }
        return PossibleMoves(board: board, color: color, dice: dice).findMoves()
    }

    public func applyHalfMove(_ halfMove: HalfMove, on board: GameBoard) { board.applyHalfMove(halfMove) }
    public func undoHalfMove(_ halfMove: HalfMove, on board: GameBoard) { board.undoHalfMove(halfMove) }
    public func apply(_ move: Move, on board: GameBoard) { board.apply(move) }
    public func undo(_ move: Move, on board: GameBoard) { board.undo(move) }

    public func hasWon(_ color: Color, on board: GameBoard) -> Bool { board.hasWon(color) }

    public func isOpen(_ point: Int, for color: Color, on board: GameBoard) -> Bool {
        if let rules = board.config.handicapRules { return board.handicapIsOpen(point, for: color, rules: rules) }
        return board.points[point].isOpen(for: color)
    }

    public func isLegalStep(from: Int, to: Int, color: Color, die: Int, on board: GameBoard) -> Bool {
        if let rules = board.config.handicapRules {
            return handicapIsLegalStep(from: from, to: to, color: color, die: die, on: board, rules: rules)
        }
        let n = board.boardSize
        guard pathIndex(of: to, for: color, boardSize: n) - pathIndex(of: from, for: color, boardSize: n) == die,
              movableCount(at: from, for: color, on: board) > 0,
              isOpen(to, for: color, on: board) else { return false }
        if to == bearOffPoint(for: color, boardSize: n) { return board.countCheckersOutsideHome(color) == 0 }
        return true
    }

    public func intermediatePoints(of half: HalfMove, die1: Int, die2: Int, on board: GameBoard) -> [Int] {
        if let rules = board.config.handicapRules {
            return handicapIntermediatePoints(of: half, die1: die1, die2: die2, on: board, rules: rules)
        }
        let n = board.boardSize
        let from = pathIndex(of: half.from.position, for: half.color, boardSize: n)
        let to = pathIndex(of: half.to.position, for: half.color, boardSize: n)
        guard to - from == die1 + die2 else { return [] }
        var mids: [Int] = []
        for step in [die1, die2] {
            let mid = point(atPath: from + step, for: half.color, boardSize: n)
            guard !mids.contains(mid), isOpen(mid, for: half.color, on: board) else { continue }
            mids.append(mid)
        }
        return mids
    }

    /// Plakoto in this app scores every win as a single game (the match score counts
    /// games won), so this is always 1 — exactly what the app does today.
    public func resultPoints(winner: Color, on board: GameBoard) -> Int { 1 }

    public func makeEncoder(config: GameConfig) -> any BoardEncoding { BoardEncoder(config: config) }
}

/// Registry of the variants this build knows, keyed by their persisted `id`.
public enum GameVariants {
    public static let plakoto = PlakotoVariant()
    /// The id written by builds that predate the variant field (and the default).
    public static let defaultID = "plakoto"

    public static let plakotoStandard = StandardPlakotoVariant()
    public static let fevga = FevgaVariant()
    public static let portes = PortesVariant()

    public static let all: [any GameVariant] = [plakoto, plakotoStandard, fevga, portes]

    /// The variant for a persisted id, or `nil` if this build doesn't know it.
    public static func variant(forID id: String) -> (any GameVariant)? {
        all.first { $0.id == id }
    }
}
