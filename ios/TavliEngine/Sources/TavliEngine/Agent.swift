import Foundation
import Dispatch
import CoreML

/// One of the 21 distinct unordered dice rolls and its probability weight
/// (doubles 1/36, the rest 2/36). Computed once; mirrors `_DICE_OUTCOMES` in
/// `ai/agent.py`.
struct DiceOutcome { let d1: Int; let d2: Int; let weight: Float }

let diceOutcomes: [DiceOutcome] = {
    let n = 6
    var out: [DiceOutcome] = []
    for i in 1...n {
        for j in i...n {
            let w = Float(i == j ? 1 : 2) / Float(n * n)
            out.append(DiceOutcome(d1: i, d2: j, weight: w))
        }
    }
    return out
}()

/// Thrown to unwind the expectimax recursion when the search deadline expires.
/// Callers discard the partial result and keep the last fully completed depth.
struct SearchTimeout: Error {}

/// Core ML-backed move selector. Mirrors `ai/agent.py`:
/// - 1-ply (`evaluateMoves`): apply each candidate; an immediate win scores 1.0,
///   otherwise score the afterstate from the opponent's perspective as `1 - opponentValue`.
/// - multi-ply (`getBestMove` with a `timeBudget`): iterative-deepening beam
///   expectimax over the 21 dice outcomes, with relative-cutoff + max-branch pruning.
///
/// `@unchecked Sendable`: the only stored state is the immutable encoder/config and
/// an `MLModel` (thread-safe for concurrent `prediction(from:)`); `encode`/`value`
/// allocate fresh per call. Safe to call from a background search task while the
/// main actor scores the live board through a *separate* `GameBoard`.
public final class Agent: @unchecked Sendable {
    private let model: MLModel
    private let encoder: BoardEncoder
    private let inputName: String
    private let outputName: String
    private let inputSize: Int

    public init(model: MLModel, encoder: BoardEncoder) {
        self.model = model
        self.encoder = encoder
        self.inputSize = encoder.inputSize
        // Resolve feature names from the model so we don't couple to the converter.
        self.inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "board"
        self.outputName = model.modelDescription.outputDescriptionsByName.keys.first ?? "win_prob"
    }

