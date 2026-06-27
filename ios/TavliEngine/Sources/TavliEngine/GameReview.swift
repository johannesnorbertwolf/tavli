import Foundation

/// One human ply, re-evaluated after the game. Ports the per-ply analysis of the
/// CLI's `_collect_blunders` (`play/loop.py`): the position the player faced, the
/// move they played and its score, and the AI's best move and score at the same
/// position. Whether it counts as a *blunder* is a threshold question left to the
/// consumer (`isBlunder(threshold:)`), so the analysis runs once and the UI can
/// filter at any threshold.
public struct PlyEvaluation: Sendable {
    /// 1-based index of this ply within `record.plies`.
    public let plyNumber: Int
    public let die1: Int
    public let die2: Int
    /// The board (per-point stacks, bottom→top) the player faced **before** moving.
    public let boardStacks: [[Color]]
    /// The side that made this move (always the human under review).
    public let mover: Color
    /// The move actually played, as recorded `[from, to]` half-move pairs.
    public let playedMove: [[Int]]
    /// Win probability for `mover` of the played move (1-ply afterstate at `depth`).
    public let playedScore: Float
    /// The AI's best legal move at this position, as `[from, to]` half-move pairs.
    public let bestMove: [[Int]]
    /// Win probability for `mover` of the best move.
    public let bestScore: Float
    /// Whether the position offered a real choice (more than one legal move). When
    /// `false` the ply was forced — a single legal move — so `playedMove == bestMove`
    /// and the UI should label it a no-decision rather than imply the player chose
    /// well. Forced plies are still evaluated and shown so the review timeline runs
    /// unbroken to the final move (#131).
    public let hadChoice: Bool
    /// Search depth this evaluation was scored at. Progressive analysis (#103) emits
    /// each ply first at depth 1, then re-emits it deeper (2, then 3 for the close
    /// calls); consumers key by `plyNumber` and replace with the deeper result.
    public let depth: Int

    public init(plyNumber: Int, die1: Int, die2: Int, boardStacks: [[Color]],
                mover: Color, playedMove: [[Int]], playedScore: Float,
                bestMove: [[Int]], bestScore: Float, hadChoice: Bool = true,
                depth: Int = 2) {
        self.plyNumber = plyNumber
        self.die1 = die1
        self.die2 = die2
        self.boardStacks = boardStacks
        self.mover = mover
        self.playedMove = playedMove
        self.playedScore = playedScore
        self.bestMove = bestMove
        self.bestScore = bestScore
        self.hadChoice = hadChoice
        self.depth = depth
    }

    /// Relative shortfall of the played move vs the best, `(best - played)/best`,
    /// guarding `best == 0`. Mirrors the CLI's relative-gap metric.
    public var relativeGap: Double {
        bestScore > 0 ? Double(bestScore - playedScore) / Double(bestScore) : 0
    }

    /// Absolute win-probability shortfall, in [0, 1].
    public var absoluteGap: Double { Double(max(0, bestScore - playedScore)) }

    /// A blunder when the relative gap meets `threshold` (e.g. 0.10 = 10%) **and**
    /// the played move is at least one percentage point (absolute) below the best —
    /// so a large *relative* miss on a near-even position (e.g. 4.5% vs 5.0%) doesn't
    /// register as a blunder.
    public func isBlunder(threshold: Double) -> Bool {
        bestScore > 0 && relativeGap >= threshold && absoluteGap >= 0.01
    }
}

/// The result of reviewing a finished game: every human ply that actually moved,
/// re-evaluated, in play order — including forced single-legal-move plies (flagged
/// `hadChoice: false`) so the timeline runs unbroken to the final move (#131).
/// `blunders(threshold:)` filters to the ones worth flagging (forced plies have a
/// zero gap and never flag).
public struct GameReviewResult: Sendable {
    public let evaluations: [PlyEvaluation]

    public init(evaluations: [PlyEvaluation]) {
        self.evaluations = evaluations
    }

    /// The evaluated plies whose relative gap meets `threshold`, in play order.
    public func blunders(threshold: Double) -> [PlyEvaluation] {
        evaluations.filter { $0.isBlunder(threshold: threshold) }
    }
}

