import Foundation

/// Incrementally builds a full `Move` from half-moves chosen one at a time.
///
/// A turn's legal `Move`s are full sequences of 1-4 `HalfMove`s. As the player
/// picks each half-move, `MoveBuilder` narrows `activeMoves` to those still
/// consistent with the choices made so far, exposing which sources/destinations
/// remain selectable. It does not mutate the board — the owner (`GameSession`)
/// applies/undoes half-moves on the live board in step with `commit`/`undo`.
/// `MoveBuilder` only *reads* that same board to decide playability.
///
/// **Order-independence.** The engine stores each multi-die move in one canonical
/// order, but the player may legally play those half-moves in any order. The
/// builder treats a move's half-moves as a *bag* (`remaining(of:)` is a multiset
/// difference) and decides which half-move may come next from the **live board**,
/// not from a combinatorial guess: a remaining half-move is playable-next iff its
/// `from` point currently holds a movable checker and its `to` is open. This
/// distinguishes a genuine single-checker chain (e.g. `8→6→4`, where point 6 is
/// empty until the first hop fills it, so `6→4` is not playable until then) from
/// two *independent* checkers whose ray positions merely coincide (a checker at 8
/// and a separate checker at 6 — both immediately playable, in any order). The
/// old board-blind `to == from` heuristic could not tell those apart and wrongly
/// locked out the independent checker.
///
/// **Multi-hop (Pasch).** On doubles the engine stores each equal-distance hop as
/// a separate half-move, so a single checker can chain along the die ray
/// (`s±N, s±2N, …`). `validDestinations(for:)` returns every such reachable
/// endpoint and `path(from:to:)` gives the ordered hops the session commits for a
/// tap on a far endpoint.
///
/// **Unmerged (non-Pasch single checker).** When a single checker plays *both*
/// distinct dice, the engine stores it *merged* as one half-move (`1→9` for dice
/// 3·5). Left merged, the player could only tap the far endpoint and could never
/// stop on, or continue from, the intermediate stop. So at construction the
/// builder **unmerges** every such half-move (distance `d1 + d2`) into its
/// single-die hop sequence(s) through whichever intermediate(s) are open at the
/// start of the turn — one expanded `Move` per legal intermediate (`[1→4, 4→9]`
/// and/or `[1→6, 6→9]`). Both the immediate stops and the far endpoint then
/// highlight, and tapping the stop lets the same checker continue. The final
/// board position is identical to applying the merged half-move. With this the
/// non-Pasch case is handled by the same bag/chaining machinery as Pasch; the
/// dice are needed only to know `d1`/`d2` for the split.
///
/// **Routes (#169).** Portes never merges: a checker using both dice is two
/// single-die halves, and the two routes `src→a→dst` / `src→b→dst` can end in
/// different positions (a blot hit at `a` but not at `b`, or different blots hit).
/// `routeOptions(from:to:)` enumerates the shortest hop chains to a far destination
/// that are prefixes of a surviving move, applies each on a scratch copy of the
/// board, and keeps one representative per distinct resulting position. One option
/// → the session plays it in one gesture; several → the player must pick the
/// intermediate point (never auto-resolved). For Plakoto/Fevga the unmerged routes
/// always end in the same position, so they keep playing directly.
///
/// **Gestures.** `commit(halfMoves:)` records the hops of one player gesture (a
/// single step, a Pasch multi-hop or a two-dice route) so `undoGesture()` can peel
/// the whole gesture at once.
public final class MoveBuilder {
    /// Legal full moves still consistent with the half-moves built so far.
    public private(set) var activeMoves: [Move]
    /// Half-moves committed so far, in the order the player chose.
    public private(set) var built: [HalfMove] = []

    /// Index into `built` where each committed gesture starts (ascending).
    private var gestureStarts: [Int] = []

    /// The full (unmerged) legal-move set, used to rebuild `activeMoves` on undo.
    private let allMoves: [Move]

    /// The live game board, read (never mutated) to decide playability. The owner
    /// applies/undoes half-moves on this same board in step with `commit`/`undo`,
    /// so the builder always sees the position after the built prefix.
    private let board: GameBoard

    public init(legalMoves: [Move], board: GameBoard, die1: Int = 0, die2: Int = 0) {
        let expanded = MoveBuilder.unmerge(legalMoves, board: board, die1: die1, die2: die2)
        self.allMoves = expanded
        self.activeMoves = expanded
        self.board = board
    }

    /// Points a checker may be picked up FROM for the next half-move.
    public var selectableSourcePoints: Set<Int> {
        var sources: Set<Int> = []
        for m in activeMoves {
            guard let rem = remaining(of: m) else { continue }
            for hm in rem where isPlayable(hm, arrivedAt: nil) {
                sources.insert(hm.from.position)
            }
        }
        return sources
    }

