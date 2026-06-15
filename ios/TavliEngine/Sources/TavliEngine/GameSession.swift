import Foundation
import Combine
import CoreML

/// The phase of the current turn. The contract all views build against.
///
/// `awaitingRoll`/`picking`/`moving`/`gameOver` are the human-move phases.
/// `aiThinking` covers the AI's off-main search; `animating` covers the
/// presentational replay of the AI's turn (#93) — both block human input
/// through the same phase guards the human intents already use.
public enum TurnPhase: Equatable {
    case awaitingRoll
    case picking                 // dice rolled, no source selected yet
    case moving                  // a source is selected, destinations highlighted
    case aiThinking
    case animating
    case gameOver(winner: Color)
}

/// Presentation timings for the AI's turn (#93). Purely visual — they never
/// affect which move is played, only how it is replayed for the viewer. A zero
/// duration disables that animation; `.off` (both zero) restores the fully
/// synchronous pre-animation behavior (the board snaps as soon as the move is
/// chosen), which headless tests rely on. The defaults give a ~1.8 s two-move
/// turn (0.6 s dice + 2 × 0.6 s moves). Surfaced in the settings screen once
/// #77 lands.
public struct AnimationTimings: Equatable, Sendable {
    /// Time the AI's dice visibly tumble before settling on the rolled values.
    public var aiDiceRollDuration: TimeInterval
    /// Time each half-move's checker spends arcing between points.
    public var aiMoveAnimationDuration: TimeInterval

    public init(aiDiceRollDuration: TimeInterval = 0.6,
                aiMoveAnimationDuration: TimeInterval = 0.6) {
        self.aiDiceRollDuration = aiDiceRollDuration
        self.aiMoveAnimationDuration = aiMoveAnimationDuration
    }

    public static let standard = AnimationTimings()
    public static let off = AnimationTimings(aiDiceRollDuration: 0, aiMoveAnimationDuration: 0)

    /// Whether the AI turn plays any animation at all.
    public var isAnimated: Bool { aiDiceRollDuration > 0 || aiMoveAnimationDuration > 0 }
}

/// One AI half-move in flight (#93). While published, the view layer renders
/// this checker arcing `from → to` (and shows one fewer checker at `from`);
/// the committed board still holds the pre-hop position. The session applies
/// the half-move and clears this when the flight time elapses, so the board
/// visibly advances point by point.
public struct AIAnimatedHop: Equatable, Sendable {
    /// Ordinal of the hop within the turn (0-based). Distinguishes consecutive
    /// hops with identical endpoints (a Pasch moving two checkers the same way)
    /// so the view restarts its flight animation per hop.
    public let id: Int
    public let from: Int
    public let to: Int
    public let color: Color
    /// Flight time, copied from `AnimationTimings.aiMoveAnimationDuration` so
    /// the view needs no second source of truth.
    public let duration: TimeInterval
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

    /// The single canonical record of this game (turn order, AI side, plies played,
    /// and the outcome once decided). The sole basis for save/resume: replaying its
    /// plies from the initial position reproduces the exact board, with no stored
    /// board state (see `GameSave`). Published so the app can auto-save after every
    /// move (#61) and so history-consuming features observe it.
    @Published public private(set) var record: GameRecord

    /// Which side the AI plays, if any. `nil` means a human-vs-human session.
    public var aiColor: Color? { record.aiColor }
    /// The side that moved first this game (the live `game.player` alternates).
    public var startingPlayer: Color { record.startingPlayer }
    /// One entry per finished turn, in play order (empty `halfMoves` = a forced pass).
    public var history: [PlyRecord] { record.plies }

    /// Knobs for the AI's iterative-deepening search (defaults match the CLI).
    public let searchConfig: SearchConfig

    /// Presentation timings for the AI turn (#93). Mutable so the settings
    /// screen (#77) can adjust them; consulted afresh at each AI turn.
    public var animationTimings: AnimationTimings

    /// Manual-dice mode (#110): when true the session does **not** auto-roll for
    /// the AI — on the AI's turn it pauses in `.awaitingRoll` so the human enters
    /// the AI's dice too, then plays the AI's move with them. Mirrors the human
    /// side, which the view gates on the same setting; the view keeps this in
    /// sync so a mid-game settings change takes effect on the next roll.
    public var manualDiceEntry: Bool

