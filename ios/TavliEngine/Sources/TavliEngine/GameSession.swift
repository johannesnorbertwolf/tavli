import Foundation
import Combine
import CoreML

/// The phase of the current turn. The contract all views build against.
///
/// `GameSession` itself only drives the human-move-centric phases
/// (`awaitingRoll`/`picking`/`moving`/`gameOver`). `aiThinking` and `animating`
/// are part of the shared vocabulary for the AI/animation layers (later
/// tickets) and are not entered by the session on its own.
public enum TurnPhase: Equatable {
    case awaitingRoll
    case picking                 // dice rolled, no source selected yet
    case moving                  // a source is selected, destinations highlighted
    case aiThinking
    case animating
    case gameOver(winner: Color)
}

/// Headless, UI-agnostic controller for a single game.
///
/// Owns the `Game`, drives the turn state machine, and exposes observable
/// read-state. Views interact only through the intent methods
/// (`roll`/`setManualDice`/`selectPoint`/`commitHalfMove`/`undo`/`confirm`/
/// `newGame`). No rendering, no AI, no animation — those belong to later layers.
@MainActor
public final class GameSession: ObservableObject {
    public let game: Game

    /// The Core ML move selector. `nil` means no model is available — AI turns
    /// then fall back to a random legal move.
    public let agent: Agent?
    /// Which side the AI plays, if any. `nil` means a human-vs-human session.
    public let aiColor: Color?

    @Published public private(set) var phase: TurnPhase = .awaitingRoll
    @Published public private(set) var legalMoves: [Move] = []

    /// Latest win probability for WHITE (∈ [0, 1]), updated after each AI move.
    @Published public private(set) var winProbability: Double = 0.5

    /// Source point currently selected (a checker the player is about to move).
    @Published public private(set) var selectedPoint: Int? = nil
    /// Destinations for the selected source.
    @Published public private(set) var validTargets: Set<Int> = []
    /// Points a checker may be picked up from for the next half-move.
    @Published public private(set) var selectableSources: Set<Int> = []

    /// Incrementally narrows the legal-move set as half-moves are committed.
    public private(set) var moveBuilder: MoveBuilder

    /// One committed ply, kept so the player can step back to a previous decision
    /// (mirrors the CLI's `Snapshot` list). `move` is `nil` for a forced pass; the
    /// recorded dice are restored on undo so the same position can be re-decided.
    /// The half-moves reference the live board points, so undoing them reverses the
    /// exact board mutation.
    private struct PlyRecord {
        let mover: Color
        let move: Move?
        let dice: (Int, Int)
    }

    /// Committed plies, oldest first. Drives decision-point undo. Not published —
    /// every transition that changes undo-availability also reassigns `phase`.
    private var history: [PlyRecord] = []

    public init(startingPlayer: Color = .black,
                config: GameConfig = .standard,
                agent: Agent? = nil,
                aiColor: Color? = nil) {
        let game = Game(config: config, startingPlayer: startingPlayer)
        self.game = game
        self.agent = agent
        self.aiColor = aiColor
        self.moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
    }

    public var currentPlayer: Color { game.currentPlayer }

    /// Load the bundled Core ML value model and wrap it in an `Agent`.
    /// Returns `nil` when the model is absent so callers can fall back to random play.
    ///
    /// Prefers a pre-compiled `.mlmodelc`, but the model ships as a `.mlpackage`
    /// under Copy Bundle Resources (xcodegen copies it verbatim rather than running
    /// the Core ML compiler), so we compile it at launch — the same path the tests use.
    public static func makeAgent() -> Agent? {
        let compiledURL: URL?
        if let c = Bundle.main.url(forResource: "PlakotoValue", withExtension: "mlmodelc") {
            compiledURL = c
        } else if let pkg = Bundle.main.url(forResource: "PlakotoValue", withExtension: "mlpackage") {
            compiledURL = try? MLModel.compileModel(at: pkg)
        } else {
            compiledURL = nil
        }
        guard let compiledURL, let model = try? MLModel(contentsOf: compiledURL) else {
            return nil
        }
        return Agent(model: model, encoder: BoardEncoder(config: .standard))
    }

    /// Kick off the first move if the starting player is the AI. Views call this
    /// once after constructing the session.
    public func start() {
        maybeStartAITurn()
    }

    private var isAITurn: Bool {
        aiColor != nil && currentPlayer == aiColor
    }

    // ── Intents ─────────────────────────────────────────────────────────────

    /// Roll the dice for the current turn and compute legal moves.
    public func roll() {
        guard phase == .awaitingRoll else { return }
        game.dice.roll()
        beginTurn()
    }

