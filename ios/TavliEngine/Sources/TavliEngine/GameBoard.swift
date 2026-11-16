import Foundation

/// Mirrors `domain/board.py`. Points are indexed `0...boardSize+1`.
/// White starts at point 1 and bears off at `boardSize+1`; Black starts at
/// `boardSize` and bears off at 0.
public final class GameBoard: CustomStringConvertible {
    public let config: GameConfig
    public var points: [Point]

    public var boardSize: Int { config.boardSize }
    public var homeSize: Int { config.homeSize }
    public var numberOfPieces: Int { config.piecesPerPlayer }
    /// The rules this board is played under (#136). The stack-of-colours container is
    /// variant-neutral; the Plakoto-specific helpers below (`initializeBoard`,
    /// `apply`/`undo`, `hasWon`, …) are reached by shared code only via `PlakotoVariant`.
    public var variant: any GameVariant { config.variant }

    public init(config: GameConfig = .standard) {
        self.config = config
        self.points = (0...(config.boardSize + 1)).map { Point(position: $0) }
    }

    public func initializeBoard() {
        points[1] = Point(position: 1, color: .white, count: numberOfPieces)
        points[boardSize] = Point(position: boardSize, color: .black, count: numberOfPieces)
    }

    /// Replace a point's stack (bottom -> top). Used to reconstruct serialized
    /// positions, e.g. parity fixtures.
    public func setPoint(_ index: Int, pieces: [Color]) {
        let p = Point(position: index)
        p.pieces = pieces
        points[index] = p
    }

    public var description: String {
        (0...(boardSize + 1)).reversed().map { points[$0].description }.joined(separator: "\n")
    }

    /// Capture every point's stack (bottom→top) for a later exact restore.
    /// Analysis passes (move scoring, single-die probing) mutate the live board in
    /// place; pairing this with `restoreStacks` guarantees they leave the position
    /// byte-identical even if a step throws or returns early partway through.
    public func captureStacks() -> [[Color]] { points.map(\.pieces) }

    /// Restore stacks captured by `captureStacks()`.
    public func restoreStacks(_ stacks: [[Color]]) {
        for i in points.indices { points[i].pieces = stacks[i] }
    }

    /// Empty every point (bear-off trays / bars included) and drop any variant undo
    /// bookkeeping. Variants call this before laying out their starting position.
    public func clear() {
        for p in points { p.pieces.removeAll(keepingCapacity: true) }
        undoLog.removeAll()
    }

    /// Per-board undo bookkeeping a variant needs beyond the stacks (Portes: whether
    /// each applied half-move hit a blot). Strictly LIFO: a variant's `applyHalfMove`
    /// pushes, its `undoHalfMove` pops. Never part of the *position* — two boards with
    /// equal stacks are the same position whatever their logs hold.
    var undoLog: [Bool] = []

    /// The full mutable state: the stacks plus the undo-log depth. Pair
    /// `captureSnapshot()` with `restore(_:)` around code that applies moves and
    /// might exit before undoing them (a thrown Core ML error, an early return), so
    /// both the position *and* the undo bookkeeping come back exactly.
    public struct Snapshot: Equatable {
        public let stacks: [[Color]]
        let undoDepth: Int
    }

    public func captureSnapshot() -> Snapshot { Snapshot(stacks: captureStacks(), undoDepth: undoLog.count) }

    public func restore(_ snapshot: Snapshot) {
        restoreStacks(snapshot.stacks)
        if undoLog.count > snapshot.undoDepth { undoLog.removeLast(undoLog.count - snapshot.undoDepth) }
    }

    public func apply(_ move: Move) {
        for hm in move.halfMoves { applyHalfMove(hm) }
    }

    public func undo(_ move: Move) {
        for hm in move.halfMoves.reversed() { undoHalfMove(hm) }
    }

    public func applyHalfMove(_ hm: HalfMove) {
        hm.from.pop()
        hm.to.push(hm.color)
    }

    public func undoHalfMove(_ hm: HalfMove) {
        hm.to.pop()
        hm.from.push(hm.color)
    }

    public func hasWon(_ color: Color) -> Bool {
        allPlayersInGoal(color) || capturedStartingPosition(color)
    }

    public func allPlayersInGoal(_ color: Color) -> Bool {
        color.isWhite
            ? points[boardSize + 1].count == numberOfPieces
            : points[0].count == numberOfPieces
    }

    public func capturedStartingPosition(_ color: Color) -> Bool {
        color.isWhite
            ? points[boardSize].isCaptured(by: .white)
            : points[1].isCaptured(by: .black)
    }

    public func isHomePoint(_ color: Color, _ pointIndex: Int) -> Bool {
        if color.isWhite {
            return (boardSize - homeSize + 1) <= pointIndex && pointIndex <= boardSize
        }
        return 1 <= pointIndex && pointIndex <= homeSize
    }

    public func countCheckersOutsideHome(_ color: Color) -> Int {
        var outside = 0
        for i in 1...boardSize where !isHomePoint(color, i) {
            outside += points[i].countForColor(color)
        }
        return outside
    }

    public func allCheckersInHome(_ color: Color) -> Bool {
        countCheckersOutsideHome(color) == 0
    }
}
