import Foundation

/// Incrementally builds a full `Move` from half-moves chosen one at a time.
///
/// A turn's legal `Move`s are full sequences of 1-4 `HalfMove`s. As the player
/// picks each half-move, `MoveBuilder` narrows `activeMoves` to those still
/// consistent with the choices made so far, exposing which sources/destinations
/// remain selectable. It is UI-agnostic: no rendering, no engine mutation. The
/// owner (`GameSession`) is responsible for applying/undoing half-moves on the
/// board in step with `commit`/`undo`.
public final class MoveBuilder {
    /// Legal full moves still consistent with the half-moves built so far.
    public private(set) var activeMoves: [Move]
    /// Half-moves committed so far, in order.
    public private(set) var built: [HalfMove] = []

    public init(legalMoves: [Move]) {
        self.activeMoves = legalMoves
    }

    /// Points a checker may be picked up FROM for the next half-move.
    public var selectableSourcePoints: Set<Int> {
        let idx = built.count
        return Set(activeMoves.compactMap { m in
            guard m.halfMoves.count > idx else { return nil }
            return m.halfMoves[idx].from.position
        })
    }

    /// Valid destination points for the next half-move given a chosen `from`.
    public func validDestinations(for fromPosition: Int) -> Set<Int> {
        let idx = built.count
        return Set(activeMoves.compactMap { m in
            guard m.halfMoves.count > idx,
                  m.halfMoves[idx].from.position == fromPosition else { return nil }
            return m.halfMoves[idx].to.position
        })
    }

    /// Commits a half-move and narrows `activeMoves`. Returns whether the move
    /// is now complete (no surviving move has further half-moves to play).
    @discardableResult
    public func commit(halfMove hm: HalfMove) -> Bool {
        let idx = built.count
        activeMoves = activeMoves.filter { m in
            guard m.halfMoves.count > idx else { return false }
            return m.halfMoves[idx].from == hm.from && m.halfMoves[idx].to == hm.to
        }
        built.append(hm)
        let maxLen = activeMoves.map(\.halfMoves.count).max() ?? 0
        return built.count >= maxLen
    }

    /// True if the current partial sequence is itself a complete legal move
    /// (some surviving move has exactly `built.count` half-moves).
    public var canFinishNow: Bool {
        activeMoves.contains { $0.halfMoves.count == built.count }
    }

    /// Undo the last committed half-move, rebuilding `activeMoves` from scratch
    /// against the full legal-move list.
    public func undo(allLegal: [Move]) {
        guard !built.isEmpty else { return }
        built.removeLast()
        activeMoves = allLegal.filter { m in
            guard m.halfMoves.count >= built.count else { return false }
            for (i, hm) in built.enumerated() {
                if m.halfMoves[i].from != hm.from || m.halfMoves[i].to != hm.to { return false }
            }
            return true
        }
    }

    /// The composed `Move` matching what has been built so far, if complete.
    public var completedMove: Move? {
        guard canFinishNow else { return nil }
        return activeMoves.first { $0.halfMoves.count == built.count }
    }
}
