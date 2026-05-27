import Foundation

/// Incrementally builds a full `Move` from half-moves chosen one at a time.
///
/// A turn's legal `Move`s are full sequences of 1-4 `HalfMove`s. As the player
/// picks each half-move, `MoveBuilder` narrows `activeMoves` to those still
/// consistent with the choices made so far, exposing which sources/destinations
/// remain selectable. It is UI-agnostic: no rendering, no engine mutation. The
/// owner (`GameSession`) is responsible for applying/undoing half-moves on the
/// board in step with `commit`/`undo`.
///
/// **Order-independence.** The engine stores each multi-die move in one canonical
/// order (e.g. a dice (3,5) two-checker move is always `[1→4, 1→6]`, die-1 first),
/// but the player may legally play those half-moves in either order. So the
/// builder treats a move's half-moves as a *bag* and offers, at each step, every
/// half-move that could come next in *some* valid ordering — not just the stored
/// one. The only ordering constraint is a chain dependency: a half-move whose
/// `from` is another remaining half-move's `to` (a checker handed along, as in a
/// pasch chain `1→3→5`) can't be played until that predecessor is. Independent
/// half-moves (different checkers) are freely reorderable. This never offers a
/// board-illegal step — for a legal move with a valid built prefix, any half-move
/// with no remaining predecessor has its `from` already populated.
public final class MoveBuilder {
    /// Legal full moves still consistent with the half-moves built so far.
    public private(set) var activeMoves: [Move]
    /// Half-moves committed so far, in the order the player chose.
    public private(set) var built: [HalfMove] = []

    public init(legalMoves: [Move]) {
        self.activeMoves = legalMoves
    }

    /// Points a checker may be picked up FROM for the next half-move.
    public var selectableSourcePoints: Set<Int> {
        var sources: Set<Int> = []
        for m in activeMoves {
            guard let rem = remaining(of: m) else { continue }
            for hm in playableNext(rem) { sources.insert(hm.from.position) }
        }
        return sources
    }

    /// Valid destination points for the next half-move given a chosen `from`.
    public func validDestinations(for fromPosition: Int) -> Set<Int> {
        var dests: Set<Int> = []
        for m in activeMoves {
            guard let rem = remaining(of: m) else { continue }
            for hm in playableNext(rem) where hm.from.position == fromPosition {
                dests.insert(hm.to.position)
            }
        }
        return dests
    }

    /// Commits a half-move and narrows `activeMoves` to the moves in which `hm`
    /// is a valid next step. Returns whether the move is now complete (no
    /// surviving move has further half-moves to play).
    @discardableResult
    public func commit(halfMove hm: HalfMove) -> Bool {
        activeMoves = activeMoves.filter { m in
            guard let rem = remaining(of: m) else { return false }
            return playableNext(rem).contains { $0 == hm }
        }
        built.append(hm)
        let maxRemaining = activeMoves.compactMap { remaining(of: $0)?.count }.max() ?? 0
        return maxRemaining == 0
    }

    /// True if the current partial sequence is itself a complete legal move
    /// (some surviving move has no half-moves left to play).
    public var canFinishNow: Bool {
        activeMoves.contains { remaining(of: $0)?.isEmpty == true }
    }

    /// Undo the last committed half-move, rebuilding `activeMoves` from scratch
    /// against the full legal-move list.
    public func undo(allLegal: [Move]) {
        guard !built.isEmpty else { return }
        built.removeLast()
        activeMoves = allLegal.filter { remaining(of: $0) != nil }
    }

    /// The composed `Move` matching what has been built so far, if complete.
    public var completedMove: Move? {
        activeMoves.first { remaining(of: $0)?.isEmpty == true }
    }

    // ── Ordering model ───────────────────────────────────────────────────────

    /// The half-moves of `m` not yet played, validating that `built` is a legal
    /// ordering prefix of `m` (each built half-move was playable-next when
    /// removed). Returns `nil` if `built` is not a valid prefix of `m`.
    private func remaining(of m: Move) -> [HalfMove]? {
        var rem = m.halfMoves
        for b in built {
            guard playableNext(rem).contains(where: { $0 == b }),
                  let i = rem.firstIndex(where: { $0 == b }) else { return nil }
            rem.remove(at: i)
        }
        return rem
    }

    /// Half-moves in `rem` that may be played next: those with no *other*
    /// remaining half-move delivering a checker to their `from` point.
    private func playableNext(_ rem: [HalfMove]) -> [HalfMove] {
        rem.enumerated().filter { i, h in
            !rem.enumerated().contains { j, o in j != i && o.to == h.from }
        }.map(\.element)
    }
}
