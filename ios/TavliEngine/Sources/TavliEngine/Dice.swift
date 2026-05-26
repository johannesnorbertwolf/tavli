import Foundation

/// Mirrors `domain/dice.py`.
public final class Die: Equatable {
    public let numberOfSides: Int
    public var value: Int

    public init(numberOfSides: Int, value: Int = 0) {
        self.numberOfSides = numberOfSides
        self.value = value
    }

    public static func == (lhs: Die, rhs: Die) -> Bool { lhs.value == rhs.value }

    @discardableResult
    public func roll<G: RandomNumberGenerator>(using generator: inout G) -> Int {
        value = Int.random(in: 1...numberOfSides, using: &generator)
        return value
    }

    @discardableResult
    public func roll() -> Int {
        var system = SystemRandomNumberGenerator()
        return roll(using: &system)
    }
}

public final class Dice {
    public let die1: Die
    public let die2: Die

    public init(numberOfSides: Int = 6) {
        self.die1 = Die(numberOfSides: numberOfSides)
        self.die2 = Die(numberOfSides: numberOfSides)
    }

    public func roll() {
        die1.roll()
        die2.roll()
    }

    public func set(_ d1: Int, _ d2: Int) {
        die1.value = d1
        die2.value = d2
    }

    public var isPasch: Bool { die1 == die2 }
}