    /// Win probability for the side whose turn it is in the encoded position.
    public func value(_ encoding: [Float]) throws -> Float {
        let arr = try MLMultiArray(shape: [1, NSNumber(value: inputSize)], dataType: .float32)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: inputSize)
        for i in 0..<inputSize { ptr[i] = encoding[i] }
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: arr)])
        let out = try model.prediction(from: provider)
        guard let mv = out.featureValue(for: outputName)?.multiArrayValue else {
            throw NSError(domain: "Agent", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "missing output \(outputName)"])
        }
        return mv[0].floatValue
    }

    /// Win probability for `color` in the given static board (no move applied).
    public func winProbability(_ board: GameBoard, color: Color) throws -> Float {
        try value(encoder.encode(board, isWhitesTurn: color.isWhite))
    }

    /// 1-ply score per candidate move, aligned to `moves`.
    ///
    /// Scoring apply/undoes each candidate on the shared live board. The outer
    /// `defer` restores the exact pre-scoring stacks no matter how the loop exits —
    /// a thrown Core ML error, an early return, or a future change that forgets an
    /// undo — so analysis can never leave the game position corrupted.
    public func evaluateMoves(_ board: GameBoard, _ moves: [Move], color: Color) throws -> [Float] {
        let opponentToMoveIsWhite = !color.isWhite
        let saved = board.captureStacks()
        defer { board.restoreStacks(saved) }
        var scores = [Float](repeating: 0, count: moves.count)
        for (idx, move) in moves.enumerated() {
            board.apply(move)
            if board.hasWon(color) {
                scores[idx] = 1.0
            } else {
                let enc = encoder.encode(board, isWhitesTurn: opponentToMoveIsWhite)
                scores[idx] = 1.0 - (try value(enc))
            }
            board.undo(move)
        }
        return scores
    }

    /// Index of the first maximal score (ties resolve to the earliest, matching
    /// Python's `max(range, key=...)`).
    private static func argmax(_ scores: [Float]) -> Int {
        var best = 0
        for i in 1..<scores.count where scores[i] > scores[best] { best = i }
        return best
    }

    /// Indices of the moves to expand, best-first. Mirrors `_prune_branches` in
    /// `ai/agent.py`: keep `score >= best*(1-relativeCutoff)` when a relative cutoff
    /// is set, else `score >= best - beamThreshold`; sort by score desc (ties by
    /// original index, matching Python's stable sort); cap to `maxBranch`; always
    /// keep at least one.
    static func pruneBranches(
        scores: [Float],
        beamThreshold: Float,
        relativeCutoff: Float?,
        maxBranch: Int?
    ) -> [Int] {
        guard let best = scores.max() else { return [] }
        let keep = relativeCutoff.map { best * (1 - $0) } ?? (best - beamThreshold)
        let order = scores.indices.sorted {
            scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1
        }
        var survivors = order.filter { scores[$0] >= keep }
        if survivors.isEmpty { survivors = [order[0]] }
        if let maxBranch, survivors.count > maxBranch {
            survivors = Array(survivors.prefix(maxBranch))
        }
        return survivors
    }

    /// Recursive expectimax with beam pruning at opponent branches. Mirrors
    /// `_evaluate_moves_nply` in `ai/agent.py`.
    ///
    /// `depth <= 1` delegates to `evaluateMoves` (1-ply). At `depth > 1`, for each
    /// candidate it iterates all 21 dice outcomes; opponent replies are 1-ply
    /// pre-screened, pruned via `pruneBranches`, then recursed at `depth-1`. The
    /// dice chance-nodes are never pruned (the distribution stays exact). A
    /// pass-position (no opponent moves) is scored from our own perspective.
    ///
    /// Each candidate's apply is paired with a `defer`-undo so the board is restored
    /// even when a `SearchTimeout` unwinds the recursion from a deeper frame.
    func evaluateMovesNply(
        _ board: GameBoard,
        _ moves: [Move],
        color: Color,
        depth: Int,
        beamThreshold: Float,
        relativeCutoff: Float?,
        maxBranch: Int?,
        deadline: DispatchTime?
    ) throws -> [Float] {
        if depth <= 1 {
            return try evaluateMoves(board, moves, color: color)
        }

        let opponentColor = color.opponent
        let isOurTurn = color.isWhite
        let dice = Dice()
        var scores: [Float] = []
        scores.reserveCapacity(moves.count)

        for candidate in moves {
            board.apply(candidate)
            defer { board.undo(candidate) }

            if board.hasWon(color) {
                scores.append(1.0)
                continue
            }

            var expected: Float = 0
            for outcome in diceOutcomes {
                if let deadline, DispatchTime.now() > deadline { throw SearchTimeout() }

                dice.set(outcome.d1, outcome.d2)
                let oppMoves = PossibleMoves(board: board, color: opponentColor, dice: dice).findMoves()

                if oppMoves.isEmpty {
                    // Opponent passes: position unchanged, our turn again.
                    let v = try value(encoder.encode(board, isWhitesTurn: isOurTurn))
                    expected += outcome.weight * v
                    continue
                }

                let oppScreen = try evaluateMoves(board, oppMoves, color: opponentColor)
                let surviving = Self.pruneBranches(
                    scores: oppScreen, beamThreshold: beamThreshold,
                    relativeCutoff: relativeCutoff, maxBranch: maxBranch
                ).map { oppMoves[$0] }

                let oppDeep = try evaluateMovesNply(
                    board, surviving, color: opponentColor, depth: depth - 1,
                    beamThreshold: beamThreshold, relativeCutoff: relativeCutoff,
                    maxBranch: maxBranch, deadline: deadline
                )
                expected += outcome.weight * (1 - oppDeep.max()!)
            }
            scores.append(expected)
        }
        return scores
    }

    /// Iterative-deepening beam expectimax under a wall-clock budget. Mirrors the
    /// time-budget path of `get_best_move` in `ai/agent.py`.
    ///
    /// Depth 1 scores all root moves; the loop then deepens while the deadline holds
    /// and `depth <= maxDepth`, re-scoring only the pruned root candidates and
    /// keeping prior-depth scores for the rest. A `SearchTimeout` mid-depth discards
    /// that depth's partial result and returns the last fully completed depth's best.
    /// Returns the chosen move with its score, its index into `moves` (so a caller
    /// holding an equivalent move list can map back), and the depth actually reached.
    public func getBestMove(
        _ board: GameBoard,
        _ moves: [Move],
        color: Color,
        timeBudget: TimeInterval,
        beamThreshold: Float = 0.08,
        relativeCutoff: Float? = nil,
        maxBranch: Int? = nil,
        maxDepth: Int? = nil
    ) throws -> (move: Move, score: Float, index: Int, depth: Int)? {
        guard !moves.isEmpty else { return nil }
        if moves.count == 1 { return (moves[0], 0.0, 0, 1) }

        let deadline = DispatchTime.now() + timeBudget

        var bestScores = try evaluateMoves(board, moves, color: color)
        var bestIdx = Self.argmax(bestScores)
        var reachedDepth = 1

        var depth = 2
        while DispatchTime.now() < deadline {
            if let maxDepth, depth > maxDepth { break }

            let candidateIndices = Self.pruneBranches(
                scores: bestScores, beamThreshold: beamThreshold,
                relativeCutoff: relativeCutoff, maxBranch: maxBranch
            )
            let candidateMoves = candidateIndices.map { moves[$0] }

            let partial: [Float]
            do {
                partial = try evaluateMovesNply(
                    board, candidateMoves, color: color, depth: depth,
                    beamThreshold: beamThreshold, relativeCutoff: relativeCutoff,
                    maxBranch: maxBranch, deadline: deadline
                )
            } catch is SearchTimeout {
                break  // discard partial results, keep previous depth's best
            }

            for (j, i) in candidateIndices.enumerated() { bestScores[i] = partial[j] }
            bestIdx = Self.argmax(bestScores)
            reachedDepth = depth
            depth += 1
        }

        return (moves[bestIdx], bestScores[bestIdx], bestIdx, reachedDepth)
    }
}
