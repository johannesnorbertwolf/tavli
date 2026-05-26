import Foundation

/// A single board point. Mirrors `domain/point.py`.
/// `pieces` is a stack ordered bottom -> top. In Plakoto the *bottom* piece may be
/// a pinned opponent checker; the *top* piece's color owns the point.
public final class Point: Equatable, CustomStringConvertible {
    public let position: Int
    public internal(set) var pieces: [Color]

    public init(position: Int, color: Color = .white, count: Int = 0) {
        self.position = position
        self.pieces = count > 0 ? Array(repeating: color, count: count) : []
    }

    /// Mirrors Python `Point.__eq__`: equality is by position only.
    public static func == (lhs: Point, rhs: Point) -> Bool {
        lhs.position == rhs.position
    }

    public var description: String {
        let prefix = position < 10 ? " " : ""
        let body = pieces.map { $0.isWhite ? "O" : "X" }.joined()
        return "\(prefix)\(position): \(body)"
    }

    public var count: Int { pieces.count }

    @discardableResult
    public func pop() -> Color? { pieces.popLast() }

    public func push(_ color: Color) { pieces.append(color) }

    /// Top color owns the point (`is_color`).
    public func isColor(_ color: Color) -> Bool { pieces.last == color }

    public var isWhite: Bool { isColor(.white) }

    /// Top color, or nil if empty (`get_color`).
    public var topColor: Color? { pieces.last }

    public var isEmpty: Bool { pieces.isEmpty }

    /// Single checker — can be pinned/landed on (`is_catchable`).
    public var isCatchable: Bool { pieces.count == 1 }

    /// `color` may land here: empty, owned by color, or a lone (catchable) checker.
    public func isOpen(for color: Color) -> Bool {
        isEmpty || isColor(color) || isCatchable
    }

    public func isDoubleColor(_ color: Color) -> Bool {
        guard pieces.count > 1 else { return false }
        return pieces[pieces.count - 1] == color && pieces[pieces.count - 2] == color
    }

    /// `color` has pinned an opponent checker here (`is_captured_by`):
    /// bottom is opponent, second-from-bottom is `color`.
    public func isCaptured(by color: Color) -> Bool {
        guard pieces.count > 1 else { return false }
        return pieces[0] != color && pieces[1] == color
    }

    /// Some color has pinned an opponent checker here (`is_captured`).
    public var isCaptured: Bool {
        guard pieces.count > 1 else { return false }
        return pieces[0] != pieces[1]
    }

    /// Owner's checker count, excluding a pinned opponent checker (`get_count`).
    public var activeCount: Int { isCaptured ? pieces.count - 1 : pieces.count }

    public func countForColor(_ color: Color) -> Int {
        pieces.reduce(0) { $0 + ($1 == color ? 1 : 0) }
    }

    /// Movable checkers for `color` (`get_number_of_movable_pieces`).
    public func movablePieces(for color: Color) -> Int {
        isColor(color) ? activeCount : 0
    }
}