/// Post-game blunder analysis. The on-device analogue of the CLI's `review`
/// command (`play/loop.py:_handle_review` → `_collect_blunders`): replay the
/// canonical `GameRecord`, and at each human ply re-rank every legal move with the
/// value network to see how far the played move fell short of the best.
public enum GameReview {
    /// Replay `record` and evaluate each human ply.
    ///
    /// Mirrors `_collect_blunders`: a ply is evaluated when it's the human's move and
    /// was not a forced pass. Forced single-legal-move plies are evaluated too (and
    /// marked `hadChoice: false`) so the review reaches the final move — they just
    /// carry a zero gap (#131). Every legal move is ranked at `depth` via
    /// `Agent.evaluateMovesNply` — the same parity-validated multi-ply scoring the
    /// live AI uses, with no wall-clock deadline since analysis is offline. The
    /// board is advanced by replaying the recorded half-moves in place, exactly as
    /// `GameSession.replay` does, so reconstruction is independent of the model.
    ///
    /// `depth` defaults to **2-ply** — fast enough to surface blunders without a long
    /// wait, and the same depth on-device play uses by default (`SearchConfig.maxDepth`).
    ///
    /// - Parameter onEvaluation: called on each evaluated human ply, in play order, as
    ///   soon as it is scored — lets a caller stream results (e.g. show the first
    ///   blunder while the rest are still being analyzed).
    /// - Parameter progress: called as each human ply finishes, with the number
    ///   evaluated so far and the total number that will be evaluated.
    public static func analyze(
        record: GameRecord,
        agent: Agent,
        humanColor: Color,
        depth: Int = 2,
        config: GameConfig = .standard,
        searchConfig: SearchConfig = .standard,
        onEvaluation: (@Sendable (PlyEvaluation) -> Void)? = nil,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) -> GameReviewResult {
        let board = GameBoard(config: config)
        board.initializeBoard()
        let upper = board.boardSize + 1
        let dice = Dice(numberOfSides: config.dieSides)

        // Total human plies that will be evaluated (drives the progress callback).
        let total = humanPlyCount(record: record, humanColor: humanColor)

        var evaluations: [PlyEvaluation] = []
        var done = 0
        var mover = record.startingPlayer

        for (index, ply) in record.plies.enumerated() {
            if mover == humanColor && !ply.halfMoves.isEmpty {
                dice.set(ply.die1, ply.die2)
                let legal = PossibleMoves(board: board, color: mover, dice: dice).findMoves()

                // Evaluate every ply that actually moved, including forced
                // single-legal-move plies (`legal.count == 1`). Those are common in
                // the bear-off endgame; dropping them made the review timeline stop
                // short of the real game end (#131). A forced ply scores its one move
                // (best == played, zero gap) and is flagged `hadChoice: false` so the
                // UI marks it a no-decision rather than implying a good choice.
                if !legal.isEmpty,
                   let scores = try? agent.evaluateMovesNply(
                       board, legal, color: mover, depth: depth,
                       beamThreshold: searchConfig.beamThreshold,
                       relativeCutoff: searchConfig.relativeCutoff,
                       maxBranch: searchConfig.maxBranch,
                       deadline: nil
                   ),
                   let bestIdx = argmax(scores),
                   let playedIdx = matchRecorded(ply.halfMoves, legal) {
                    let evaluation = PlyEvaluation(
                        plyNumber: index + 1,
                        die1: ply.die1,
                        die2: ply.die2,
                        boardStacks: board.captureStacks(),
                        mover: mover,
                        playedMove: ply.halfMoves,
                        playedScore: scores[playedIdx],
                        bestMove: pairs(of: legal[bestIdx]),
                        bestScore: scores[bestIdx],
                        hadChoice: legal.count > 1
                    )
                    evaluations.append(evaluation)
                    onEvaluation?(evaluation)
                }
                done += 1
                progress?(done, total)
            }

            // Advance the board by replaying the recorded half-moves in place
            // (identical to `GameSession.replay`).
            for pair in ply.halfMoves where pair.count == 2 {
                let from = pair[0], to = pair[1]
                guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
                board.points[from].pop()
                board.points[to].push(mover)
            }

            if board.hasWon(mover) { break }
            mover = mover.opponent
        }

        return GameReviewResult(evaluations: evaluations)
    }

    // ── Progressive analysis (#103) ──────────────────────────────────────────────

    /// One human ply, captured during a single replay so the deepening passes can
    /// re-score it without replaying the whole game again. The board is rebuilt from
    /// `boardStacks` on demand (as `Agent.scoreCandidate` does), so no live `Move` or
    /// `Point` reference is held across passes.
    private struct PlyContext {
        let plyNumber: Int
        let die1: Int
        let die2: Int
        let boardStacks: [[Color]]
        let mover: Color
        let playedPairs: [[Int]]
    }