    /// Set the dice to specific values (manual/debug/scripted play), then compute
    /// legal moves. Same effect as `roll` but deterministic.
    public func setManualDice(_ d1: Int, _ d2: Int) {
        guard phase == .awaitingRoll else { return }
        game.dice.set(d1, d2)
        beginTurn()
    }

    /// Pick (or clear) a source point for the next half-move.
    public func selectPoint(_ pointIndex: Int) {
        guard phase == .picking || phase == .moving else { return }
        guard selectableSources.contains(pointIndex) else {
            clearSelection()
            phase = .picking
            return
        }
        selectedPoint = pointIndex
        validTargets = moveBuilder.validDestinations(for: pointIndex)
        phase = .moving
    }

    /// Commit a move from `from` to `to`, applying it to the board. On a Pasch a
    /// far destination is a multi-hop chain, so this commits every intervening
    /// single-die hop. Advances to the next half-move, or finishes the turn when
    /// the move is complete (or the only remaining continuation is itself a
    /// complete legal move).
    public func commitHalfMove(from fromIndex: Int, to toIndex: Int) {
        guard phase == .picking || phase == .moving else { return }
        guard selectableSources.contains(fromIndex) else { return }

        let hops = moveBuilder.path(from: fromIndex, to: toIndex)
        guard !hops.isEmpty else { return }

        var complete = false
        for hop in hops {
            let hm = HalfMove(from: game.board.points[hop.from.position],
                              to: game.board.points[hop.to.position],
                              color: game.currentPlayer)
            game.board.applyHalfMove(hm)
            complete = moveBuilder.commit(halfMove: hm)
        }
        clearSelection()

        if complete || moveBuilder.canFinishNow {
            finishTurn(playedMove: Move(moveBuilder.built), mover: game.currentPlayer)
        } else {
            refreshSources()
        }
    }

    /// Undo one step. While a move is being composed this pops the last committed
    /// half-move (the within-turn editing primitive); once nothing is built it steps
    /// back to the previous decision point (the human's last move plus the AI's
    /// response), restoring that ply's dice. Tap again to keep going back.
    public func undo() {
        guard isUndoablePhase else { return }
        if let last = moveBuilder.built.last {
            game.board.undoHalfMove(last)
            moveBuilder.undo()
            clearSelection()
            refreshSources()
            return
        }
        undoLastDecision()
    }

    /// Finish the turn early when the partial sequence is already a legal move.
    public func confirm() {
        guard phase == .picking || phase == .moving, moveBuilder.canFinishNow else { return }
        finishTurn(playedMove: Move(moveBuilder.built), mover: game.currentPlayer)
    }

    /// Reset to a fresh game, current player rolling first.
    public func newGame(startingPlayer: Color = .black) {
        game.board.initializeBoard()
        game.dice.set(1, 1)
        game.setPlayer(startingPlayer)
        legalMoves = []
        moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
        clearSelection()
        selectableSources = []
        winProbability = 0.5
        history = []
        phase = .awaitingRoll
        maybeStartAITurn()
    }

    // ── Internal transitions ──────────────────────────────────────────────────

    private func beginTurn() {
        legalMoves = PossibleMoves(
            board: game.board,
            color: game.currentPlayer,
            dice: game.dice
        ).findMoves()

        guard !legalMoves.isEmpty else {
            // Forced pass: no legal moves, advance the turn.
            moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
            finishTurn(playedMove: nil, mover: game.currentPlayer)
            return
        }

        moveBuilder = MoveBuilder(legalMoves: legalMoves, board: game.board,
                                  die1: game.dice.die1.value, die2: game.dice.die2.value)
        clearSelection()
        refreshSources()
    }

    private func refreshSources() {
        selectableSources = moveBuilder.selectableSourcePoints
        phase = .picking
        refreshEvaluation()
    }

    /// Re-score the live board from the current player's view and publish it as
    /// WHITE's win probability, keeping the overlay live on the human's turn (after
    /// a roll, a committed half-move, or an undo). No-op without a model, so the
    /// random fallback leaves `winProbability` at its 0.5 default. The AI's turn is
    /// covered separately by `applyAIMove`.
    private func refreshEvaluation() {
        guard let agent,
              let v = try? agent.winProbability(game.board, color: currentPlayer) else { return }
        winProbability = currentPlayer.isWhite ? Double(v) : 1 - Double(v)
    }

    private func clearSelection() {
        selectedPoint = nil
        validTargets = []
    }

    /// Record the just-played ply (so it can be rewound), then advance the turn.
    /// `mover` and the live dice are captured before `switchTurn`. A winning move is
    /// still recorded for history completeness, though undo is blocked at `gameOver`.
    private func finishTurn(playedMove: Move?, mover: Color) {
        history.append(PlyRecord(
            mover: mover,
            move: playedMove,
            dice: (game.dice.die1.value, game.dice.die2.value)
        ))
        clearSelection()
        selectableSources = []

        if game.isOver(), let winner = game.getWinner() {
            phase = .gameOver(winner: winner)
            return
        }

        game.switchTurn()
        phase = .awaitingRoll
        maybeStartAITurn()
    }

