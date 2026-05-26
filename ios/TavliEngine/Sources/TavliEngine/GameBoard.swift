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
