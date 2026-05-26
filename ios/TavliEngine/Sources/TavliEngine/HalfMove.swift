import Foundation

/// Mirrors `domain/half_move.py`. Holds references to the board's `Point`
/// objects, so applying a half-move mutates the board in place.
public final class HalfMove: CustomStringConvertible, Equatable {
    public let from: Point
    public let to: Point
    public let color: Color

    public init(from: Point, to: Point, color: Color) {
        self.from = from
        self.to = to
        self.color = color
    }

    public var description: String { "\(from.position)->\(to.position)" }

    /// From-point is owned by color and to-point is landable.
    public func isValid() -> Bool {
        from.isColor(color) && to.isOpen(for: color)
    }

    public func twoCheckersAvailable() -> Bool { from.isDoubleColor(color) }

    public func canMerge(with other: HalfMove) -> Bool { to == other.from }

    public func canMergeOrViceVersa(with other: HalfMove) -> Bool {
        canMerge(with: other) || other.canMerge(with: self)
    }

    public func merge(with other: HalfMove) -> HalfMove {
        HalfMove(from: from, to: other.to, color: color)
    }

    public static func == (lhs: HalfMove, rhs: HalfMove) -> Bool {
        lhs.from == rhs.from && lhs.to == rhs.to && lhs.color == rhs.color
    }
}