    /// Every destination reachable from `fromPosition` for the next move. On a
    /// Pasch the same checker may chain along the die ray, so this includes the
    /// far endpoints `s±N, s±2N, …`, not just the immediate hop.
    public func validDestinations(for fromPosition: Int) -> Set<Int> {
        Set(reachable(from: fromPosition).keys)
    }

    /// The ordered single-die hops the session applies to move from `fromPosition`
    /// to `toPosition` (one element for a normal move, several for a Pasch
    /// multi-hop tap). Empty if `toPosition` is unreachable.
    public func path(from fromPosition: Int, to toPosition: Int) -> [HalfMove] {
        reachable(from: fromPosition)[toPosition] ?? []
    }

    /// Every distinct way to move the checker on `fromPosition` to `toPosition` in one
    /// gesture, as ordered single-die hop chains: only the **shortest** chains that are
    /// a prefix of some surviving move (given what was already built), deduplicated by
    /// the **resulting position** (first chain in search order kept). Empty if
    /// `toPosition` is unreachable; one element = unambiguous; more = the routes lead
    /// to different positions and the player must choose (#169).
    public func routeOptions(from fromPosition: Int, to toPosition: Int) -> [[HalfMove]] {
        var all: [[HalfMove]] = []
        collectChains(from: fromPosition, to: toPosition, hops: [], into: &all)
        guard let shortest = all.map(\.count).min() else { return [] }
        let chains = all.filter { $0.count == shortest }
        guard chains.count > 1 else { return chains }

        // Group by resulting position on a scratch copy (the live board is never touched).
        let variant = board.variant
        let scratch = GameBoard(config: board.config)
        let start = board.captureStacks()
        var seen: [[[Color]]] = []
        var options: [[HalfMove]] = []
        for chain in chains {
            scratch.restoreStacks(start)
            scratch.undoLog.removeAll()
            for hop in chain {
                variant.applyHalfMove(HalfMove(from: scratch.points[hop.from.position],
                                               to: scratch.points[hop.to.position],
                                               color: hop.color), on: scratch)
            }
            let result = scratch.captureStacks()
            guard !seen.contains(result) else { continue }
            seen.append(result)
            options.append(chain)
        }
        return options
    }

    /// The half-moves of the most recent gesture (see `commit(halfMoves:)`), in the
    /// order they were played. Empty when nothing has been built.
    public var lastGesture: [HalfMove] {
        guard let start = gestureStarts.last else { return [] }
        return Array(built[start...])
    }

    /// Commits the hops of one player gesture (applied to the board by the owner, in
    /// order) so `undoGesture()` can take them back together. Returns whether the move
    /// is now complete, like `commit(halfMove:)`.
    @discardableResult
    public func commit(halfMoves hops: [HalfMove]) -> Bool {
        guard !hops.isEmpty else { return false }
        let start = built.count
        var complete = false
        for hm in hops { complete = commit(halfMove: hm) }
        // `commit(halfMove:)` marked each hop as its own gesture; merge them.
        gestureStarts.removeAll { $0 > start }
        return complete
    }

    /// Undo the whole most recent gesture (the owner reverses `lastGesture` on the
    /// board first, last hop first).
    public func undoGesture() {
        guard let start = gestureStarts.last else { return }
        built.removeLast(built.count - start)
        gestureStarts.removeLast()
        activeMoves = allMoves.filter { remaining(of: $0) != nil }
    }