    // ── Decision-point undo ──────────────────────────────────────────────────

    /// Undo is offered only while it's the human's move or between turns — never
    /// mid-AI-think, mid-animation, or once the game is over.
    private var isUndoablePhase: Bool {
        switch phase {
        case .awaitingRoll, .picking, .moving: return true
        case .aiThinking, .animating, .gameOver: return false
        }
    }

    /// True when an Undo control should be active: either a half-move is being
    /// composed, or there's a prior decision to step back to.
    public var canUndo: Bool {
        guard isUndoablePhase else { return false }
        return !moveBuilder.built.isEmpty || lastDecisionIndex() != nil
    }

    /// True when stepping back a whole decision is available (independent of any
    /// in-progress half-move build).
    public var canUndoLastDecision: Bool {
        isUndoablePhase && lastDecisionIndex() != nil
    }

    /// Index of the ply to rewind to: the most recent real move (not a pass) made by
    /// the side that gets to re-decide. With an AI that's the human; in a
    /// human-vs-human session it's simply the last move played. Passes are skipped
    /// because they were never a real choice — undo lands on the prior decision.
    private func lastDecisionIndex() -> Int? {
        let undoColor = aiColor?.opponent
        var i = history.count - 1
        while i >= 0 {
            let record = history[i]
            if record.move != nil, undoColor == nil || record.mover == undoColor {
                return i
            }
            i -= 1
        }
        return nil
    }

    /// Step back to the previous decision point: pop every ply from the target
    /// forward (reversing each on the board), restore that ply's player and dice, and
    /// re-enter the human's turn so the same position can be re-decided. No-op when
    /// there's nothing to rewind.
    public func undoLastDecision() {
        guard isUndoablePhase, let target = lastDecisionIndex() else { return }

        // Discard any half-moves built this turn but not yet recorded.
        for hm in moveBuilder.built.reversed() { game.board.undoHalfMove(hm) }

        let restoredColor = history[target].mover
        let (d1, d2) = history[target].dice
        while history.count > target {
            let popped = history.removeLast()
            if let move = popped.move { game.board.undo(move) }
        }

        game.setPlayer(restoredColor)
        game.dice.set(d1, d2)
        // The target was a real move, so the restored position has legal moves —
        // `beginTurn` lands in `picking` rather than auto-passing.
        beginTurn()
    }

    // ── AI turn ────────────────────────────────────────────────────────────────

    private func maybeStartAITurn() {
        guard isAITurn, phase == .awaitingRoll else { return }
        takeAITurn()
    }

    /// Roll for the AI, then either play a random move (no model) or compute the
    /// best move off the main actor and apply it back on the main actor.
    private func takeAITurn() {
        game.dice.roll()
        legalMoves = PossibleMoves(
            board: game.board,
            color: game.currentPlayer,
            dice: game.dice
        ).findMoves()

        guard !legalMoves.isEmpty else {
            moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
            finishTurn(playedMove: nil, mover: game.currentPlayer)
            return
        }
        moveBuilder = MoveBuilder(legalMoves: legalMoves, board: game.board,
                                  die1: game.dice.die1.value, die2: game.dice.die2.value)

        guard let agent else {
            // No model available — fall back to a random legal move.
            applyAIMove(legalMoves.randomElement()!, score: nil)
            return
        }

        phase = .aiThinking
        let moves = legalMoves
        let color = game.currentPlayer
        // Scoring apply/undoes on the shared `game.board`, so it must stay on the
        // board's own actor (main) — never a background task. The UI render and the
        // debug overlay's own scoring also touch this board; a concurrent analysis
        // pass would interleave the unbalanced pop/push and corrupt the checker
        // counts (and crash on a torn `pieces` read). Each `evaluateMoves` has no
        // internal `await`, so on the main actor it runs atomically and always
        // restores the board. The unstructured Task + yield lets the human's move
        // and the "AI thinking…" state paint before we block on inference.
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            // try? — a Core ML failure yields nil and a random fallback.
            let result = try? agent.getBestMove(self.game.board, moves, color: color)
            let chosen = result?.move ?? moves.randomElement()!
            self.applyAIMove(chosen, score: result?.score)
        }
    }

    private func applyAIMove(_ move: Move, score: Float?) {
        let mover = game.currentPlayer
        game.board.apply(move)
        if let score {
            // `score` is the win probability for the side that just moved.
            winProbability = (mover == .white) ? Double(score) : 1 - Double(score)
        }
        finishTurn(playedMove: move, mover: mover)
    }
}
