import Foundation

/// Board-display mapping (#143): turns the engine's per-point stacks (indices
/// `0...boardSize+1`) into what the board views draw, driven **only** by the variant's
/// geometry hooks — no view hard-codes a variant.
///
/// The engine's end indices can hold two kinds of off-board checker (Portes keeps a
/// colour's bar checkers in the stack at the opposite end from its off tray, see
/// `PortesVariant`). The display splits them: the trays (`0` / `boardSize+1`) show only
/// **borne-off** checkers, and each colour's **bar** checkers move to a display slot of
/// their own (`whiteBarSlot` / `blackBarSlot`, past the engine range), which the board
/// geometry places on the centre bar.
///
/// A checker of colour `c` at end index `e` is
/// - borne off when `e == variant.bearOffPoint(for: c)`,
/// - on the bar when `variant.pathIndex(of: e, for: c) == 0` (its entry point).
///
/// For Plakoto / standard Plakoto / Fevga no checker ever sits on a bar position, so
/// the display is the engine stacks plus two empty bar slots.
public enum BoardLayout {
    /// Display slot of White's bar checkers.
    public static let whiteBarSlot = 26
    /// Display slot of Black's bar checkers.
    public static let blackBarSlot = 27
    /// Number of display slots (`0...boardSize+1` + the two bar slots, for 24 points).
    public static let slotCount = 28

    public static func barSlot(for color: Color) -> Int {
        color.isWhite ? whiteBarSlot : blackBarSlot
    }

    public static func isBarSlot(_ slot: Int) -> Bool {
        slot == whiteBarSlot || slot == blackBarSlot
    }

    /// The engine end index (`0` / `boardSize+1`) holding `color`'s bar checkers per
    /// the variant's path (`pathIndex == 0`), or `nil` when the variant has none.
    public static func barPosition(for color: Color, variant: any GameVariant,
                                   boardSize: Int = 24) -> Int? {
        for end in [0, boardSize + 1]
        where end != variant.bearOffPoint(for: color, boardSize: boardSize)
            && variant.pathIndex(of: end, for: color, boardSize: boardSize) == 0 {
            return end
        }
        return nil
    }

    /// Display stacks (`slotCount` entries) for engine stacks (`boardSize + 2` entries):
    /// the trays keep only borne-off checkers, bar checkers move to the bar slots.
    public static func displayStacks(_ stacks: [[Color]], variant: any GameVariant) -> [[Color]] {
        let boardSize = stacks.count - 2
        var out = stacks + [[], []]
        for color in [Color.white, .black] {
            guard let end = barPosition(for: color, variant: variant, boardSize: boardSize),
                  stacks.indices.contains(end) else { continue }
            let onBar = stacks[end].filter { $0 == color }.count
            guard onBar > 0 else { continue }
            out[end] = stacks[end].filter { $0 != color }
            out[barSlot(for: color)] = Array(repeating: color, count: onBar)
        }
        return out
    }

    /// The display slot a checker picked up from engine `position` is drawn at: a
    /// bar position maps to that colour's bar slot, everything else is unchanged.
    /// (Nothing is ever picked up from a tray, so an end index used as a *source* is
    /// always a bar.)
    public static func displaySlot(forSource position: Int, variant: any GameVariant,
                                   boardSize: Int = 24) -> Int {
        guard position == 0 || position == boardSize + 1 else { return position }
        for color in [Color.white, .black]
        where barPosition(for: color, variant: variant, boardSize: boardSize) == position {
            return barSlot(for: color)
        }
        return position
    }

    /// The engine source position for a tapped / dragged display slot, or `nil` when
    /// the slot can never be a move source (a bear-off tray, or a bar the variant lacks).
    public static func sourcePosition(forDisplaySlot slot: Int, variant: any GameVariant,
                                      boardSize: Int = 24) -> Int? {
        if slot == whiteBarSlot { return barPosition(for: .white, variant: variant, boardSize: boardSize) }
        if slot == blackBarSlot { return barPosition(for: .black, variant: variant, boardSize: boardSize) }
        guard (1...boardSize).contains(slot) else { return nil }
        return slot
    }

    /// `color`'s borne-off checkers (only those in its own tray — never bar checkers).
    public static func borneOffCount(_ color: Color, stacks: [[Color]],
                                     variant: any GameVariant) -> Int {
        let boardSize = stacks.count - 2
        let tray = variant.bearOffPoint(for: color, boardSize: boardSize)
        guard stacks.indices.contains(tray) else { return 0 }
        return stacks[tray].filter { $0 == color }.count
    }

    /// `color`'s checkers on the bar.
    public static func barCount(_ color: Color, stacks: [[Color]], variant: any GameVariant) -> Int {
        let boardSize = stacks.count - 2
        guard let end = barPosition(for: color, variant: variant, boardSize: boardSize),
              stacks.indices.contains(end) else { return 0 }
        return stacks[end].filter { $0 == color }.count
    }

    /// Checkers sent to the bar between two display snapshots (a hit), as
    /// `(from: board point, to: bar slot, color)` — drives the hit animation. A colour
    /// whose bar count grew by `k` lost a checker on up to `k` board points; those are
    /// the hit points. Empty when no bar grew (ordinary moves, undo).
    public static func hits(from old: [[Color]], to new: [[Color]]) -> [(from: Int, to: Int, color: Color)] {
        guard old.count == slotCount, new.count == slotCount else { return [] }
        var result: [(from: Int, to: Int, color: Color)] = []
        for color in [Color.white, .black] {
            let bar = barSlot(for: color)
            let grew = new[bar].count - old[bar].count
            guard grew > 0 else { continue }
            var found = 0
            for p in 1...(slotCount - 4) where found < grew {
                let before = old[p].filter { $0 == color }.count
                let after = new[p].filter { $0 == color }.count
                if after < before {
                    result.append((from: p, to: bar, color: color))
                    found += 1
                }
            }
        }
        return result
    }
}

public extension GameVariant {
    /// Whether the value network's output is **normalized expected points** rather
    /// than a win probability (variants with 2-point wins): the UI then labels it
    /// "equity" instead of "win chance".
    var reportsEquity: Bool { maxPoints > 1 }

    /// Expected points in `[-maxPoints, +maxPoints]` for a value `v ∈ [0, 1]`
    /// (`v = 0.5 + E / (2 * maxPoints)`, the inverse of `terminalValue`'s scaling).
    func equity(fromValue v: Double) -> Double {
        (v - 0.5) * 2 * Double(maxPoints)
    }
}