    /// Progressive, deepening analysis (#103). Scores every human ply at **1-ply
    /// first** — so the caller can show the full win-probability graph and a playable
    /// drill immediately — then re-scores in the background at **2-ply**, skipping
    /// plies already clearly lost causes, and finally at **3-ply** for the ones still
    /// too close to call. Each (re)scored ply is streamed via `onEvaluation` with its
    /// current `depth`; the consumer keys by `plyNumber` and replaces shallower
    /// results. `onPassComplete(pass, depth)` fires when a whole pass finishes (pass 0
    /// = the 1-ply base, after which the graph/drill are complete).
    ///
    /// Returns the final, deepest result. Mirrors `analyze`'s per-ply selection and
    /// board reconstruction exactly — only the depth schedule differs.
    /// - Parameter includeOpponent: also evaluate the opponent's (AI's) plies, so the
    ///   review can step through and annotate them too (#132). Opponent plies are
    ///   scored on the 1-ply base pass only — they are not deepened (the precise
    ///   ranking matters for *your* blunders, and deepening both sides would double the
    ///   expensive work). Each evaluation carries its `mover`, so the consumer keeps
    ///   blunder flagging / the drill to the human's own plies.
    public static func analyzeProgressive(
        record: GameRecord,
        agent: Agent,
        humanColor: Color,
        depths: [Int] = [1, 2, 3],
        includeOpponent: Bool = false,
        config: GameConfig = .standard,
        searchConfig: SearchConfig = .standard,
        onEvaluation: (@Sendable (PlyEvaluation) -> Void)? = nil,
        onPassComplete: (@Sendable (_ pass: Int, _ depth: Int) -> Void)? = nil,
        progress: (@Sendable (_ done: Int, _ total: Int, _ pass: Int) -> Void)? = nil
    ) -> GameReviewResult {
        let contexts = replayContexts(record: record, humanColor: humanColor,
                                      config: config, includeOpponent: includeOpponent)
        guard !depths.isEmpty else { return GameReviewResult(evaluations: []) }

        // Current best evaluation per ply, keyed by plyNumber, preserving play order.
        var current: [Int: PlyEvaluation] = [:]
        let order = contexts.map(\.plyNumber)

        for (pass, depth) in depths.enumerated() {
            var done = 0
            for ctx in contexts {
                // The 1-ply base scores every ply (both sides). Deeper passes refine
                // only the human's plies — opponent plies stay at depth 1 (#132).
                let mayDeepen = ctx.mover == humanColor && shouldRefine(current[ctx.plyNumber], pass: pass)
                if pass == 0 || mayDeepen,
                   let eval = evaluate(ctx, agent: agent, depth: depth,
                                       config: config, searchConfig: searchConfig) {
                    current[ctx.plyNumber] = eval
                    onEvaluation?(eval)
                }
                done += 1
                progress?(done, contexts.count, pass)
            }
            onPassComplete?(pass, depth)
        }

        let evaluations = order.compactMap { current[$0] }
        return GameReviewResult(evaluations: evaluations)
    }

    /// Replay the record once, capturing each scored ply's pre-move position. By
    /// default only the human's non-pass plies; with `includeOpponent`, the AI's too.
    private static func replayContexts(record: GameRecord, humanColor: Color,
                                       config: GameConfig,
                                       includeOpponent: Bool = false) -> [PlyContext] {
        let board = GameBoard(config: config)
        board.initializeBoard()
        let upper = board.boardSize + 1
        var contexts: [PlyContext] = []
        var mover = record.startingPlayer

        for (index, ply) in record.plies.enumerated() {
            if !ply.halfMoves.isEmpty, includeOpponent || mover == humanColor {
                contexts.append(PlyContext(
                    plyNumber: index + 1, die1: ply.die1, die2: ply.die2,
                    boardStacks: board.captureStacks(), mover: mover,
                    playedPairs: ply.halfMoves))
            }
            for pair in ply.halfMoves where pair.count == 2 {
                let from = pair[0], to = pair[1]
                guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
                board.points[from].pop()
                board.points[to].push(mover)
            }
            if board.hasWon(mover) { break }
            mover = mover.opponent
        }
        return contexts
    }

