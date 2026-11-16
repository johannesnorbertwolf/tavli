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
/// **Legal play order (#169 follow-up).** The bag alone would accept a legal move's
/// halves in *any* order, including orders no player could legally play (Portes: move
/// another checker before entering from the bar; any variant: bear off before the last
/// checker is home; a larger-die bear-off before the checker behind has moved; Fevga:
/// a second checker leaving the start under the first-checker lock). So each play is
/// also checked against the variant's `isLegalStep` at the position it is played, for
/// one of the dice still unplayed (`diceStates`, tracked per built half-move). Chains
/// to far endpoints are simulated on a scratch board so every hop is judged at its
/// own position. Without dice (`die1 == 0`) only board playability is checked.
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

    /// The turn's dice as single plays (`[d1, d2]`, or four of a double); empty when
    /// the builder was made without dice (then only board playability is checked).
    private let dice: [Int]
    /// The position at construction (turn start), replayed to evaluate each commit.
    private let startStacks: [[Color]]
    /// `diceStates[i]`: the possible multisets (sorted) of dice still unplayed after
    /// the first `i` built half-moves. A set because a bear-off may be played by more
    /// than one die value.
    private var diceStates: [Set<[Int]>]

    public init(legalMoves: [Move], board: GameBoard, die1: Int = 0, die2: Int = 0) {
        let expanded = MoveBuilder.unmerge(legalMoves, board: board, die1: die1, die2: die2)
        self.allMoves = expanded
        self.activeMoves = expanded
        self.board = board
        if die1 > 0, die2 > 0 {
            dice = die1 == die2 ? [die1, die1, die1, die1] : [min(die1, die2), max(die1, die2)]
        } else {
            dice = []
        }
        startStacks = board.captureStacks()
        diceStates = [[dice]]
    }

    /// Points a checker may be picked up FROM for the next half-move.
    public var selectableSourcePoints: Set<Int> {
        var sources: Set<Int> = []
        var checked: [HalfMoveKey: Bool] = [:]
        let states = diceStates[built.count]
        for m in activeMoves {
            guard let rem = remaining(of: m) else { continue }
            for hm in rem where !sources.contains(hm.from.position) {
                let key = HalfMoveKey(hm)
                let ok = checked[key] ?? !advance(states, by: hm, on: board).isEmpty
                checked[key] = ok
                if ok { sources.insert(hm.from.position) }
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
        let all = chains(from: fromPosition).filter { $0.hops.last?.to.position == toPosition }
        guard let shortest = all.map(\.hops.count).min() else { return [] }
        var seen: [[[Color]]] = []
        var options: [[HalfMove]] = []
        for chain in all where chain.hops.count == shortest && !seen.contains(chain.result) {
            seen.append(chain.result)
            options.append(chain.hops)
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
        diceStates.removeLast(diceStates.count - built.count - 1)
        activeMoves = allMoves.filter { remaining(of: $0) != nil }
    }

    /// Commits a half-move and narrows `activeMoves` to the moves whose remaining
    /// bag still contains `hm`. Returns whether the move is now complete (no
    /// surviving move has further half-moves to play). The half-move's board
    /// legality is enforced by the caller before it is applied.
    @discardableResult
    public func commit(halfMove hm: HalfMove) -> Bool {
        // Which dice this play consumed, judged at the position before it (turn start
        // replayed through `built`, so it does not matter whether the owner applied it yet).
        let states = diceStates[built.count]
        let next = advance(states, by: hm, on: replayedBoard())
        diceStates.append(next.isEmpty ? states : next)   // unchecked commit: dice left as is
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
        diceStates.removeLast()
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

    /// Hashable identity of a half-move by value.
    private struct HalfMoveKey: Hashable {
        let from: Int, to: Int, white: Bool
        init(_ hm: HalfMove) { from = hm.from.position; to = hm.to.position; white = hm.color.isWhite }
    }

    /// The dice states after playing `hm` at position `b` from `states`; empty when
    /// `hm` is not a legal single play there. Board playability (movable source, open
    /// target) always applies; with dice, the variant's `isLegalStep` must accept `hm`
    /// for one of the unplayed dice — so a legal move's half-moves are only accepted in
    /// an order that is itself a legal sequence of plays (Portes bar-first, bear-off
    /// only once every checker is home, larger-die bear-off, Fevga's first-checker lock).
    private func advance(_ states: Set<[Int]>, by hm: HalfMove, on b: GameBoard) -> Set<[Int]> {
        let v = b.variant
        let from = hm.from.position, to = hm.to.position
        guard v.movableCount(at: from, for: hm.color, on: b) > 0,
              v.isOpen(to, for: hm.color, on: b) else { return [] }
        guard !dice.isEmpty else { return states }
        var out = Set<[Int]>()
        for s in states {
            for d in Set(s) where v.isLegalStep(from: from, to: to, color: hm.color, die: d, on: b) {
                var r = s
                r.remove(at: r.firstIndex(of: d)!)
                out.insert(r)
            }
        }
        if out.isEmpty {
            // A merged two-dice half the variant did not split: it plays every die left.
            let n = b.boardSize
            let dist = v.pathIndex(of: to, for: hm.color, boardSize: n)
                - v.pathIndex(of: from, for: hm.color, boardSize: n)
            for s in states where s.count > 1 && s.reduce(0, +) == dist { out.insert([]) }
        }
        return out
    }

    /// A scratch board holding `position` (the live board is never touched).
    private func scratch(_ position: [[Color]]) -> GameBoard {
        let b = GameBoard(config: board.config)
        b.restoreStacks(position)
        return b
    }

    /// The turn-start position with `built` replayed: the position before the next play.
    private func replayedBoard() -> GameBoard {
        let b = scratch(startStacks)
        for hm in built { apply(hm, on: b) }
        return b
    }

    private func apply(_ hm: HalfMove, on b: GameBoard) {
        b.variant.applyHalfMove(HalfMove(from: b.points[hm.from.position], to: b.points[hm.to.position],
                                         color: hm.color), on: b)
    }

    private func unapply(_ hm: HalfMove, on b: GameBoard) {
        b.variant.undoHalfMove(HalfMove(from: b.points[hm.from.position], to: b.points[hm.to.position],
                                        color: hm.color), on: b)
    }

    /// Every chain of plays of the single checker on `start` — each a prefix of some
    /// surviving move's remaining bag, each step legal at the position it is played
    /// (simulated on a scratch board) — in DFS preorder, with the position it leads to.
    private func chains(from start: Int) -> [(hops: [HalfMove], result: [[Color]])] {
        var out: [(hops: [HalfMove], result: [[Color]])] = []
        let b = scratch(board.captureStacks())
        walk(from: start, hops: [], states: diceStates[built.count], on: b, into: &out)
        return out
    }

    private func walk(from point: Int, hops: [HalfMove], states: Set<[Int]>, on b: GameBoard,
                      into out: inout [(hops: [HalfMove], result: [[Color]])]) {
        for (hm, next) in nextHops(from: point, taken: hops, states: states, on: b) {
            let chain = hops + [hm]
            apply(hm, on: b)
            out.append((chain, b.captureStacks()))
            walk(from: hm.to.position, hops: chain, states: next, on: b, into: &out)
            unapply(hm, on: b)
        }
    }

    /// All endpoints reachable by chaining a single checker from `start`, mapped to the
    /// ordered hops of the first chain found to each.
    private func reachable(from start: Int) -> [Int: [HalfMove]] {
        var paths: [Int: [HalfMove]] = [:]
        for c in chains(from: start) {
            let end = c.hops[c.hops.count - 1].to.position
            if paths[end] == nil { paths[end] = c.hops }
        }
        return paths
    }

    /// Distinct half-moves (deduped by destination) leaving `point` that are
    /// consistent with some surviving move's remaining bag after `taken` and are a
    /// legal play at position `b` (which already has `taken` applied), each with the
    /// dice states after it.
    private func nextHops(from point: Int, taken: [HalfMove], states: Set<[Int]>,
                          on b: GameBoard) -> [(HalfMove, Set<[Int]>)] {
        var result: [(HalfMove, Set<[Int]>)] = []
        var seen: Set<Int> = []
        for m in activeMoves {
            guard let rem = remaining(of: m), let bag = subtract(taken, from: rem) else { continue }
            for hm in bag where hm.from.position == point && !seen.contains(hm.to.position) {
                seen.insert(hm.to.position)
                let next = advance(states, by: hm, on: b)
                if !next.isEmpty { result.append((hm, next)) }
            }
        }
        return result
    }
}
