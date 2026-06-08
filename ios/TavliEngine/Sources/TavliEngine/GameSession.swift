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
    /// The side that moved first this game. Retained (the live `game.player`
    /// alternates) so a save can record the turn order for exact replay.
    public private(set) var startingPlayer: Color

    /// Knobs for the AI's iterative-deepening search (defaults match the CLI).
    public let searchConfig: SearchConfig

    @Published public private(set) var phase: TurnPhase = .awaitingRoll
    @Published public private(set) var legalMoves: [Move] = []

    /// One entry per finished turn, in play order, recording the dice and the
    /// half-moves actually applied (empty = a forced pass). This is the sole basis
    /// for save/resume: replaying these half-moves from the initial position
    /// reproduces the exact board, with no stored board state (see `GameSave`).
    /// Published so the app can auto-save after every move (#61).
    @Published public private(set) var history: [PlyRecord] = []

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

    public init(startingPlayer: Color = .black,
                config: GameConfig = .standard,
                agent: Agent? = nil,
                aiColor: Color? = nil,
                searchConfig: SearchConfig = .standard) {
        let game = Game(config: config, startingPlayer: startingPlayer)
        self.game = game
        self.agent = agent
        self.aiColor = aiColor
        self.searchConfig = searchConfig
        self.startingPlayer = startingPlayer
        self.moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
    }

    public var currentPlayer: Color { game.currentPlayer }

    /// Whether the game has ended (someone won). Saves are only meaningful for
    /// non-terminal games — the app clears the auto-save once this is true.
    public var isTerminal: Bool {
        if case .gameOver = phase { return true }
        return false
    }

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
            recordPly(moveBuilder.built)
            finishTurn()
        } else {
            refreshSources()
        }
    }

    /// Undo the last committed half-move (reverses the board mutation too).
    public func undo() {
        guard let last = moveBuilder.built.last else { return }
        game.board.undoHalfMove(last)
        moveBuilder.undo()
        clearSelection()
        refreshSources()
    }

    /// Finish the turn early when the partial sequence is already a legal move.
    public func confirm() {
        guard phase == .picking || phase == .moving, moveBuilder.canFinishNow else { return }
        recordPly(moveBuilder.built)
        finishTurn()
    }

    /// Reset to a fresh game, current player rolling first.
    public func newGame(startingPlayer: Color = .black) {
        game.board.initializeBoard()
        game.dice.set(1, 1)
        game.setPlayer(startingPlayer)
        self.startingPlayer = startingPlayer
        history = []
        legalMoves = []
        moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
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
            moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
            recordPly([])
            finishTurn()
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
            moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
            recordPly([])
            finishTurn()
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
        let liveMoves = legalMoves
        let color = game.currentPlayer
        let search = searchConfig
        // Run the multi-ply search OFF the main actor so the UI stays responsive
        // while the AI thinks. It scores an *isolated copy* of the board (rebuilt
        // from a stack snapshot) rather than `game.board`: the main actor keeps
        // reading/scoring the live board (UI render, debug overlay), and the search
        // applies/undoes thousands of times — sharing one board across the two would
        // interleave the unbalanced pop/push and corrupt the checker counts. Move
        // generation is deterministic, so the copy's move list matches `liveMoves`
        // index-for-index; the search returns the chosen index, which we map back to
        // the live move on the main actor.
        let config = game.board.config
        let stacks = game.board.captureStacks()
        let d1 = game.dice.die1.value
        let d2 = game.dice.die2.value
        Task.detached { [weak self] in
            let copyBoard = GameBoard(config: config)
            copyBoard.restoreStacks(stacks)
            let dice = Dice(numberOfSides: config.dieSides)
            dice.set(d1, d2)
            let copyMoves = PossibleMoves(board: copyBoard, color: color, dice: dice).findMoves()

            // try? — a Core ML failure yields nil and a random fallback.
            let result = try? agent.getBestMove(
                copyBoard, copyMoves, color: color,
                timeBudget: search.timeBudget,
                beamThreshold: search.beamThreshold,
                relativeCutoff: search.relativeCutoff,
                maxBranch: search.maxBranch,
                maxDepth: search.maxDepth,
                rootSoftBudget: search.rootSoftBudget,
                minRootBranches: search.minRootBranches,
                maxRootBranches: search.maxRootBranches
            )
            let chosenIndex = result?.index
            let chosenScore = result?.score

            await MainActor.run { [weak self] in
                guard let self else { return }
                let chosen: Move
                if let chosenIndex, chosenIndex < liveMoves.count {
                    chosen = liveMoves[chosenIndex]
                } else {
                    chosen = liveMoves.randomElement()!
                }
                self.applyAIMove(chosen, score: chosenScore)
            }
        }
    }

    private func applyAIMove(_ move: Move, score: Float?) {
        let mover = game.currentPlayer
        game.board.apply(move)
        recordPly(move.halfMoves)
        if let score {
            // `score` is the win probability for the side that just moved.
            winProbability = (mover == .white) ? Double(score) : 1 - Double(score)
        }
        finishTurn()
    }

    // ── History ──────────────────────────────────────────────────────────────

    /// Append a finished turn to `history`. Captures the current dice and the
    /// applied half-moves as `[from, to]` index pairs (empty = a forced pass).
    /// Must be called before `finishTurn` switches the turn, while the dice still
    /// hold this ply's values.
    private func recordPly(_ halfMoves: [HalfMove]) {
        history.append(PlyRecord(
            die1: game.dice.die1.value,
            die2: game.dice.die2.value,
            halfMoves: halfMoves.map { [$0.from.position, $0.to.position] }
        ))
    }

    // ── Resume from a save ────────────────────────────────────────────────────

    /// Rebuild a session from a save by replaying its history from the initial
    /// position. The returned session sits at the resumed player's `awaitingRoll`
    /// (or `gameOver` if the recorded game already ended). Call `start()` afterward
    /// — exactly as for a new game — so the AI takes its turn if it owns the move.
    public static func resume(from save: GameSave,
                              config: GameConfig = .standard,
                              agent: Agent? = nil) -> GameSession {
        let starting = Color(rawValue: save.startingPlayer) ?? .black
        let aiColor = save.aiColor.flatMap { Color(rawValue: $0) }
        let session = GameSession(startingPlayer: starting,
                                  config: config,
                                  agent: agent,
                                  aiColor: aiColor)
        session.replay(save.history)
        return session
    }

    /// Apply each recorded half-move directly to the board, alternating the mover
    /// every ply (a pass still passes the turn). Mirrors `applyHalfMove`
    /// (`from.pop()` / `to.push(mover)`) without re-deriving legal moves, so the
    /// reconstruction is exact and independent of the bundled model.
    private func replay(_ plies: [PlyRecord]) {
        let board = game.board
        let upper = board.boardSize + 1
        var mover = startingPlayer
        history = []

        for ply in plies {
            for pair in ply.halfMoves where pair.count == 2 {
                let from = pair[0], to = pair[1]
                guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
                board.points[from].pop()
                board.points[to].push(mover)
            }
            history.append(ply)
            if game.isOver() { break }
            mover = mover.opponent
            game.setPlayer(mover)
        }

        game.dice.set(1, 1)
        legalMoves = []
        moveBuilder = MoveBuilder(legalMoves: [], board: board)
        clearSelection()
        selectableSources = []

        if game.isOver(), let winner = game.getWinner() {
            phase = .gameOver(winner: winner)
        } else {
            phase = .awaitingRoll
            refreshEvaluation()
        }
    }
}