    /// Score one captured ply at `depth` against a board rebuilt from its stacks.
    /// Returns `nil` only if the recorded move can't be matched to a legal move
    /// (mirrors `analyze`'s guards), so the ply is simply left at its prior depth.
    private static func evaluate(_ ctx: PlyContext, agent: Agent, depth: Int,
                                 config: GameConfig, searchConfig: SearchConfig) -> PlyEvaluation? {
        let board = GameBoard(config: config)
        for (i, pieces) in ctx.boardStacks.enumerated() where i < board.points.count {
            board.setPoint(i, pieces: pieces)
        }
        let dice = Dice(numberOfSides: config.dieSides)
        dice.set(ctx.die1, ctx.die2)
        let legal = PossibleMoves(board: board, color: ctx.mover, dice: dice).findMoves()
        guard !legal.isEmpty,
              let scores = try? agent.evaluateMovesNply(
                  board, legal, color: ctx.mover, depth: depth,
                  beamThreshold: searchConfig.beamThreshold,
                  relativeCutoff: searchConfig.relativeCutoff,
                  maxBranch: searchConfig.maxBranch, deadline: nil),
              let bestIdx = argmax(scores),
              let playedIdx = matchRecorded(ctx.playedPairs, legal) else { return nil }
        return PlyEvaluation(
            plyNumber: ctx.plyNumber, die1: ctx.die1, die2: ctx.die2,
            boardStacks: ctx.boardStacks, mover: ctx.mover,
            playedMove: ctx.playedPairs, playedScore: scores[playedIdx],
            bestMove: pairs(of: legal[bestIdx]), bestScore: scores[bestIdx],
            hadChoice: legal.count > 1, depth: depth)
    }

    // Deepening cutoffs (#103). Pass 1 (→2-ply) re-scores everything except plies
    // already a clear blunder at the shallower depth (extra depth won't change the
    // verdict). Pass 2 (→3-ply) re-scores only the ones still too close to call —
    // a played-vs-best gap in a band around the 10% blunder threshold.
    private static let clearBlunderRelative = 0.20
    private static let clearBlunderAbsolute = 0.02
    private static let closeBandLowRelative = 0.05
    private static let closeBandHighRelative = 0.15
    private static let closeBandAbsolute = 0.005

    /// Whether a ply currently at `current` warrants re-scoring deeper on `pass`.
    /// `internal` (not `private`) so the cutoff rules can be unit-tested without the
    /// minutes-long model inference a full deepening pass costs.
    static func shouldRefine(_ current: PlyEvaluation?, pass: Int) -> Bool {
        guard let e = current, e.hadChoice else { return false }   // forced ⇒ never deepen
        switch pass {
        case 1:   // → 2-ply: skip the already-clear blunders
            let clearlyBad = e.relativeGap >= clearBlunderRelative
                && e.absoluteGap >= clearBlunderAbsolute
            return !clearlyBad
        case 2:   // → 3-ply: only the borderline calls
            return e.absoluteGap >= closeBandAbsolute
                && e.relativeGap >= closeBandLowRelative
                && e.relativeGap <= closeBandHighRelative
        default:
            return true
        }
    }

    // ── Cached analysis (#104) ───────────────────────────────────────────────────

    /// Rebuild a `GameReviewResult` from a game's **saved** analysis, without the
    /// model (#104). The persisted `AnalysisEntry`s carry the scores but not the bulky
    /// pre-move `boardStacks`, so this replays `record` once to recover each scored
    /// ply's position/dice/mover (exactly as `replayContexts` does) and merges them
    /// with the stored scores. The result is interchangeable with a freshly computed
    /// one — the review pager and the drill (which both need `boardStacks`) consume it
    /// unchanged — so a second review/drill of the same game skips re-analysis.
    ///
    /// Entries whose ply can't be located in the replay (a malformed/cleared log) are
    /// dropped, mirroring the per-ply guards in `analyze`. `hadChoice` is recomputed
    /// exactly from the legal moves at the replayed position (model-free),
    /// so it matches the live analysis — a ply where you played the best is still a
    /// real choice, not mislabeled "forced".
    public static func cachedResult(record: GameRecord,
                                    analysis: [AnalysisEntry],
                                    config: GameConfig = .standard) -> GameReviewResult {
        // Replaying with `includeOpponent` captures both sides, so an analysis that
        // annotated the opponent's plies (#132) rebuilds in full too.
        let contexts = replayContexts(record: record, humanColor: record.aiColor?.opponent ?? .white,
                                      config: config, includeOpponent: true)
        let byPly = Dictionary(contexts.map { ($0.plyNumber, $0) }, uniquingKeysWith: { a, _ in a })

        let evaluations: [PlyEvaluation] = analysis.compactMap { entry in
            guard let ctx = byPly[entry.plyNumber] else { return nil }
            return PlyEvaluation(
                plyNumber: entry.plyNumber, die1: ctx.die1, die2: ctx.die2,
                boardStacks: ctx.boardStacks, mover: ctx.mover,
                playedMove: entry.playedMove, playedScore: Float(entry.playedScore),
                bestMove: entry.bestMove, bestScore: Float(entry.bestScore),
                hadChoice: legalMoveCount(ctx, config: config) > 1, depth: entry.depth)
        }
        return GameReviewResult(evaluations: evaluations.sorted { $0.plyNumber < $1.plyNumber })
    }