    /// Auto-roll mode (#116): when true the human's dice fire automatically at
    /// the start of their turn — no tap required. Mutually exclusive with
    /// `manualDiceEntry`; the view keeps this in sync with the settings toggle.
    public var autoRoll: Bool

    @Published public private(set) var phase: TurnPhase = .awaitingRoll
    @Published public private(set) var legalMoves: [Move] = []

    /// True while the AI's dice visibly tumble (#93). The dice values are
    /// already set (the engine needs them to pick a move); the view masks them
    /// until this flips back to false.
    @Published public private(set) var aiDiceRolling = false

    /// The AI half-move currently animating (#93), or `nil` outside an AI
    /// flight. Hops of one turn are published strictly one at a time; the
    /// board mutates only as each one lands.
    @Published public private(set) var aiHopInFlight: AIAnimatedHop? = nil

    /// The in-progress AI turn animation, kept so `newGame()` can cancel it.
    private var aiAnimationTask: Task<Void, Never>? = nil

    /// The pending auto-roll or auto-roll forced-pass task (#116).
    private var autoRollTask: Task<Void, Never>? = nil
    /// True while a forced-pass delay is counting down under auto-roll, to
    /// block a concurrent manual `roll()` call during those 0.5 s.
    private var autoRollPassing = false

    /// Bumped whenever a new game interrupts a pending AI turn, so a stale
    /// search result or animation continuation detects it and bails instead of
    /// mutating the fresh game.
    private var aiTurnEpoch = 0

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

    /// Fired exactly once, when the session first enters `.gameOver`, with the
    /// winning color. The app layer uses this to record the human's win/loss
    /// (issue #64); the engine itself stays unaware of stats persistence.
    public var onGameOver: (@MainActor (Color) -> Void)?

    /// Drill attempt hook (#63). When set, the session runs in **attempt mode**: a
    /// completed move is reported here and then rolled back to the pre-move position
    /// instead of being recorded and advancing the turn, so the player can keep
    /// trying the same position. `nil` (the default) is normal play.
    public var onMoveAttempt: (@MainActor (Move) -> Void)?

    /// One committed ply kept for decision-point undo. `move` is `nil` for a forced
    /// pass; dice are restored on undo so the same position can be re-decided.
    private struct UndoRecord {
        let mover: Color
        let move: Move?
        let dice: (Int, Int)
    }

    /// Committed plies, oldest first. Parallel to `record.plies` but carries the
    /// live `Move` objects needed to reverse board mutations. Not published —
    /// every transition that changes undo-availability also reassigns `phase`.
    private var undoHistory: [UndoRecord] = []

    /// Dice values saved during `undoLastDecision` for the plies being rewound, in
    /// chronological play order. `rollDice()` pops from the front before generating
    /// fresh random dice, so re-playing the same position produces identical rolls.
    private var diceReplays: [(Int, Int)] = []

    public init(startingPlayer: Color = .black,
                config: GameConfig = .standard,
                agent: Agent? = nil,
                aiColor: Color? = nil,
                searchConfig: SearchConfig = .standard,
                animationTimings: AnimationTimings = .standard,
                manualDiceEntry: Bool = false,
                autoRoll: Bool = false) {
        let game = Game(config: config, startingPlayer: startingPlayer)
        self.game = game
        self.agent = agent
        self.record = GameRecord(startingPlayer: startingPlayer, aiColor: aiColor)
        self.searchConfig = searchConfig
        self.animationTimings = animationTimings
        self.manualDiceEntry = manualDiceEntry
        self.autoRoll = autoRoll
        self.moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
    }

    public var currentPlayer: Color { game.currentPlayer }

    /// Whether the game has ended (someone won). Saves are only meaningful for
    /// non-terminal games — the app clears the auto-save once this is true.
    public var isTerminal: Bool {
        if case .gameOver = phase { return true }
        return false
    }

    /// Whether the human may resign right now (#74): only on the human's own move
    /// of a game with an AI side — never mid-AI-think/animation or once it's over.
    public var canSurrender: Bool {
        guard aiColor != nil else { return false }
        switch phase {
        case .awaitingRoll, .picking, .moving: return true
        case .aiThinking, .animating, .gameOver: return false
        }
    }

