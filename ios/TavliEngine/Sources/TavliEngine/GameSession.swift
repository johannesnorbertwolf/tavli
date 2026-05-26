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
    public private(set) var moveBuilder = MoveBuilder(legalMoves: [])

    public init(startingPlayer: Color = .black,
                config: GameConfig = .standard,
                agent: Agent? = nil,
                aiColor: Color? = nil) {
        self.game = Game(config: config, startingPlayer: startingPlayer)
        self.agent = agent
        self.aiColor = aiColor
    }

    public var currentPlayer: Color { game.currentPlayer }

    /// Load the bundled Core ML value model and wrap it in an `Agent`.
    /// Returns `nil` when the model is absent so callers can fall back to random play.
    public static func makeAgent() -> Agent? {
        guard let url = Bundle.main.url(forResource: "PlakotoValue", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else {
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

    /// Commit a single half-move `from -> to`, applying it to the board. Advances
    /// to the next half-move, or finishes the turn when the move is complete (or
    /// the only remaining continuation is itself a complete legal move).
    public func commitHalfMove(from fromIndex: Int, to toIndex: Int) {
        guard phase == .picking || phase == .moving else { return }
        guard selectableSources.contains(fromIndex),
              moveBuilder.validDestinations(for: fromIndex).contains(toIndex) else { return }

        let hm = HalfMove(from: game.board.points[fromIndex],
                          to: game.board.points[toIndex],
                          color: game.currentPlayer)
        game.board.applyHalfMove(hm)

        let complete = moveBuilder.commit(halfMove: hm)
        clearSelection()

        if complete || moveBuilder.canFinishNow {
            finishTurn()
        } else {
            refreshSources()
        }
    }

    /// Undo the last committed half-move (reverses the board mutation too).
    public func undo() {
        guard let last = moveBuilder.built.last else { return }
        game.board.undoHalfMove(last)
        moveBuilder.undo(allLegal: legalMoves)
        clearSelection()
        refreshSources()
    }

    /// Finish the turn early when the partial sequence is already a legal move.
    public func confirm() {
        guard phase == .picking || phase == .moving, moveBuilder.canFinishNow else { return }
        finishTurn()
    }

    /// Reset to a fresh game, current player rolling first.
    public func newGame(startingPlayer: Color = .black) {
        game.board.initializeBoard()
        game.dice.set(1, 1)
        game.setPlayer(startingPlayer)
        legalMoves = []
        moveBuilder = MoveBuilder(legalMoves: [])
        clearSelection()
        selectableSources = []
        winProbability = 0.5
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
            moveBuilder = MoveBuilder(legalMoves: [])
            finishTurn()
            return
        }

        moveBuilder = MoveBuilder(legalMoves: legalMoves)
        clearSelection()
        refreshSources()
    }

    private func refreshSources() {
        selectableSources = moveBuilder.selectableSourcePoints
        phase = .picking
    }

    private func clearSelection() {
        selectedPoint = nil
        validTargets = []
    }

    private func finishTurn() {
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
            moveBuilder = MoveBuilder(legalMoves: [])
            finishTurn()
            return
        }
        moveBuilder = MoveBuilder(legalMoves: legalMoves)

        guard let agent else {
            // No model available — fall back to a random legal move.
            applyAIMove(legalMoves.randomElement()!, score: nil)
            return
        }

        phase = .aiThinking
        let board = game.board
        let color = game.currentPlayer
        let moves = legalMoves
        Task.detached(priority: .userInitiated) {
            // do/catch via try? — a Core ML failure yields nil and a random fallback.
            let result = try? agent.getBestMove(board, moves, color: color)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let chosen = result?.move ?? moves.randomElement()!
                self.applyAIMove(chosen, score: result?.score)
            }
        }
    }

    private func applyAIMove(_ move: Move, score: Float?) {
        let mover = game.currentPlayer
        game.board.apply(move)
        if let score {
            // `score` is the win probability for the side that just moved.
            winProbability = (mover == .white) ? Double(score) : 1 - Double(score)
        }
        finishTurn()
    }
}
