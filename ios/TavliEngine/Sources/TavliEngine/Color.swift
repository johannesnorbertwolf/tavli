import Foundation

/// Mirrors `domain/color.py`.
public enum Color: String, Sendable, Hashable, CaseIterable {
    case white = "W"
    case black = "B"

    public var isWhite: Bool { self == .white }

    public var opponent: Color { self == .white ? .black : .white }
}
