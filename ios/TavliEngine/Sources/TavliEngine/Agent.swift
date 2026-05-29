import Foundation
import CoreML

/// Core ML-backed move selector. Mirrors the 1-ply path of `ai/agent.py`:
/// for each candidate move, apply it; an immediate win scores 1.0, otherwise score
/// the afterstate from the opponent's perspective and take `1 - opponentValue`.
public final class Agent {
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

    public func getBestMove(_ board: GameBoard, _ moves: [Move], color: Color) throws -> (move: Move, score: Float)? {
        guard !moves.isEmpty else { return nil }
        let scores = try evaluateMoves(board, moves, color: color)
        var best = 0
        for i in 1..<scores.count where scores[i] > scores[best] { best = i }
        return (moves[best], scores[best])
    }
}
