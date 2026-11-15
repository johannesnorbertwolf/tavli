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
}

public extension GameVariant {
    func apply(_ move: Move, on board: GameBoard) {
        for hm in move.halfMoves { applyHalfMove(hm, on: board) }
    }

    func undo(_ move: Move, on board: GameBoard) {
        for hm in move.halfMoves.reversed() { undoHalfMove(hm, on: board) }
    }

    /// The winner at this position, if any (WHITE checked first, as `Game` always has).
    func winner(on board: GameBoard) -> Color? {
        if hasWon(.white, on: board) { return .white }
        if hasWon(.black, on: board) { return .black }
        return nil
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

    public func setUpInitialPosition(on board: GameBoard) { board.initializeBoard() }

    public func legalMoves(on board: GameBoard, color: Color, dice: Dice) -> [Move] {
        PossibleMoves(board: board, color: color, dice: dice).findMoves()
    }

    public func applyHalfMove(_ halfMove: HalfMove, on board: GameBoard) { board.applyHalfMove(halfMove) }
    public func undoHalfMove(_ halfMove: HalfMove, on board: GameBoard) { board.undoHalfMove(halfMove) }
    public func apply(_ move: Move, on board: GameBoard) { board.apply(move) }
    public func undo(_ move: Move, on board: GameBoard) { board.undo(move) }

    public func hasWon(_ color: Color, on board: GameBoard) -> Bool { board.hasWon(color) }

    public func isOpen(_ point: Int, for color: Color, on board: GameBoard) -> Bool {
        board.points[point].isOpen(for: color)
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

    public static let all: [any GameVariant] = [plakoto]

    /// The variant for a persisted id, or `nil` if this build doesn't know it.
    public static func variant(forID id: String) -> (any GameVariant)? {
        all.first { $0.id == id }
    }
}
