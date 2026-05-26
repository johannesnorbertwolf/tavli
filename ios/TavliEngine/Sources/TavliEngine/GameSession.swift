import Foundation
import Combine

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

    @Published public private(set) var phase: TurnPhase = .awaitingRoll
    @Published public private(set) var legalMoves: [Move] = []

    /// Source point currently selected (a checker the player is about to move).
    @Published public private(set) var selectedPoint: Int? = nil
    /// Destinations for the selected source.
    @Published public private(set) var validTargets: Set<Int> = []
    /// Points a checker may be picked up from for the next half-move.
    @Published public private(set) var selectableSources: Set<Int> = []

    /// Incrementally narrows the legal-move set as half-moves are committed.
    public private(set) var moveBuilder = MoveBuilder(legalMoves: [])

    public init(startingPlayer: Color = .black, config: GameConfig = .standard) {
        self.game = Game(config: config, startingPlayer: startingPlayer)
    }

    public var currentPlayer: Color { game.currentPlayer }

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
        phase = .awaitingRoll
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
    }
}
