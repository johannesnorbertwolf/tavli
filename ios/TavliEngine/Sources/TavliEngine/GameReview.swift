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

    public init(plyNumber: Int, die1: Int, die2: Int, boardStacks: [[Color]],
                mover: Color, playedMove: [[Int]], playedScore: Float,
                bestMove: [[Int]], bestScore: Float) {
        self.plyNumber = plyNumber
        self.die1 = die1
        self.die2 = die2
        self.boardStacks = boardStacks
        self.mover = mover
        self.playedMove = playedMove
        self.playedScore = playedScore
        self.bestMove = bestMove
        self.bestScore = bestScore
    }

    /// Relative shortfall of the played move vs the best, `(best - played)/best`,
    /// guarding `best == 0`. Mirrors the CLI's relative-gap metric.
    public var relativeGap: Double {
        bestScore > 0 ? Double(bestScore - playedScore) / Double(bestScore) : 0
    }

    /// Absolute win-probability shortfall, in [0, 1].
    public var absoluteGap: Double { Double(max(0, bestScore - playedScore)) }

    /// A blunder when the relative gap meets `threshold` (e.g. 0.10 = 10%).
    public func isBlunder(threshold: Double) -> Bool {
        bestScore > 0 && relativeGap >= threshold
    }
}

/// The result of reviewing a finished game: every human ply that offered a real
/// choice (more than one legal move), re-evaluated. `blunders(threshold:)` filters
/// to the ones worth flagging.
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
    /// Mirrors `_collect_blunders`: a ply is evaluated only when it's the human's
    /// move, was not a forced pass, and offered more than one legal move (a single
    /// legal move is no decision). Every legal move is ranked at `depth` via
    /// `Agent.evaluateMovesNply` — the same parity-validated multi-ply scoring the
    /// live AI uses, with no wall-clock deadline since analysis is offline. The
    /// board is advanced by replaying the recorded half-moves in place, exactly as
    /// `GameSession.replay` does, so reconstruction is independent of the model.
    ///
    /// - Parameter progress: called as each human ply finishes, with the number
    ///   evaluated so far and the total number that will be evaluated.
    public static func analyze(
        record: GameRecord,
        agent: Agent,
        humanColor: Color,
        depth: Int = 3,
        config: GameConfig = .standard,
        searchConfig: SearchConfig = .standard,
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

                // A single legal move is no decision (matches `len(moves) <= 1`).
                if legal.count > 1,
                   let scores = try? agent.evaluateMovesNply(
                       board, legal, color: mover, depth: depth,
                       beamThreshold: searchConfig.beamThreshold,
                       relativeCutoff: searchConfig.relativeCutoff,
                       maxBranch: searchConfig.maxBranch,
                       deadline: nil
                   ),
                   let bestIdx = argmax(scores),
                   let playedIdx = matchRecorded(ply.halfMoves, legal) {
                    evaluations.append(PlyEvaluation(
                        plyNumber: index + 1,
                        die1: ply.die1,
                        die2: ply.die2,
                        boardStacks: board.captureStacks(),
                        mover: mover,
                        playedMove: ply.halfMoves,
                        playedScore: scores[playedIdx],
                        bestMove: pairs(of: legal[bestIdx]),
                        bestScore: scores[bestIdx]
                    ))
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

    // ── Helpers ────────────────────────────────────────────────────────────────

    /// Number of human plies that `analyze` will evaluate: the human's own,
    /// non-pass plies. (Single-legal-move plies are still counted here — they are
    /// only skipped during scoring, which doesn't change the progress denominator
    /// materially and keeps this a cheap, replay-free pass.)
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

    /// Index of the legal move whose half-moves match `recorded`, comparing the
    /// `(from, to)` pairs as a multiset (order-independent — the recorded order
    /// from `MoveBuilder` may differ from the generator's). The Swift analogue of
    /// the CLI's structural `_pairs`/`_find` matching.
    private static func matchRecorded(_ recorded: [[Int]], _ moves: [Move]) -> Int? {
        let target = sortedPairs(recorded)
        for (i, move) in moves.enumerated() where sortedPairs(pairs(of: move)) == target {
            return i
        }
        return nil
    }

    /// Canonical (sorted) form of a pair list, for order-independent comparison.
    private static func sortedPairs(_ pairs: [[Int]]) -> [[Int]] {
        pairs.filter { $0.count == 2 }
            .sorted { $0[0] != $1[0] ? $0[0] < $1[0] : $0[1] < $1[1] }
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
                        depth: Int = 3,
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
