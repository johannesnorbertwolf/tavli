import Foundation

/// Mirrors `domain/move.py`. An ordered sequence of 1-4 half-moves.
public final class Move: CustomStringConvertible, Equatable {
    public let halfMoves: [HalfMove]

    public init(_ halfMoves: [HalfMove]) {
        self.halfMoves = halfMoves
    }

    public var description: String {
        "(" + halfMoves.map(\.description).joined(separator: ",") + ")"
    }

    public static func == (lhs: Move, rhs: Move) -> Bool {
        lhs.halfMoves.count == rhs.halfMoves.count
            && zip(lhs.halfMoves, rhs.halfMoves).allSatisfy { $0 == $1 }
    }
}