    /// Commits a half-move and narrows `activeMoves` to the moves whose remaining
    /// bag still contains `hm`. Returns whether the move is now complete (no
    /// surviving move has further half-moves to play). The half-move's board
    /// legality is enforced by the caller before it is applied.
    @discardableResult
    public func commit(halfMove hm: HalfMove) -> Bool {
        activeMoves = activeMoves.filter { m in
            guard let rem = remaining(of: m) else { return false }
            return rem.contains { $0 == hm }
        }
        gestureStarts.append(built.count)
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
    /// against the full (unmerged) legal-move set.
    public func undo() {
        guard !built.isEmpty else { return }
        built.removeLast()
        if let last = gestureStarts.last, last >= built.count { gestureStarts.removeLast() }
        activeMoves = allMoves.filter { remaining(of: $0) != nil }
    }

    /// The composed `Move` matching what has been built so far, if complete.
    public var completedMove: Move? {
        activeMoves.first { remaining(of: $0)?.isEmpty == true }
    }

    // ── Internals ──────────────────────────────────────────────────────────────

    /// Split each merged half-move (a single-checker move of distance `d1 + d2`,
    /// only generated when `d1 != d2`) into one expanded `Move` per open
    /// intermediate stop. Non-merged moves pass through unchanged; on a Pasch
    /// (`d1 == d2`) or with no dice, nothing is split.
    private static func unmerge(_ moves: [Move], board: GameBoard, die1: Int, die2: Int) -> [Move] {
        guard die1 > 0, die2 > 0, die1 != die2 else { return moves }
        let variant = board.variant
        var result: [Move] = []
        for m in moves {
            guard m.halfMoves.count == 1 else { result.append(m); continue }
            let h = m.halfMoves[0]
            // The variant decides whether this is a merged two-dice half and through
            // which midpoints it can legally be split (#137-#139: path geometry, e.g.
            // Fevga Black's wrap, and larger-die bear-off rules live there).
            let mids = variant.intermediatePoints(of: h, die1: die1, die2: die2, on: board)
            guard !mids.isEmpty else { result.append(m); continue }
            for mid in mids {
                result.append(Move([
                    HalfMove(from: board.points[h.from.position], to: board.points[mid], color: h.color),
                    HalfMove(from: board.points[mid], to: board.points[h.to.position], color: h.color),
                ]))
            }
        }
        return result
    }

    /// The half-moves of `m` not yet played: a multiset difference of
    /// `m.halfMoves` minus `built` (by value). `nil` if `built` is not a
    /// sub-multiset of `m` (so `m` is inconsistent with what was played). Ordering
    /// legality needs no re-check here — every committed half-move was board-legal
    /// in real order at commit time.
    private func remaining(of m: Move) -> [HalfMove]? {
        subtract(built, from: m.halfMoves)
    }

    /// `bag` minus one occurrence of each element of `taken`; `nil` if `taken` is
    /// not a sub-multiset of `bag`.
    private func subtract(_ taken: [HalfMove], from bag: [HalfMove]) -> [HalfMove]? {
        var rem = bag
        for t in taken {
            guard let i = rem.firstIndex(where: { $0 == t }) else { return nil }
            rem.remove(at: i)
        }
        return rem
    }

    /// Whether `hm` can be played right now on the live board. Its `from` must
    /// hold a movable checker (or a checker just arrived there via `arrivedAt`, for
    /// a continuation hop whose predecessor isn't applied to the board yet) and its
    /// `to` must be open.
    private func isPlayable(_ hm: HalfMove, arrivedAt: Int?) -> Bool {
        let hasChecker = board.variant.movableCount(at: hm.from.position, for: hm.color, on: board) > 0
            || arrivedAt == hm.from.position
        return hasChecker && board.variant.isOpen(hm.to.position, for: hm.color, on: board)
    }

    /// All endpoints reachable by chaining a single checker from `start` along the
    /// die ray, mapped to the ordered hops that reach each. Follows continuations
    /// of the same checker (a hop whose `from` is the previous hop's `to`), bounded
    /// by what the surviving moves and the board allow.
    private func reachable(from start: Int) -> [Int: [HalfMove]] {
        var paths: [Int: [HalfMove]] = [:]
        extend(from: start, hops: [], into: &paths)
        return paths
    }

    private func extend(from point: Int, hops: [HalfMove], into paths: inout [Int: [HalfMove]]) {
        for hm in nextHops(from: point, taken: hops) {
            let endpoint = hm.to.position
            let chain = hops + [hm]
            if paths[endpoint] == nil { paths[endpoint] = chain }
            extend(from: endpoint, hops: chain, into: &paths)
        }
    }

    /// Every hop chain of a single checker from `point` that ends exactly on `target`
    /// (DFS in the same order as `extend`, so the first chain matches `path`).
    private func collectChains(from point: Int, to target: Int, hops: [HalfMove],
                               into out: inout [[HalfMove]]) {
        for hm in nextHops(from: point, taken: hops) {
            let chain = hops + [hm]
            if hm.to.position == target {
                out.append(chain)
            } else {
                collectChains(from: hm.to.position, to: target, hops: chain, into: &out)
            }
        }
    }

    /// Distinct half-moves (deduped by destination) leaving `point` that are
    /// consistent with some surviving move's remaining bag after `taken` and are
    /// board-legal. For the first hop (`taken` empty) the source must hold a real
    /// checker; for a continuation the checker is the one delivered by the last hop.
    private func nextHops(from point: Int, taken: [HalfMove]) -> [HalfMove] {
        let arrived = taken.last?.to.position
        var result: [HalfMove] = []
        var seen: Set<Int> = []
        for m in activeMoves {
            guard let rem = remaining(of: m), let bag = subtract(taken, from: rem) else { continue }
            for hm in bag where hm.from.position == point && !seen.contains(hm.to.position) {
                guard isPlayable(hm, arrivedAt: arrived) else { continue }
                seen.insert(hm.to.position)
                result.append(hm)
            }
        }
        return result
    }
}