    /// WHITE's latest `winProbability` re-expressed for the human side (the AI's
    /// opponent), or `nil` in a human-vs-human session. Drives the surrender
    /// double-confirm threshold (#74).
    public var humanWinProbability: Double? {
        guard let human = aiColor?.opponent else { return nil }
        return human.isWhite ? winProbability : 1 - winProbability
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

    /// Kick off the first move. If the AI owns the turn it thinks immediately;
    /// if auto-roll is on and the human is first, the dice fire automatically.
    public func start() {
        maybeStartAITurn()
        maybeAutoRoll()
    }

    private var isAITurn: Bool {
        aiColor != nil && currentPlayer == aiColor
    }

    // ── Intents ─────────────────────────────────────────────────────────────

    /// Roll the dice for the current turn and compute legal moves.
    public func roll() {
        guard phase == .awaitingRoll, !autoRollPassing else { return }
        rollDice()
        beginTurn()
    }

    /// Set the dice to specific values (manual/debug/scripted play), then compute
    /// legal moves. Same effect as `roll` but deterministic. Clears the replay
    /// queue — a manual override supersedes any saved future dice. In manual-dice
    /// mode (#110) the human enters the AI's dice too: on the AI's turn this hands
    /// straight off to the AI's search/play with the entered dice (no tumble, the
    /// values are already shown), rather than starting a human turn.
    public func setManualDice(_ d1: Int, _ d2: Int) {
        guard phase == .awaitingRoll else { return }
        diceReplays.removeAll()
        game.dice.set(d1, d2)
        if isAITurn {
            playAITurn(animateDiceRoll: false)
        } else {
            beginTurn()
        }
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
            completeMove()
        } else {
            refreshSources()
        }
    }

    /// Undo the last committed half-move within the current turn (the within-turn
    /// editing primitive). No-op when nothing has been built yet this turn.
    /// For stepping back a whole decision see `undoLastDecision()`.
    public func undo() {
        guard isUndoablePhase, let last = moveBuilder.built.last else { return }
        game.board.undoHalfMove(last)
        moveBuilder.undo()
        clearSelection()
        refreshSources()
    }

    /// The in-game "Undo" button's action (#110). Peels back the current turn's
    /// half-moves first (within-turn `undo`); in manual-dice mode, once nothing is
    /// left to peel, it steps the game back one ply to that ply's **dice entry**, so
    /// the human can choose different dice and re-play it. In automatic mode it is
    /// exactly the within-turn undo (whole-decision rewind stays in the debug
    /// overlay's `undoLastDecision`).
    public func undoOrStepBack() {
        if canUndo { undo(); return }
        guard manualDiceEntry else { return }
        stepBackToManualRoll()
    }

    /// Whether the Undo button is enabled: a within-turn half-move to peel, or — in
    /// manual mode — a ply (the current rolled turn or a recorded one) to step back
    /// to its dice entry.
    public var canUndoOrStepBack: Bool {
        canUndo || (manualDiceEntry && canStepBackToManualRoll)
    }

    private var canStepBackToManualRoll: Bool {
        guard manualDiceEntry, isUndoablePhase else { return false }
        // Mid-turn (already rolled): unroll it. Between turns: pop the last ply.
        return phase == .picking || phase == .moving || !undoHistory.isEmpty
    }

    /// Step back one ply to its dice entry in manual mode (#110). Called only with
    /// no built half-moves left (the button peels those first via `undo`). If the
    /// current turn was rolled but not yet recorded, unroll it (same mover re-rolls);
    /// otherwise pop the last recorded ply — reversing it on the board — and restore
    /// its mover. Lands in `.awaitingRoll` so the manual control reappears.
    private func stepBackToManualRoll() {
        guard manualDiceEntry, isUndoablePhase, moveBuilder.built.isEmpty else { return }
        if phase == .picking || phase == .moving {
            enterManualRoll(for: game.currentPlayer)
        } else if let popped = undoHistory.popLast() {
            if !record.plies.isEmpty { record.plies.removeLast() }
            if let move = popped.move { game.board.undo(move) }
            enterManualRoll(for: popped.mover)
        }
    }