    /// Number of legal moves at a replayed ply's position — the exact `hadChoice`
    /// signal, rebuilt from the move history with no model (move generation only).
    private static func legalMoveCount(_ ctx: PlyContext, config: GameConfig) -> Int {
        let board = GameBoard(config: config)
        for (i, pieces) in ctx.boardStacks.enumerated() where i < board.points.count {
            board.setPoint(i, pieces: pieces)
        }
        let dice = Dice(numberOfSides: config.dieSides)
        dice.set(ctx.die1, ctx.die2)
        return PossibleMoves(board: board, color: ctx.mover, dice: dice).findMoves().count
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    /// Number of human plies that `analyze` will evaluate: the human's own,
    /// non-pass plies — forced single-legal-move plies included, since those are now
    /// evaluated too (#131). A cheap, replay-free pass that matches the emitted count.
    private static func humanPlyCount(record: GameRecord, humanColor: Color) -> Int {
        var mover = record.startingPlayer
        var count = 0
        for ply in record.plies {
            if mover == humanColor && !ply.halfMoves.isEmpty { count += 1 }
            mover = mover.opponent
        }
        return count
    }

    /// Index of the maximum score (ties → lowest index), or nil when empty.
    private static func argmax(_ scores: [Float]) -> Int? {
        guard !scores.isEmpty else { return nil }
        var best = 0
        for i in 1..<scores.count where scores[i] > scores[best] { best = i }
        return best
    }

    /// The `[from, to]` half-move pairs of a move, in stored order.
    private static func pairs(of move: Move) -> [[Int]] {
        move.halfMoves.map { [$0.from.position, $0.to.position] }
    }

    /// Index of the legal move with the same **net board effect** as `recorded`. The
    /// move generator collapses a single checker's two-die move into one merged hop
    /// (e.g. `13→4`), while the UI records the two stepped hops the player tapped
    /// (`13→7→4`); comparing raw `(from,to)` pairs misses that, silently dropping the
    /// ply (the "missing moves" bug — #132 made it visible). Matching by net delta
    /// (which points lose/gain a checker) is robust to *how* the move was split, and
    /// since the afterstate — and thus the score — depends only on that delta, it's
    /// the correct key.
    private static func matchRecorded(_ recorded: [[Int]], _ moves: [Move]) -> Int? {
        let target = netDelta(recorded)
        for (i, move) in moves.enumerated() where netDelta(pairs(of: move)) == target {
            return i
        }
        return nil
    }

    /// Net change a move makes to the board: `point → checker delta` (each `from`
    /// loses one, each `to` gains one), with intermediate hop points cancelling to
    /// zero and dropping out. `13→4` and `13→7→4` both yield `{13: -1, 4: +1}`.
    private static func netDelta(_ pairs: [[Int]]) -> [Int: Int] {
        var delta: [Int: Int] = [:]
        for p in pairs where p.count == 2 {
            delta[p[0], default: 0] -= 1
            delta[p[1], default: 0] += 1
        }
        return delta.filter { $0.value != 0 }
    }
}

public extension Agent {
    /// Win probability for `mover` of a single candidate move at `position`
    /// (`boardStacks`), scored at `depth` — the public entry the post-game drill
    /// (#63) uses to grade an attempt. Builds an **isolated** board from the stacks
    /// and reconstructs the move against it (the attempt's own `Move` references the
    /// live drill board, which the main actor keeps reading), so it is safe to call
    /// off the main actor. The score is identical to that move's entry in a full
    /// `evaluateMovesNply` ranking — i.e. directly comparable to a `PlyEvaluation`'s
    /// `bestScore`.
    func scoreCandidate(boardStacks: [[Color]],
                        move pairs: [[Int]],
                        mover: Color,
                        depth: Int = 2,
                        config: GameConfig = .standard,
                        searchConfig: SearchConfig = .standard) throws -> Float {
        let board = GameBoard(config: config)
        for (i, pieces) in boardStacks.enumerated() where i < board.points.count {
            board.setPoint(i, pieces: pieces)
        }
        let halves = pairs.compactMap { pair -> HalfMove? in
            guard pair.count == 2 else { return nil }
            return HalfMove(from: board.points[pair[0]], to: board.points[pair[1]], color: mover)
        }
        return try evaluateMovesNply(
            board, [Move(halves)], color: mover, depth: depth,
            beamThreshold: searchConfig.beamThreshold,
            relativeCutoff: searchConfig.relativeCutoff,
            maxBranch: searchConfig.maxBranch,
            deadline: nil
        )[0]
    }
}
