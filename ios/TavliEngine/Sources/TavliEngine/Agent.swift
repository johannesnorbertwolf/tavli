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

/// Deterministic, seedable RNG (SplitMix64, Steele et al.) for reproducible
/// move-selection noise in tests (#108). Real play uses `SystemRandomNumberGenerator`.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

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

    /// Pick the index to play from `scores` (#108 difficulty). With `noise <= 0` this is the
    /// plain argmax (ties → lowest index), identical to full-strength selection. With
    /// `noise > 0` it adds iid Gaussian(0, noise) to each score and takes the argmax of the
    /// perturbed values, so a weaker opponent occasionally passes up its best move. `seed`
    /// pins the RNG for tests; `nil` uses the system RNG.
    static func selectIndex(_ scores: [Float], noise: Float, seed: UInt64?) -> Int {
        guard noise > 0, scores.count > 1 else { return argmax(scores) }
        if let seed {
            var rng = SplitMix64(seed: seed)
            return noisyArgmax(scores, sigma: noise, using: &rng)
        } else {
            var rng = SystemRandomNumberGenerator()
            return noisyArgmax(scores, sigma: noise, using: &rng)
        }
    }

    /// Argmax over `scores`, ties → lowest index.
    static func argmax(_ scores: [Float]) -> Int {
        var b = 0
        for i in scores.indices where scores[i] > scores[b] { b = i }
        return b
    }

    private static func noisyArgmax<G: RandomNumberGenerator>(
        _ scores: [Float], sigma: Float, using rng: inout G
    ) -> Int {
        var bestI = 0
        var bestV = -Float.greatestFiniteMagnitude
        for i in scores.indices {
            let v = scores[i] + sigma * gaussian(using: &rng)
            if v > bestV { bestV = v; bestI = i }
        }
        return bestI
    }

    /// One standard-normal sample via Box–Muller.
    private static func gaussian<G: RandomNumberGenerator>(using rng: inout G) -> Float {
        let u1 = Double.random(in: Double.leastNonzeroMagnitude...1, using: &rng)
        let u2 = Double.random(in: 0...1, using: &rng)
        return Float((-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2))
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

    /// Best-first search with a **2-ply baseline** and anytime deepening under a
    /// wall-clock budget. This is the on-device search strategy and intentionally
    /// diverges from the CLI's plain iterative-deepening `get_best_move` in
    /// `ai/agent.py`: only the time/branch *policy* differs — the leaf scoring
    /// (`evaluateMoves`) and the deeper recursion (`evaluateMovesNply`) are the
    /// parity-validated port, so move evaluation still matches Python exactly.
    ///
    /// Strategy:
    /// 1. **1-ply** score every root move; keep the best-first candidate set within
    ///    `relativeCutoff`, capped at `maxRootBranches`.
    /// 2. **2-ply baseline** — score the whole candidate set at depth 2. This is the
    ///    guaranteed floor: cheap, (almost) always completes, and gives the move
    ///    ordering for the next step. Its best is the answer if `maxDepth <= 2` or if
    ///    deepening can't finish a single branch.
    /// 3. **Deepen to `maxDepth`** (anytime) — re-score candidates one at a time, in
    ///    2-ply order, overwriting their baseline score with the deeper score:
    ///    - always deepen at least `minRootBranches` (subject to the `timeBudget` hard cap), then
    ///    - keep widening up to `maxRootBranches` total **only while elapsed < `rootSoftBudget`**.
    ///    Inside each branch the 2nd/3rd levels prune to `maxBranch`.
    /// 4. Return the argmax over the (mixed 2-ply / deepened) candidate scores.
    ///
    /// So cheap positions deepen the whole candidate set in well under the soft budget,
    /// while a hugely-branching doubles roll still returns a complete 2-ply result plus
    /// a genuine `maxDepth` evaluation of its best moves within `timeBudget`. A
    /// `SearchTimeout` (hard cap hit mid-branch) keeps the best result so far; if not
    /// even the 2-ply baseline finishes, the 1-ply best is returned (`depth = 1`).
    /// Returns the chosen move, its score, its index into `moves`, and the depth reached.
    ///
    /// **Difficulty (#108).** `selectionNoise` (σ) only takes effect in the 1-ply path the
    /// strength slider drops to below full strength: it adds iid Gaussian(0, σ) to every
    /// move's 1-ply score before the argmax, so a weaker opponent sometimes plays a
    /// non-best move. σ = 0 is the unchanged full-strength argmax. `noiseSeed` makes the
    /// perturbation reproducible for tests (nil → the system RNG in real play). The 2-ply+
    /// path is unaffected — the slider only ever pairs deeper search with σ = 0.
    public func getBestMove(
        _ board: GameBoard,
        _ moves: [Move],
        color: Color,
        timeBudget: TimeInterval,
        beamThreshold: Float = 0.08,
        relativeCutoff: Float? = nil,
        maxBranch: Int? = nil,
        maxDepth: Int? = nil,
        rootSoftBudget: TimeInterval = 8.0,
        minRootBranches: Int = 2,
        maxRootBranches: Int = 5,
        selectionNoise: Float = 0,
        noiseSeed: UInt64? = nil
    ) throws -> (move: Move, score: Float, index: Int, depth: Int)? {
        guard !moves.isEmpty else { return nil }
        if moves.count == 1 { return (moves[0], 0.0, 0, 1) }

        let hardDeadline = DispatchTime.now() + timeBudget
        let softDeadline = DispatchTime.now() + rootSoftBudget

        // 1-ply score for every root move → best-first candidate set, capped.
        let rootScores = try evaluateMoves(board, moves, color: color)
        let candidates = Self.pruneBranches(
            scores: rootScores, beamThreshold: beamThreshold,
            relativeCutoff: relativeCutoff, maxBranch: maxRootBranches
        )   // indices into `moves`, best-first

        // argmax over candidate scores (ties → lowest move index), returns a position in `candidates`.
        func bestPosition(_ scores: [Float]) -> Int {
            var b = 0
            for i in 1..<scores.count
            where scores[i] > scores[b] || (scores[i] == scores[b] && candidates[i] < candidates[b]) {
                b = i
            }
            return b
        }

        let targetDepth = maxDepth ?? 3
        guard targetDepth > 1 else {
            // 1-ply play — the strength the slider drops to below full strength (#108).
            // Select over **all** moves (not the pruned candidate set) so the noise can
            // reach any legal reply; σ = 0 is the plain global 1-ply argmax (unchanged).
            let idx = Self.selectIndex(rootScores, noise: selectionNoise, seed: noiseSeed)
            return (moves[idx], rootScores[idx], idx, 1)
        }

        // Step 2 — 2-ply baseline over the whole candidate set (the guaranteed floor).
        var scores: [Float]
        do {
            scores = try evaluateMovesNply(
                board, candidates.map { moves[$0] }, color: color, depth: 2,
                beamThreshold: beamThreshold, relativeCutoff: relativeCutoff,
                maxBranch: maxBranch, deadline: hardDeadline
            )
        } catch is SearchTimeout {
            // Couldn't even finish 2-ply — fall back to the 1-ply best.
            let p = bestPosition(candidates.map { rootScores[$0] })
            return (moves[candidates[p]], rootScores[candidates[p]], candidates[p], 1)
        }
        var reachedDepth = 2

        if targetDepth > 2 {
            // Step 3 — deepen candidates, best-2-ply-first, overwriting their score.
            let deepOrder = scores.indices.sorted {
                scores[$0] != scores[$1] ? scores[$0] > scores[$1] : candidates[$0] < candidates[$1]
            }
            for (k, pos) in deepOrder.enumerated() {
                if DispatchTime.now() > hardDeadline { break }
                if k >= minRootBranches && DispatchTime.now() > softDeadline { break }

                do {
                    scores[pos] = try evaluateMovesNply(
                        board, [moves[candidates[pos]]], color: color, depth: targetDepth,
                        beamThreshold: beamThreshold, relativeCutoff: relativeCutoff,
                        maxBranch: maxBranch, deadline: hardDeadline
                    )[0]
                } catch is SearchTimeout {
                    break  // hard cap hit mid-branch — keep the best result so far
                }
                reachedDepth = targetDepth
            }
        }

        let p = bestPosition(scores)
        return (moves[candidates[p]], scores[p], candidates[p], reachedDepth)
    }
}