    /// Re-enter `.awaitingRoll` for `color` so the human picks fresh dice (manual
    /// step-back, #110). Clears move state and any saved replay dice — re-choosing
    /// supersedes them — and re-scores for the overlay.
    private func enterManualRoll(for color: Color) {
        game.setPlayer(color)
        legalMoves = []
        moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
        clearSelection()
        selectableSources = []
        diceReplays.removeAll()
        phase = .awaitingRoll
        refreshEvaluation()
    }

    /// Finish the turn early when the partial sequence is already a legal move.
    public func confirm() {
        guard phase == .picking || phase == .moving, moveBuilder.canFinishNow else { return }
        completeMove()
    }

    /// Finalize the move just composed in `moveBuilder`. In normal play this records
    /// the ply and advances the turn. In **attempt mode** (`onMoveAttempt` set — used
    /// by the post-game drill, #63) the move is instead reported to the handler and
    /// **rolled back** to the pre-move position, so the same position can be
    /// re-attempted; `record.plies`/`undoHistory` and the turn are left untouched.
    private func completeMove() {
        let move = Move(moveBuilder.built)
        if let onMoveAttempt {
            for hm in moveBuilder.built.reversed() { game.board.undoHalfMove(hm) }
            onMoveAttempt(move)
            beginTurn()   // recompute legal moves at the same dice → back to .picking
        } else {
            recordTurn(mover: game.currentPlayer, move: move)
            finishTurn()
        }
    }

    /// Resign on the human's behalf (#74): discard any half-move built this turn,
    /// award the win to the AI, and enter `.gameOver` — the same terminal state a
    /// played-out loss reaches, so `onGameOver` fires and the loss is recorded. No-op
    /// once the game is over, while the AI is thinking/animating (`canSurrender`
    /// guards both), or in a human-vs-human session (no AI side to award the win to).
    public func surrender() {
        guard canSurrender, let aiColor else { return }
        for hm in moveBuilder.built.reversed() { game.board.undoHalfMove(hm) }
        moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
        clearSelection()
        selectableSources = []
        legalMoves = []
        record.outcome = aiColor
        phase = .gameOver(winner: aiColor)
        onGameOver?(aiColor)
    }

    /// Reset to a fresh game, current player rolling first. Interrupts any
    /// pending AI turn: the animation task is cancelled and the epoch bumped so
    /// a still-running search cannot apply a stale move to the fresh board.
    public func newGame(startingPlayer: Color = .black) {
        aiTurnEpoch += 1
        aiAnimationTask?.cancel()
        aiAnimationTask = nil
        aiDiceRolling = false
        aiHopInFlight = nil
        autoRollTask?.cancel()
        autoRollTask = nil
        autoRollPassing = false
        game.board.initializeBoard()
        game.dice.set(1, 1)
        game.setPlayer(startingPlayer)
        record = GameRecord(startingPlayer: startingPlayer, aiColor: record.aiColor)
        legalMoves = []
        moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
        clearSelection()
        selectableSources = []
        winProbability = 0.5
        undoHistory = []
        diceReplays = []
        phase = .awaitingRoll
        maybeStartAITurn()
        maybeAutoRoll()
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
            if autoRoll {
                // Pause 0.5 s so the player can see the rolled dice before the
                // turn passes automatically. `autoRollPassing` blocks a concurrent
                // manual tap-to-roll during this window.
                autoRollPassing = true
                let mover = game.currentPlayer
                autoRollTask = Task { @MainActor [weak self] in
                    await GameSession.sleep(0.5)
                    guard let self, !Task.isCancelled else { return }
                    self.autoRollPassing = false
                    self.recordTurn(mover: mover, move: nil)
                    self.finishTurn()
                }
            } else {
                recordTurn(mover: game.currentPlayer, move: nil)
                finishTurn()
            }
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

    /// Advance the turn (or end the game). Call `recordPly` first so the mover
    /// and dice are captured before `switchTurn` hands the turn to the opponent.
    private func finishTurn() {
        clearSelection()
        selectableSources = []

        if game.isOver(), let winner = game.getWinner() {
            record.outcome = winner
            phase = .gameOver(winner: winner)
            onGameOver?(winner)
            return
        }

        game.switchTurn()
        phase = .awaitingRoll
        maybeStartAITurn()
        maybeAutoRoll()
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

    /// True when a half-move can be peeled back (something has been built this turn).
    public var canUndo: Bool {
        isUndoablePhase && !moveBuilder.built.isEmpty
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
        var i = undoHistory.count - 1
        while i >= 0 {
            let entry = undoHistory[i]
            if entry.move != nil, undoColor == nil || entry.mover == undoColor {
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

        let restoredColor = undoHistory[target].mover
        let (d1, d2) = undoHistory[target].dice

        // Collect dice for the plies being removed so re-plays reproduce the same
        // rolls. Start from target+1 (target's dice are restored directly below);
        // append the current in-progress roll last if already rolled this turn.
        var toReplay: [(Int, Int)] = []
        for i in (target + 1)..<undoHistory.count { toReplay.append(undoHistory[i].dice) }
        if phase == .picking || phase == .moving {
            toReplay.append((game.dice.die1.value, game.dice.die2.value))
        }
        diceReplays = toReplay + diceReplays

        while undoHistory.count > target {
            let popped = undoHistory.removeLast()
            if let move = popped.move { game.board.undo(move) }
        }
        // Keep record.plies in sync with undoHistory (both track one entry per turn).
        record.plies = Array(record.plies.prefix(target))

        game.setPlayer(restoredColor)
        game.dice.set(d1, d2)
        // The target was a real move, so the restored position has legal moves —
        // `beginTurn` lands in `picking` rather than auto-passing.
        beginTurn()
    }

    // ── AI turn ────────────────────────────────────────────────────────────────

    private func maybeStartAITurn() {
        guard isAITurn, phase == .awaitingRoll else { return }
        // Manual-dice mode (#110): don't auto-roll — wait in `.awaitingRoll` for
        // the human to enter the AI's dice, which then drives `playAITurn`.
        guard !manualDiceEntry else { return }
        takeAITurn()
    }

    /// Fire the human's roll automatically (#116). No-op when auto-roll is off,
    /// when the AI owns the turn, in manual-dice mode, or outside `.awaitingRoll`.
    private func maybeAutoRoll() {
        guard autoRoll, !isAITurn, phase == .awaitingRoll, !manualDiceEntry else { return }
        autoRollTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.roll()
        }
    }

    /// Roll for the AI, then either play a random move (no model) or compute the
    /// best move off the main actor and apply it back on the main actor.
    ///
    /// With `animationTimings.isAnimated` (#93) the turn is additionally
    /// *presented*: the dice tumble for `aiDiceRollDuration` (concurrently with
    /// the search, which already knows the values), then `animateAITurn` replays
    /// the chosen half-moves one at a time. With `.off` everything below is
    /// synchronous exactly as before.
    private func takeAITurn() {
        rollDice()
        playAITurn(animateDiceRoll: true)
    }

    /// Continue the AI's turn with the dice already on the board: generate legal
    /// moves and either pass, play randomly (no model), or search off the main
    /// actor, then present the result. `animateDiceRoll` is true for a normal
    /// secret roll (tumble + masked reveal, #93) and false when the human entered
    /// the AI's dice in manual mode (#110) — those are already shown, so we skip
    /// straight to the move animation.
    private func playAITurn(animateDiceRoll: Bool) {
        legalMoves = PossibleMoves(
            board: game.board,
            color: game.currentPlayer,
            dice: game.dice
        ).findMoves()

        let timings = animationTimings
        let epoch = aiTurnEpoch
        let diceRollStarted = Date()
        let rollDuration = animateDiceRoll ? timings.aiDiceRollDuration : 0
        if timings.isAnimated { aiDiceRolling = rollDuration > 0 }

        guard !legalMoves.isEmpty else {
            moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
            guard timings.isAnimated else {
                recordTurn(mover: game.currentPlayer, move: nil)
                finishTurn()
                return
            }
            // Forced pass: still show the roll the AI could not play.
            animateAITurn(move: nil, score: nil, diceRollStarted: diceRollStarted,
                          rollDuration: rollDuration, epoch: epoch)
            return
        }
        moveBuilder = MoveBuilder(legalMoves: legalMoves, board: game.board,
                                  die1: game.dice.die1.value, die2: game.dice.die2.value)

        guard let agent else {
            // No model available — fall back to a random legal move.
            let move = legalMoves.randomElement()!
            guard timings.isAnimated else {
                applyAIMove(move, score: nil)
                return
            }
            animateAITurn(move: move, score: nil, diceRollStarted: diceRollStarted,
                          rollDuration: rollDuration, epoch: epoch)
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
                guard let self, self.aiTurnEpoch == epoch else { return }
                let chosen: Move
                if let chosenIndex, chosenIndex < liveMoves.count {
                    chosen = liveMoves[chosenIndex]
                } else {
                    chosen = liveMoves.randomElement()!
                }
                if self.animationTimings.isAnimated {
                    self.animateAITurn(move: chosen, score: chosenScore,
                                       diceRollStarted: diceRollStarted,
                                       rollDuration: rollDuration, epoch: epoch)
                } else {
                    self.applyAIMove(chosen, score: chosenScore)
                }
            }
        }
    }

    private func applyAIMove(_ move: Move, score: Float?) {
        let mover = game.currentPlayer
        game.board.apply(move)
        recordTurn(mover: mover, move: move)
        if let score {
            // `score` is the win probability for the side that just moved.
            winProbability = (mover == .white) ? Double(score) : 1 - Double(score)
        }
        finishTurn()
    }

    /// How long the settled dice of a forced pass stay on screen before the
    /// turn passes, so the player registers the roll the AI could not play.
    /// Scales down with the configured timings so near-zero test timings keep
    /// the whole animated turn near-instant; 0.45 s at the standard timings.
    private var passBeat: TimeInterval {
        min(0.45, 2 * max(animationTimings.aiDiceRollDuration,
                          animationTimings.aiMoveAnimationDuration))
    }

    /// Replay the AI's already-chosen turn visually (#93): wait out the rest of
    /// the dice tumble, then for each half-move publish it as in flight, wait
    /// its flight time, and only then land it on the board — so every
    /// intermediate position (all four hops of a Pasch included) is visible.
    /// Recording and `finishTurn` happen after the last hop lands, keeping the
    /// usual ordering guarantees; phase guards block human input throughout.
    /// `move == nil` is a forced pass (dice settle, short beat, turn passes).
    /// `rollDuration` is the dice-tumble window to wait out before the move (the
    /// configured duration for a secret roll, 0 for manual entry where the dice
    /// are already on screen, #110).
    private func animateAITurn(move: Move?, score: Float?, diceRollStarted: Date,
                               rollDuration: TimeInterval, epoch: Int) {
        phase = .animating
        let timings = animationTimings
        let beat = passBeat
        let mover = game.currentPlayer
        aiAnimationTask = Task { @MainActor [weak self] in
            // Re-validate after every suspension: the session may be gone, the
            // task cancelled, or a new game started (epoch bumped) meanwhile.
            @MainActor func live() -> GameSession? {
                guard let self, !Task.isCancelled, self.aiTurnEpoch == epoch else { return nil }
                return self
            }

            // The search ran concurrently with the tumble — sleep only the rest.
            let elapsed = Date().timeIntervalSince(diceRollStarted)
            await Self.sleep(rollDuration - elapsed)
            guard let settled = live() else { return }
            settled.aiDiceRolling = false

            guard let move else {
                await Self.sleep(beat)
                guard let s = live() else { return }
                s.recordTurn(mover: mover, move: nil)
                s.finishTurn()
                return
            }

            for (i, hop) in move.halfMoves.enumerated() {
                guard let s = live() else { return }
                s.aiHopInFlight = AIAnimatedHop(id: i,
                                                from: hop.from.position,
                                                to: hop.to.position,
                                                color: mover,
                                                duration: timings.aiMoveAnimationDuration)
                await Self.sleep(timings.aiMoveAnimationDuration)
                guard let landed = live() else { return }
                landed.game.board.applyHalfMove(hop)
                landed.moveBuilder.commit(halfMove: hop)
                landed.aiHopInFlight = nil
            }

            guard let s = live() else { return }
            // Fresh builder so the finished turn leaves no built half-moves
            // behind (a stale `built` would re-enable the within-turn Undo).
            s.moveBuilder = MoveBuilder(legalMoves: [], board: s.game.board)
            if let score {
                s.winProbability = (mover == .white) ? Double(score) : 1 - Double(score)
            }
            s.recordTurn(mover: mover, move: move)
            s.finishTurn()
        }
    }

    /// Sleep helper for the animation driver; a non-positive duration returns
    /// immediately, so zeroed timings degrade to back-to-back publishes.
    private static func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // ── Dice rolling ─────────────────────────────────────────────────────────

    /// Set the dice for the next ply. Pops a saved roll from `diceReplays` when
    /// one is queued (so re-plays after `undoLastDecision` reproduce the original
    /// dice); falls back to a fresh random roll when the queue is empty.
    private func rollDice() {
        if diceReplays.isEmpty {
            game.dice.roll()
        } else {
            let (d1, d2) = diceReplays.removeFirst()
            game.dice.set(d1, d2)
        }
    }

    // ── History recording ─────────────────────────────────────────────────────

    /// Append a finished turn to both `record.plies` (for replay/save) and
    /// `undoHistory` (for decision-point undo). Must be called before `finishTurn`
    /// switches the turn, while the dice still hold this ply's values.
    private func recordTurn(mover: Color, move: Move?) {
        record.plies.append(PlyRecord(
            die1: game.dice.die1.value,
            die2: game.dice.die2.value,
            halfMoves: (move?.halfMoves ?? []).map { [$0.from.position, $0.to.position] }
        ))
        undoHistory.append(UndoRecord(
            mover: mover,
            move: move,
            dice: (game.dice.die1.value, game.dice.die2.value)
        ))
    }

    // ── Drill seeding (#63) ───────────────────────────────────────────────────

    /// Stand up a session at an arbitrary position for the post-game drill: seed the
    /// board from `boardStacks`, set `mover` to play under the given dice, and land
    /// in `.picking`. Always **human-vs-human** (`aiColor: nil`) so no AI auto-moves;
    /// the caller sets `onMoveAttempt` to evaluate the player's tries. The agent is
    /// kept only so the live win-probability overlay still works.
    public static func drill(boardStacks: [[Color]],
                             die1: Int, die2: Int,
                             mover: Color,
                             agent: Agent? = nil,
                             config: GameConfig = .standard) -> GameSession {
        let session = GameSession(startingPlayer: mover, config: config, agent: agent, aiColor: nil)
        for i in session.game.board.points.indices where i < boardStacks.count {
            session.game.board.setPoint(i, pieces: boardStacks[i])
        }
        session.setManualDice(die1, die2)   // → beginTurn → .picking at this position
        return session
    }

    // ── Resume from a save ────────────────────────────────────────────────────

    /// Rebuild a session from a save by replaying its history from the initial
    /// position. The returned session sits at the resumed player's `awaitingRoll`
    /// (or `gameOver` if the recorded game already ended). Call `start()` afterward
    /// — exactly as for a new game — so the AI takes its turn if it owns the move.
    public static func resume(from save: GameSave,
                              config: GameConfig = .standard,
                              agent: Agent? = nil,
                              animationTimings: AnimationTimings = .standard,
                              manualDiceEntry: Bool = false,
                              autoRoll: Bool = false) -> GameSession {
        let starting = Color(rawValue: save.startingPlayer) ?? .black
        let aiColor = save.aiColor.flatMap { Color(rawValue: $0) }
        let session = GameSession(startingPlayer: starting,
                                  config: config,
                                  agent: agent,
                                  aiColor: aiColor,
                                  animationTimings: animationTimings,
                                  manualDiceEntry: manualDiceEntry,
                                  autoRoll: autoRoll)
        session.replay(save.history)
        return session
    }

    /// Apply each recorded half-move directly to the board, alternating the mover
    /// every ply (a pass still passes the turn). Mirrors `applyHalfMove`
    /// (`from.pop()` / `to.push(mover)`) without re-deriving legal moves, so the
    /// reconstruction is exact and independent of the bundled model. `undoHistory`
    /// is left empty after replay — Move objects cannot be reconstructed from saved
    /// indices, so decision-point undo is unavailable until the first new move.
    private func replay(_ plies: [PlyRecord]) {
        let board = game.board
        let upper = board.boardSize + 1
        var mover = startingPlayer
        record.plies = []
        undoHistory = []
        diceReplays = []

        for ply in plies {
            for pair in ply.halfMoves where pair.count == 2 {
                let from = pair[0], to = pair[1]
                guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
                board.points[from].pop()
                board.points[to].push(mover)
            }
            record.plies.append(ply)
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
            record.outcome = winner
            phase = .gameOver(winner: winner)
        } else {
            phase = .awaitingRoll
            refreshEvaluation()
        }
    }
}
