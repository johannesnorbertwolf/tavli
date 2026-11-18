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
    /// The game has ended. `winner == nil` is a **draw** (standard Plakoto, both
    /// mothers pinned); see `GameSession.record` for the points scored.
    case gameOver(winner: Color?)
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

/// A pending choice between routes of one checker that end in different positions
/// (#169, Portes). Keyed by the route's first intermediate point: unique per route,
/// since only two-dice (non-double) routes can be ambiguous.
public struct RouteChoice: Equatable {
    /// The checker's source position and the far destination the player chose.
    public let source: Int
    public let destination: Int
    /// First intermediate point -> the route's ordered hops.
    public let routes: [Int: [HalfMove]]

    /// The points the player may tap to pick a route.
    public var intermediatePoints: Set<Int> { Set(routes.keys) }
}

/// Headless, UI-agnostic controller for a single game.
///
/// Owns the `Game`, drives the turn state machine, and exposes observable
/// read-state. Views interact only through the intent methods
/// (`roll`/`setDice`/`selectPoint`/`commitHalfMove`/`undo`/`confirm`/
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

    /// The 2-ply analysis accumulated during play (#146), in play order. Empty when
    /// in-play analysis is off, when there is no model, or before any analyzable ply
    /// has completed. Written into the finished game's log entry so the review reuses it.
    public var inPlayAnalysis: [AnalysisEntry] {
        analysisByPly.values.sorted { $0.plyNumber < $1.plyNumber }
    }

    /// Knobs for the AI's search. Mutable so the settings screen can retune the
    /// AI-strength dial (`maxDepth` + `selectionNoise`, #108) mid-game; the view keeps it
    /// in sync and it is read afresh at each AI turn.
    public var searchConfig: SearchConfig

    /// Presentation timings for the AI turn (#93). Mutable so the settings
    /// screen (#77) can adjust them; consulted afresh at each AI turn.
    public var animationTimings: AnimationTimings

    /// Auto-roll mode (#116): when true the human's dice fire automatically at
    /// the start of their turn — no tap required. The view keeps this in sync with
    /// the settings toggle.
    public var autoRoll: Bool

    /// In-play analysis mode (#146): when true the session computes each ply's 2-ply
    /// analysis *while the game is played* — captured for free from the AI's own move
    /// search on its turns, and ranked in the background during the human's thinking
    /// time on theirs — and accumulates it in `inPlayAnalysis`. Persisting that with
    /// the finished game (see the game log) lets the post-game review open instantly,
    /// leaving only the 3-ply borderline refinement. Mutable so the settings toggle can
    /// flip it mid-game; the view keeps it in sync. Spends CPU/battery while playing, so
    /// it is gated. No effect in attempt mode (the drill) or without a model.
    public var inPlayAnalysisEnabled: Bool

    @Published public private(set) var phase: TurnPhase = .awaitingRoll
    @Published public private(set) var legalMoves: [Move] = []

    /// The roll of the turn in progress (#171): set the moment dice exist for the
    /// side on move (tap, auto-roll, the AI's roll, a decision rewind)
    /// and cleared when that turn is recorded as a ply (or abandoned). `snapshot`
    /// persists it so a crash/relaunch mid-turn resumes with the same dice.
    @Published public private(set) var pendingRoll: PendingRoll? = nil

    /// Bumped whenever `pendingRoll` is set — and when it is dropped without a ply
    /// being recorded (a decision rewind) — so the app can write its autosave as soon
    /// as a roll exists (#171), not only after a move (`history.count`).
    @Published public private(set) var rollRevision = 0

    /// A resumed save carried a pending roll (#171): `start()` (or a stray `roll()`)
    /// re-enters that turn with the restored dice instead of rolling.
    private var restoreRollOnStart = false

    /// True while the AI's dice visibly tumble (#93). The dice values are
    /// already set (the engine needs them to pick a move); the view masks them
    /// until this flips back to false.
    @Published public private(set) var aiDiceRolling = false

    /// True while the human's dice tumble under auto-roll (#116). Same contract
    /// as `aiDiceRolling`: values are already set; the view masks them with
    /// random faces and reveals on settle. The view uses `aiDiceRollDuration`
    /// from `animationTimings` for the tumble length.
    @Published public private(set) var humanDiceRolling = false

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

    // ── In-play analysis (#146) ────────────────────────────────────────────────
    /// Accumulated per-ply 2-ply analysis, keyed by 1-based ply number, in
    /// `record.plies` index space. Filled as each ply completes (the AI's from its
    /// search, the human's from the background ranking). Persisted with the finished
    /// game so the review opens without re-computing the 2-ply pass.
    private var analysisByPly: [Int: AnalysisEntry] = [:]
    /// The background 2-ply ranking of the human's legal moves for the current turn,
    /// kept so transitions that change the position can cancel it.
    private var humanAnalysisTask: Task<Void, Never>? = nil
    /// The completed background ranking, one score per entry of `legalMoves` (same
    /// order, since move generation is deterministic), or `nil` until it finishes.
    /// Read on move commit to record the played/best scores; cleared each turn.
    private var humanAnalysisScores: [Float]? = nil
    /// Bumped on every transition that invalidates the human ranking (a new turn, a
    /// step-back, surrender, a new game) so a still-running ranking detects it and
    /// discards its stale result instead of recording it against the wrong position.
    private var analysisEpoch = 0

    /// Latest win probability for WHITE (∈ [0, 1]), updated after each AI move.
    @Published public private(set) var winProbability: Double = 0.5

    /// Source point currently selected (a checker the player is about to move).
    @Published public private(set) var selectedPoint: Int? = nil
    /// Destinations for the selected source.
    @Published public private(set) var validTargets: Set<Int> = []
    /// Points a checker may be picked up from for the next half-move.
    @Published public private(set) var selectableSources: Set<Int> = []
    /// A pending two-dice route choice (#169), or `nil`. While set, `selectedPoint` is
    /// its source, `validTargets` is empty, and the view highlights `destination` plus
    /// the `intermediatePoints`; resolve with `chooseRoute(via:)` / `cancelRouteChoice()`.
    @Published public private(set) var routeChoice: RouteChoice? = nil

    /// Incrementally narrows the legal-move set as half-moves are committed.
    public private(set) var moveBuilder: MoveBuilder

    // ── Handicap (#148, tier 1) ───────────────────────────────────────────────
    // Everything below is inert unless the game was started with an active
    // `HandicapSetup` (house Plakoto only): `handicap == nil` keeps every code path
    // exactly as it was.

    /// The handicap and its tokens left, or `nil` for a normal game. Persisted in the
    /// save (`GameSave.handicap`) so a resumed game keeps its counts.
    @Published public private(set) var handicap: HandicapGameState? = nil
    /// The value net used for weighted dice, the computer's reroll decisions and hints
    /// (the session's own `agent`, or one passed in for a two-player game). `nil`
    /// outside handicap games.
    public let handicapAgent: Agent?
    /// True while a weighted roll is being prepared (the 21 rolls rated off the main
    /// actor). Rolling, undo and the handicap buttons wait for it.
    @Published public private(set) var preparingDice = false
    /// The best move for the turn in progress, shown after a hint was used (`[from,
    /// to]` pairs, the generator's form), or `nil`. Cleared as soon as a checker moves.
    @Published public private(set) var hint: [[Int]]? = nil
    /// A hint is being computed (2-ply, off the main actor).
    @Published public private(set) var hintPending = false
    /// The side whose computer player last used a reroll (shown as a note until its
    /// next turn), or `nil`.
    @Published public private(set) var lastComputerReroll: Color? = nil
    /// Uniform source in [0, 1) for handicap dice draws (weighted rolls and rerolls).
    /// Injectable so tests are deterministic; never consulted for a normal game.
    public var handicapUniform: () -> Double = { Double.random(in: 0..<1) }
    /// Bumped whenever a pending weighted roll must be discarded (new game, rewind,
    /// scripted dice), so a late result doesn't land on the wrong turn.
    private var handicapEpoch = 0
    /// Bumped whenever a pending hint goes stale (a checker moved, a new turn).
    private var hintEpoch = 0

    /// Fired exactly once, when the session first enters `.gameOver`, with the
    /// winning color. The app layer uses this to record the human's win/loss
    /// (issue #64); the engine itself stays unaware of stats persistence.
    public var onGameOver: (@MainActor (Color) -> Void)?

    /// Fired exactly once whenever the game ends — wins **and draws** (which do not
    /// fire `onGameOver`) — with the winner (`nil` = draw) and the points the result
    /// is worth under the variant (1, or 2 for a gammon/mars/mother win).
    public var onGameFinished: (@MainActor (_ winner: Color?, _ points: Int) -> Void)?

    /// Drill attempt hook (#63). When set, the session runs in **attempt mode**: a
    /// completed move is reported here and then rolled back to the pre-move position
    /// instead of being recorded and advancing the turn, so the player can keep
    /// trying the same position. `nil` (the default) is normal play.
    public var onMoveAttempt: (@MainActor (Move) -> Void)?

    /// When `true`, attempt mode **holds** the completed move on the board instead of
    /// rolling it back immediately (#114): the player can see the position their move
    /// produced. `retryAttempt()` rolls it back to re-try. Has no effect outside
    /// attempt mode (`onMoveAttempt == nil`).
    public var holdAttempts = false

    /// The attempt currently held on the board (#114), or `nil` when the board is at
    /// the pre-move position. While non-nil the board shows the result of the move and
    /// accepts no further input until `retryAttempt()`.
    @Published public private(set) var heldAttempt: Move?

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
                autoRoll: Bool = false,
                inPlayAnalysis: Bool = false,
                handicap: HandicapSetup? = nil,
                handicapAgent: Agent? = nil) {
        // A handicap applies only when active and only to house Plakoto (#148); any
        // other combination is simply a normal game.
        let setup = handicap.map(\.normalized).flatMap {
            $0.isActive && HandicapSetup.supports(variantID: config.variant.id) ? $0 : nil
        }
        let starter = setup?.forcedStarter ?? startingPlayer
        let game = Game(config: config, startingPlayer: starter)
        setup?.setUpInitialPosition(on: game.board)
        self.game = game
        self.agent = agent
        self.handicap = setup.map(HandicapGameState.init(setup:))
        self.handicapAgent = setup == nil ? nil : (handicapAgent ?? agent)
        self.record = GameRecord(startingPlayer: starter, aiColor: aiColor,
                                 variantID: config.variant.id, handicap: setup)
        self.searchConfig = searchConfig
        self.animationTimings = animationTimings
        self.autoRoll = autoRoll
        self.inPlayAnalysisEnabled = inPlayAnalysis
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
    ///
    /// The model is the one named by `config.variant.modelResourceName` (#136), wrapped
    /// with that variant's encoder and rules.
    /// Resolution goes through `ModelCatalog.main` (#143), so a variant whose model is
    /// not bundled yields `nil` — the app gates vs-AI play on `ModelCatalog.isAvailable`.
    public static func makeAgent(config: GameConfig = .standard) -> Agent? {
        ModelCatalog.main.makeAgent(config: config)
    }

    /// Kick off the first move. If the AI owns the turn it thinks immediately;
    /// if auto-roll is on and the human is first, the dice fire automatically.
    public func start() {
        if restoreRollOnStart { resumePendingRoll(); return }
        maybeStartAITurn()
        maybeAutoRoll()
    }

    private var isAITurn: Bool {
        aiColor != nil && currentPlayer == aiColor
    }

    // ── Intents ─────────────────────────────────────────────────────────────

    /// Roll the dice for the current turn and compute legal moves.
    public func roll() {
        guard phase == .awaitingRoll, !autoRollPassing, !humanDiceRolling, !preparingDice else { return }
        if restoreRollOnStart { resumePendingRoll(); return }
        if weightedTiltForCurrentPlayer != nil {
            // Weighted dice (#148): rate the rolls off the main actor, then draw.
            let pending = startHandicappedRoll()
            Task { @MainActor [weak self] in
                guard let self, await self.finishHandicappedRoll(pending) else { return }
                self.beginTurn()
            }
            return
        }
        rollDice()
        beginTurn()
    }

    /// Set the dice to specific values (scripted/deterministic play — tests, previews,
    /// the `-uiTestGame` launch hook, the drill seeder), then compute legal moves.
    /// Same effect as `roll` but deterministic. Clears the replay queue — an explicit
    /// override supersedes any saved future dice and any restored pending roll.
    /// Always starts a human turn; on the AI's turn the AI rolls for itself.
    public func setDice(_ d1: Int, _ d2: Int) {
        guard phase == .awaitingRoll else { return }
        if preparingDice { discardPendingHandicapRoll() }
        diceReplays.removeAll()
        restoreRollOnStart = false
        game.dice.set(d1, d2)
        markRolled()
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
        routeChoice = nil
        selectedPoint = pointIndex
        validTargets = moveBuilder.validDestinations(for: pointIndex)
        phase = .moving
    }

    /// Commit a move from `from` to `to`, applying it to the board. On a Pasch a
    /// far destination is a multi-hop chain, so this commits every intervening
    /// single-die hop. Advances to the next half-move, or finishes the turn when
    /// the move is complete (or the only remaining continuation is itself a
    /// complete legal move).
    ///
    /// **Route choice (#169).** When the checker can reach `to` by routes that end in
    /// *different* positions (Portes: hit a blot on the way or not, or hit different
    /// blots), nothing is played: the session enters a pending `routeChoice` exposing
    /// the candidate intermediate points, resolved by `chooseRoute(via:)` or aborted by
    /// `cancelRouteChoice()`. Routes that all end in the same position play directly.
    public func commitHalfMove(from fromIndex: Int, to toIndex: Int) {
        guard phase == .picking || phase == .moving else { return }
        routeChoice = nil
        guard selectableSources.contains(fromIndex) else { return }

        let options = moveBuilder.routeOptions(from: fromIndex, to: toIndex)
        guard let first = options.first else { return }
        guard options.count == 1 else {
            var routes: [Int: [HalfMove]] = [:]
            for hops in options where routes[hops[0].to.position] == nil {
                routes[hops[0].to.position] = hops
            }
            selectedPoint = fromIndex
            validTargets = []
            routeChoice = RouteChoice(source: fromIndex, destination: toIndex, routes: routes)
            phase = .moving
            return
        }
        play(gesture: first)
    }

    /// Resolve a pending `routeChoice` (#169): `point` is one of its
    /// `intermediatePoints` -> play that route as one gesture; anything else aborts the
    /// choice with nothing played (the board and the built move are untouched).
    public func chooseRoute(via point: Int) {
        guard let choice = routeChoice else { return }
        guard let hops = choice.routes[point] else { cancelRouteChoice(); return }
        routeChoice = nil
        play(gesture: hops)
    }

    /// Abort a pending `routeChoice` (#169) with nothing played; back to `.picking`.
    public func cancelRouteChoice() {
        guard routeChoice != nil else { return }
        clearSelection()
        phase = .picking
    }

    /// Apply one gesture's hops to the board and commit them to the builder as a
    /// single gesture (so `undo` takes them back together).
    private func play(gesture hops: [HalfMove]) {
        if hint != nil || hintPending { clearHint() }
        let applied = hops.map { hop -> HalfMove in
            let hm = HalfMove(from: game.board.points[hop.from.position],
                              to: game.board.points[hop.to.position],
                              color: game.currentPlayer)
            game.variant.applyHalfMove(hm, on: game.board)
            return hm
        }
        let complete = moveBuilder.commit(halfMoves: applied)
        clearSelection()

        if complete || moveBuilder.canFinishNow {
            completeMove()
        } else {
            refreshSources()
        }
    }

    /// Undo the last committed **gesture** within the current turn (the within-turn
    /// editing primitive): a single step, or every hop of a multi-hop / two-dice
    /// gesture at once (#169). No-op when nothing has been built yet this turn.
    /// For stepping back a whole decision see `undoLastDecision()`.
    public func undo() {
        guard isUndoablePhase else { return }
        let gesture = moveBuilder.lastGesture
        guard !gesture.isEmpty else { return }
        for hm in gesture.reversed() { game.variant.undoHalfMove(hm, on: game.board) }
        moveBuilder.undoGesture()
        clearSelection()
        refreshSources()
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
            if holdAttempts {
                // Keep the move on the board so the player can study the result (#114);
                // lock input until `retryAttempt()` rolls it back.
                heldAttempt = move
                clearSelection()
                selectableSources = []
                legalMoves = []
                onMoveAttempt(move)
            } else {
                for hm in moveBuilder.built.reversed() { game.variant.undoHalfMove(hm, on: game.board) }
                onMoveAttempt(move)
                beginTurn()   // recompute legal moves at the same dice → back to .picking
            }
        } else {
            recordTurn(mover: game.currentPlayer, move: move)
            captureMoveAnalysis(playedMove: move)
            finishTurn()
        }
    }

    /// Roll back the held attempt (#114) to the pre-move position and re-arm the same
    /// dice, so the player can try again. No-op when nothing is held.
    public func retryAttempt() {
        guard let move = heldAttempt else { return }
        for hm in move.halfMoves.reversed() { game.variant.undoHalfMove(hm, on: game.board) }
        heldAttempt = nil
        beginTurn()   // back to .picking at the same position/dice
    }

    /// Resign on the human's behalf (#74): discard any half-move built this turn,
    /// award the win to the AI, and enter `.gameOver` — the same terminal state a
    /// played-out loss reaches, so `onGameOver` fires and the loss is recorded. No-op
    /// once the game is over, while the AI is thinking/animating (`canSurrender`
    /// guards both), or in a human-vs-human session (no AI side to award the win to).
    public func surrender() {
        guard canSurrender, let aiColor else { return }
        cancelHumanAnalysis()
        if handicap != nil { clearHint() }
        for hm in moveBuilder.built.reversed() { game.variant.undoHalfMove(hm, on: game.board) }
        moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
        clearSelection()
        selectableSources = []
        legalMoves = []
        pendingRoll = nil
        record.outcome = aiColor
        if game.variant.maxPoints > 1 { record.points = 1 }
        phase = .gameOver(winner: aiColor)
        onGameOver?(aiColor)
        onGameFinished?(aiColor, 1)
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
        humanDiceRolling = false
        pendingRoll = nil
        restoreRollOnStart = false
        cancelHumanAnalysis()
        analysisByPly = [:]
        let setup = record.handicap
        let starter = setup?.forcedStarter ?? startingPlayer
        if let setup {
            // Same handicap, fresh tokens (#148).
            discardPendingHandicapRoll()
            clearHint()
            lastComputerReroll = nil
            handicap = HandicapGameState(setup: setup)
        }
        record.setUpInitialPosition(on: game.board)
        game.dice.set(1, 1)
        game.setPlayer(starter)
        record = GameRecord(startingPlayer: starter, aiColor: record.aiColor,
                            variantID: record.variantID, handicap: setup)
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
        if handicap != nil { clearHint() }
        legalMoves = game.variant.legalMoves(on: game.board, color: game.currentPlayer, dice: game.dice)

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
        startMoveAnalysis()
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
        routeChoice = nil
    }

    /// Advance the turn (or end the game). Call `recordPly` first so the mover
    /// and dice are captured before `switchTurn` hands the turn to the opponent.
    private func finishTurn() {
        clearSelection()
        selectableSources = []

        if game.isOver() {
            let (winner, points) = recordOutcome()
            phase = .gameOver(winner: winner)
            if let winner { onGameOver?(winner) }
            onGameFinished?(winner, points)
            return
        }

        game.switchTurn()
        phase = .awaitingRoll
        maybeStartAITurn()
        maybeAutoRoll()
    }

    /// Write the finished game's result into `record` (winner, draw flag, and —
    /// for variants with 2-point wins — the points) and return it.
    @discardableResult
    private func recordOutcome() -> (winner: Color?, points: Int) {
        let result = game.outcome()
        record.outcome = result.winner
        record.isDraw = result.winner == nil
        if game.variant.maxPoints > 1 { record.points = result.points }
        return result
    }

    // ── Decision-point undo ──────────────────────────────────────────────────

    /// Undo is offered only while it's the human's move or between turns — never
    /// mid-AI-think, mid-animation, or once the game is over.
    private var isUndoablePhase: Bool {
        if preparingDice || hintPending { return false }   // only in handicap games (#148)
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
        for hm in moveBuilder.built.reversed() { game.variant.undoHalfMove(hm, on: game.board) }

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
            if let move = popped.move { game.variant.undo(move, on: game.board) }
        }
        // Keep record.plies in sync with undoHistory (both track one entry per turn).
        record.plies = Array(record.plies.prefix(target))
        pruneStaleAnalysis()   // drop in-play analysis (#146) of the rewound plies

        game.setPlayer(restoredColor)
        game.dice.set(d1, d2)
        markRolled()
        // The target was a real move, so the restored position has legal moves —
        // `beginTurn` lands in `picking` rather than auto-passing.
        beginTurn()
    }

    // ── AI turn ────────────────────────────────────────────────────────────────

    private func maybeStartAITurn() {
        guard isAITurn, phase == .awaitingRoll else { return }
        takeAITurn()
    }

    /// Fire the human's roll automatically (#116). No-op when auto-roll is off,
    /// when the AI owns the turn or outside `.awaitingRoll`.
    /// With animation on: pre-rolls (so the engine has the values), raises
    /// `humanDiceRolling` (the view masks faces like the AI tumble), waits out
    /// `aiDiceRollDuration`, then lowers the flag and calls `beginTurn`.
    /// With animation off: goes straight to `roll()`.
    private func maybeAutoRoll() {
        guard autoRoll, !isAITurn, phase == .awaitingRoll else { return }
        let rollDuration = animationTimings.aiDiceRollDuration
        autoRollTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if rollDuration > 0 {
                if self.weightedTiltForCurrentPlayer != nil {
                    guard await self.finishHandicappedRoll(self.startHandicappedRoll()) else { return }
                } else {
                    self.rollDice()
                }
                self.humanDiceRolling = true
                await GameSession.sleep(rollDuration)
                guard !Task.isCancelled else {
                    self.humanDiceRolling = false
                    return
                }
                self.humanDiceRolling = false
                self.beginTurn()
            } else {
                self.roll()
            }
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
        if handicap != nil, weightedTiltForCurrentPlayer != nil || computerMayReroll {
            takeHandicappedAITurn()
            return
        }
        rollDice()
        playAITurn(animateDiceRoll: true)
    }

    /// Continue the AI's turn with the dice already on the board: generate legal
    /// moves and either pass, play randomly (no model), or search off the main
    /// actor, then present the result. `animateDiceRoll` is true for a normal
    /// secret roll (tumble + masked reveal, #93) and false when resuming a restored
    /// pending roll (#171) — those dice are already shown, so we skip straight to
    /// the move animation.
    private func playAITurn(animateDiceRoll: Bool) {
        legalMoves = game.variant.legalMoves(on: game.board, color: game.currentPlayer, dice: game.dice)

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

        // Rank this position at full-strength 2-ply in the background — the same pass and
        // grading as a human turn (#108) — so the AI's ply is captured played-vs-best even
        // when its *play* search was weakened (1-ply + noise). No-op without a model/analysis.
        startMoveAnalysis()

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
            let copyMoves = config.variant.legalMoves(on: copyBoard, color: color, dice: dice)

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
                maxRootBranches: search.maxRootBranches,
                selectionNoise: search.selectionNoise
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
        game.variant.apply(move, on: game.board)
        recordTurn(mover: mover, move: move)
        captureMoveAnalysis(playedMove: move)
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
    /// configured duration for a secret roll, 0 for a restored roll where the dice
    /// are already on screen, #171).
    private func animateAITurn(move: Move?, score: Float?,
                               diceRollStarted: Date,
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
                landed.game.variant.applyHalfMove(hop, on: landed.game.board)
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
            s.captureMoveAnalysis(playedMove: move)
            s.finishTurn()
        }
    }

    /// Sleep helper for the animation driver; a non-positive duration returns
    /// immediately, so zeroed timings degrade to back-to-back publishes.
    private static func sleep(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // ── Handicap (#148, tier 1) ─────────────────────────────────────────────────
    // Only reached when `handicap != nil`.

    /// The weighted-dice β for the side on move, or `nil` when its dice are fair (no
    /// handicap, β = 0, no evaluator, or an undo replay queued — replays reproduce the
    /// recorded dice exactly).
    private var weightedTiltForCurrentPlayer: Double? {
        guard let handicap, handicapAgent != nil, diceReplays.isEmpty else { return nil }
        let beta = handicap.setup[currentPlayer].diceTilt
        return beta > 0 ? beta : nil
    }

    /// The computer on move has rerolls left (and a net to decide with).
    private var computerMayReroll: Bool {
        guard let handicap, handicapAgent != nil, isAITurn, diceReplays.isEmpty else { return false }
        return handicap.rerollsLeft[currentPlayer] > 0
    }

    /// The side on move is a human (vs the computer: the human; two players: both).
    private var isHumanTurn: Bool { aiColor == nil || currentPlayer != aiColor }

    /// Whether the human on move may reroll now: a handicap game, rerolls left, their
    /// own turn with the dice rolled (anything built this turn is taken back first).
    public var canReroll: Bool {
        guard let handicap, onMoveAttempt == nil, isHumanTurn, !preparingDice, !hintPending,
              phase == .picking || phase == .moving else { return false }
        return handicap.rerollsLeft[currentPlayer] > 0
    }

    /// Rerolls left for `color` (0 outside handicap games).
    public func rerollsLeft(_ color: Color) -> Int { handicap?.rerollsLeft[color] ?? 0 }
    /// Hints left for `color` (0 outside handicap games).
    public func hintsLeft(_ color: Color) -> Int { handicap?.hintsLeft[color] ?? 0 }

    /// Whether the human on move may ask for a hint now: hints left, a net to search
    /// with, their own turn with the dice rolled, and no hint already showing.
    public var canHint: Bool {
        guard let handicap, handicapAgent != nil, onMoveAttempt == nil, isHumanTurn,
              !preparingDice, !hintPending, hint == nil,
              phase == .picking || phase == .moving else { return false }
        return handicap.hintsLeft[currentPlayer] > 0
    }

    /// Spend a reroll (#148): take back anything built this turn and roll again —
    /// weighted when this side has weighted dice, fair otherwise.
    public func reroll() {
        guard canReroll else { return }
        takeBackBuiltMove()
        clearHint()
        cancelHumanAnalysis()
        selectableSources = []
        legalMoves = []
        handicap?.rerollsLeft[currentPlayer] -= 1
        phase = .awaitingRoll
        if weightedTiltForCurrentPlayer != nil {
            let pending = startHandicappedRoll()
            Task { @MainActor [weak self] in
                guard let self, await self.finishHandicappedRoll(pending) else { return }
                self.beginTurn()
            }
        } else {
            drawHandicapRoll(values: nil)
            beginTurn()
        }
    }

    /// Spend a hint (#148): search the turn's position at full strength (2-ply, the
    /// level-8 computer) off the main actor and publish the best move in `hint`
    /// without playing it. Anything built this turn is taken back first, since the hint
    /// is for the whole roll. The hint is only charged once it arrives; if the turn
    /// moves on first, it is dropped and not charged.
    public func requestHint() {
        guard canHint, let agent = handicapAgent else { return }
        if !moveBuilder.built.isEmpty {
            takeBackBuiltMove()
            refreshSources()
        }
        hintPending = true
        let epoch = hintEpoch
        let color = game.currentPlayer
        let config = game.board.config
        let stacks = game.board.captureStacks()
        let d1 = game.dice.die1.value
        let d2 = game.dice.die2.value
        let search = SearchConfig.standard
        Task.detached(priority: .userInitiated) { [weak self] in
            let board = GameBoard(config: config)
            board.restoreStacks(stacks)
            let dice = Dice(numberOfSides: config.dieSides)
            dice.set(d1, d2)
            let moves = config.variant.legalMoves(on: board, color: color, dice: dice)
            let best = try? agent.getBestMove(
                board, moves, color: color, timeBudget: search.timeBudget,
                beamThreshold: search.beamThreshold, relativeCutoff: search.relativeCutoff,
                maxBranch: search.maxBranch, maxDepth: search.maxDepth,
                rootSoftBudget: search.rootSoftBudget, minRootBranches: search.minRootBranches,
                maxRootBranches: search.maxRootBranches)
            let pairs = best?.move.halfMoves.map { [$0.from.position, $0.to.position] }
            await MainActor.run { [weak self] in
                guard let self, self.hintEpoch == epoch else { return }
                self.hintPending = false
                guard let pairs, !pairs.isEmpty else { return }
                self.hint = pairs
                self.handicap?.hintsLeft[color] -= 1
            }
        }
    }

    /// Await a pending hint (tests).
    func awaitHintForTesting() async {
        while hintPending { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Await a pending weighted roll (tests).
    func awaitDiceForTesting() async {
        while preparingDice { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    /// Drop any shown or pending hint (a pending one is then never charged).
    private func clearHint() {
        hintEpoch += 1
        hint = nil
        hintPending = false
    }

    /// Undo every half-move built this turn (reroll / hint start from the full roll).
    private func takeBackBuiltMove() {
        for hm in moveBuilder.built.reversed() { game.variant.undoHalfMove(hm, on: game.board) }
        moveBuilder = MoveBuilder(legalMoves: legalMoves, board: game.board,
                                  die1: game.dice.die1.value, die2: game.dice.die2.value)
        clearSelection()
    }

    /// Discard a weighted roll still being prepared.
    private func discardPendingHandicapRoll() {
        handicapEpoch += 1
        preparingDice = false
    }

    /// Rate the side on move's 21 rolls with the net, off the main actor (an isolated
    /// board copy, as the AI search does). `nil` without an evaluator or on a Core ML
    /// failure (the roll is then fair).
    private func computeRollValues() async -> [Float]? {
        guard let agent = handicapAgent else { return nil }
        let color = game.currentPlayer
        let config = game.board.config
        let stacks = game.board.captureStacks()
        return await Task.detached(priority: .userInitiated) {
            let board = GameBoard(config: config)
            board.restoreStacks(stacks)
            return try? HandicapDice.rollValues(agent: agent, board: board, color: color)
        }.value
    }

    /// Mark a weighted roll as being prepared (synchronously, so `preparingDice` blocks
    /// input at once) and return its epoch for `finishHandicappedRoll`.
    private func startHandicappedRoll() -> Int {
        preparingDice = true
        return handicapEpoch
    }

    /// Rate the rolls and draw a weighted roll for the side on move. Returns `false`
    /// when the roll went stale meanwhile (new game, scripted dice): nothing is set.
    private func finishHandicappedRoll(_ epoch: Int) async -> Bool {
        let values = await computeRollValues()
        guard handicapEpoch == epoch else { return false }
        preparingDice = false
        guard !Task.isCancelled else { return false }
        drawHandicapRoll(values: values)
        return true
    }

    /// Draw the side on move's dice from its handicap distribution — tilted by its β
    /// when `values` are known, fair otherwise — with `handicapUniform`, and publish
    /// them as the pending roll.
    private func drawHandicapRoll(values: [Float]?) {
        let beta = handicap?.setup[currentPlayer].diceTilt ?? 0
        let (d1, d2) = HandicapDice.weightedFaces(u1: handicapUniform(), u2: handicapUniform(),
                                                  values: values, beta: beta)
        game.dice.set(d1, d2)
        markRolled()
    }

    /// The computer's turn in a handicap game whose dice need the net: rate the rolls,
    /// draw (weighted or fair), apply the reroll rule while rerolls remain
    /// (`HandicapDice.shouldReroll`, the harness policy), then play as usual.
    private func takeHandicappedAITurn() {
        lastComputerReroll = nil
        phase = .aiThinking
        let epoch = handicapEpoch
        let turnEpoch = aiTurnEpoch
        preparingDice = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let values = await self.computeRollValues()
            guard self.handicapEpoch == epoch, self.aiTurnEpoch == turnEpoch else { return }
            self.preparingDice = false
            self.drawHandicapRoll(values: values)
            let mover = self.currentPlayer
            if let values {
                while self.rerollsLeft(mover) > 0,
                      HandicapDice.shouldReroll(values: values, d1: self.game.dice.die1.value,
                                                d2: self.game.dice.die2.value,
                                                beta: self.handicap?.setup[mover].diceTilt ?? 0) {
                    self.handicap?.rerollsLeft[mover] -= 1
                    self.lastComputerReroll = mover
                    self.drawHandicapRoll(values: values)
                }
            }
            self.playAITurn(animateDiceRoll: true)
        }
    }

    // ── Remote move (online multiplayer, #134) ──────────────────────────────────

    /// Apply a single ply received from a networked opponent (a Game Center
    /// turn-based match, #134). The session is a pure human-vs-human game
    /// (`aiColor == nil`); a remote move is structurally the AI move we already
    /// animate, so it funnels through the same presentation path — only the move's
    /// source differs (the wire, not a search).
    ///
    /// The ply carries its own dice (the active player rolled locally and broadcast
    /// them). We set those dice, regenerate the legal moves, and **validate by
    /// outcome**: the ply is legal iff applying it reaches the same board as some
    /// legal move for these dice. Outcome comparison (not half-move identity) is
    /// required because the same physical move is recorded differently depending on
    /// who composed it — a single-checker two-die move is stored *merged* (`1→9`) by
    /// the move generator but *unmerged* (`1→4,4→9`) when a human plays it through
    /// `MoveBuilder`; both replay to the identical position.
    ///
    /// Returns `false` without mutating the game when the ply is illegal, malformed,
    /// or arrives outside `.awaitingRoll` (a desync); the caller should then rebuild
    /// from the authoritative match log via `resume`. An empty `halfMoves` is a
    /// forced pass, legal only when there are no legal moves.
    @discardableResult
    public func applyRemoteMove(_ ply: PlyRecord) -> Bool {
        guard phase == .awaitingRoll else { return false }

        game.dice.set(ply.die1, ply.die2)
        let mover = game.currentPlayer
        let legal = game.variant.legalMoves(on: game.board, color: mover, dice: game.dice)

        // Forced pass: legal only when the mover genuinely has no move.
        if ply.halfMoves.isEmpty {
            guard legal.isEmpty else { return false }
            moveBuilder = MoveBuilder(legalMoves: [], board: game.board)
            if animationTimings.isAnimated {
                animateAITurn(move: nil, score: nil, diceRollStarted: Date(),
                              rollDuration: 0, epoch: aiTurnEpoch)
            } else {
                recordTurn(mover: mover, move: nil)
                finishTurn()
            }
            return true
        }

        guard let move = reconstructMove(ply, mover: mover),
              isLegalOutcome(move, among: legal) else { return false }

        moveBuilder = MoveBuilder(legalMoves: legal, board: game.board,
                                  die1: ply.die1, die2: ply.die2)
        if animationTimings.isAnimated {
            animateAITurn(move: move, score: nil, diceRollStarted: Date(),
                          rollDuration: 0, epoch: aiTurnEpoch)
        } else {
            game.variant.apply(move, on: game.board)
            recordTurn(mover: mover, move: move)
            finishTurn()
        }
        return true
    }

    /// Rebuild a `Move` from a ply's `[from, to]` index pairs against the live board,
    /// or `nil` if any pair is malformed or out of range. The half-moves hold the
    /// board's live `Point` objects, so the move can be applied/animated directly.
    private func reconstructMove(_ ply: PlyRecord, mover: Color) -> Move? {
        let upper = game.board.boardSize + 1
        var halfMoves: [HalfMove] = []
        for pair in ply.halfMoves {
            guard pair.count == 2 else { return nil }
            let from = pair[0], to = pair[1]
            guard (0...upper).contains(from), (0...upper).contains(to) else { return nil }
            halfMoves.append(HalfMove(from: game.board.points[from],
                                      to: game.board.points[to],
                                      color: mover))
        }
        return halfMoves.isEmpty ? nil : Move(halfMoves)
    }

    /// Whether `move` reaches the same position as some legal move for the current
    /// dice. Board mutations are bracketed by capture/restore so the live board is
    /// left exactly as found regardless of which branch matches.
    private func isLegalOutcome(_ move: Move, among legal: [Move]) -> Bool {
        let before = game.board.captureSnapshot()
        game.variant.apply(move, on: game.board)
        let target = game.board.captureStacks()
        game.board.restore(before)

        for candidate in legal {
            game.variant.apply(candidate, on: game.board)
            let outcome = game.board.captureStacks()
            game.board.restore(before)
            if outcome == target { return true }
        }
        return false
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
        markRolled()
    }

    /// Publish the dice now on the board as the current turn's pending roll (#171).
    private func markRolled() {
        pendingRoll = PendingRoll(die1: game.dice.die1.value, die2: game.dice.die2.value)
        rollRevision += 1
    }

    /// Re-enter the turn a save was taken in (#171) with its restored dice — no new
    /// roll, no tumble: the human lands in `.picking` (or the forced-pass path runs as
    /// it would have live); the AI searches and plays those dice.
    private func resumePendingRoll() {
        restoreRollOnStart = false
        guard phase == .awaitingRoll, let roll = pendingRoll else { return }
        game.dice.set(roll.die1, roll.die2)
        if isAITurn {
            playAITurn(animateDiceRoll: false)
        } else {
            beginTurn()
        }
    }

    // ── History recording ─────────────────────────────────────────────────────

    /// Append a finished turn to both `record.plies` (for replay/save) and
    /// `undoHistory` (for decision-point undo). Must be called before `finishTurn`
    /// switches the turn, while the dice still hold this ply's values.
    private func recordTurn(mover: Color, move: Move?) {
        pendingRoll = nil   // the roll is now part of the ply (#171)
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

    // ── In-play analysis (#146) ────────────────────────────────────────────────

    /// Kick off a background 2-ply ranking of the legal moves for the turn just begun, so
    /// the played move can be scored the instant it is committed. Runs for **both** the
    /// human's and the AI's turns (#108): the AI's *play* search may be weakened (1-ply +
    /// selection noise), but its ply must be graded by the same full-strength yardstick as
    /// the human's, so it gets the same 2-ply ranking here. Runs only when analysis is
    /// enabled, a model is present, and it is a real (non-drill) turn with moves to rank — a
    /// forced single move included, which the review scores too. The ranking is the *same*
    /// `evaluateMovesNply(depth: 2)` over the *same* `legalMoves` the post-game review uses,
    /// so the captured scores match a from-scratch review exactly. It scores an isolated
    /// board copy off the main actor (exactly as the AI search does) and stores its result
    /// only if the turn hasn't moved on (the epoch still matches).
    private func startMoveAnalysis() {
        cancelHumanAnalysis()
        guard inPlayAnalysisEnabled, onMoveAttempt == nil,
              let agent, !legalMoves.isEmpty else { return }

        let epoch = analysisEpoch
        let color = game.currentPlayer
        let search = searchConfig
        let config = game.board.config
        let stacks = game.board.captureStacks()
        let d1 = game.dice.die1.value
        let d2 = game.dice.die2.value
        humanAnalysisTask = Task.detached(priority: .utility) { [weak self] in
            let board = GameBoard(config: config)
            board.restoreStacks(stacks)
            let dice = Dice(numberOfSides: config.dieSides)
            dice.set(d1, d2)
            // Move generation is deterministic, so this copy's moves match the live
            // `legalMoves` index-for-index — the score at index i grades `legalMoves[i]`.
            let copyMoves = config.variant.legalMoves(on: board, color: color, dice: dice)
            let scores = try? agent.evaluateMovesNply(
                board, copyMoves, color: color, depth: 2,
                beamThreshold: search.beamThreshold, relativeCutoff: search.relativeCutoff,
                maxBranch: search.maxBranch, deadline: nil)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.analysisEpoch == epoch,
                      let scores, scores.count == self.legalMoves.count else { return }
                self.humanAnalysisScores = scores
            }
        }
    }

    /// Record the just-committed ply's 2-ply analysis from the background ranking, if it
    /// finished in time. Used for **both** sides (#108): the played move (the human's, or
    /// the AI's possibly-weakened pick) is keyed to its score by net board delta and the
    /// best to the argmax — the exact selection `GameReview` uses — so the stored entry is
    /// identical to a from-scratch depth-2 review of this ply. If the ranking isn't ready
    /// (the mover committed faster than it computed), nothing is stored and the post-game
    /// review fills this ply in. Call right after `recordTurn`, so `record.plies.count` is
    /// this ply's 1-based number.
    private func captureMoveAnalysis(playedMove move: Move) {
        guard inPlayAnalysisEnabled,
              let scores = humanAnalysisScores, scores.count == legalMoves.count,
              let bestIdx = GameReview.argmax(scores),
              var playedIdx = GameReview.matchRecorded(pairs(of: move), legalMoves) else { return }
        if GameReview.deltaMatchCount(pairs(of: move), legalMoves) > 1, let mover = move.halfMoves.first?.color {
            // Ambiguous by net delta (Portes hits): match by resulting position on the
            // pre-move board, then put the played move back.
            game.variant.undo(move, on: game.board)
            playedIdx = GameReview.matchRecorded(pairs(of: move), legalMoves, on: game.board, mover: mover) ?? playedIdx
            game.variant.apply(move, on: game.board)
        }
        let plyNumber = record.plies.count
        analysisByPly[plyNumber] = AnalysisEntry(
            plyNumber: plyNumber,
            playedMove: pairs(of: move),
            playedScore: Double(scores[playedIdx]),
            bestMove: pairs(of: legalMoves[bestIdx]),
            bestScore: Double(scores[bestIdx]),
            depth: 2)
    }

    /// Cancel any in-flight human ranking and drop its (now stale) result, bumping the
    /// epoch so a late completion discards itself. Called whenever the position the
    /// ranking was computed for is left (a new turn, step-back, surrender, or new game).
    private func cancelHumanAnalysis() {
        humanAnalysisTask?.cancel()
        humanAnalysisTask = nil
        humanAnalysisScores = nil
        analysisEpoch += 1
    }

    /// Drop in-play analysis (#146) for plies past the current history length after a
    /// step-back rewinds part of the game. `analysisByPly` is keyed by ply number, so an
    /// entry from an undone line would otherwise survive and be mis-keyed onto the
    /// *re-played* ply's position in the post-game review/drill — surfacing a move that no
    /// longer fits the board (an "impossible" position). Re-played plies re-capture their
    /// own analysis, so anything within the new length is left untouched. Call right after
    /// truncating `record.plies`.
    private func pruneStaleAnalysis() {
        analysisByPly = analysisByPly.filter { $0.key <= record.plies.count }
    }

    /// The `[from, to]` half-move pairs of a move, in stored order — the same shape
    /// `recordTurn` and `AnalysisEntry` use.
    private func pairs(of move: Move) -> [[Int]] {
        move.halfMoves.map { [$0.from.position, $0.to.position] }
    }

    // ── In-play analysis: testing seams (#146) ────────────────────────────────
    // `internal`, so they reach `@testable` tests but never the app (a separate module
    // that imports only the public surface). They let a test commit a human move only
    // once its background ranking is ready, and observe cancellation.

    /// Whether the human ranking has finished and its scores are staged for capture.
    var inPlayAnalysisReadyForTesting: Bool { humanAnalysisScores != nil }
    /// Whether a human ranking task is currently retained (cleared on cancel).
    var inPlayAnalysisTaskActiveForTesting: Bool { humanAnalysisTask != nil }
    /// Await the in-flight human ranking so a test can act once its scores are ready.
    func awaitInPlayAnalysisForTesting() async { await humanAnalysisTask?.value }

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
                             config: GameConfig? = nil) -> GameSession {
        // Default to the agent's variant (#136), else Plakoto.
        let config = config ?? agent.map { GameConfig(variant: $0.variant) } ?? .standard
        let session = GameSession(startingPlayer: mover, config: config, agent: agent, aiColor: nil)
        for i in session.game.board.points.indices where i < boardStacks.count {
            session.game.board.setPoint(i, pieces: boardStacks[i])
        }
        session.setDice(die1, die2)   // → beginTurn → .picking at this position
        return session
    }

    // ── Resume from a save ────────────────────────────────────────────────────

    /// Rebuild a session from a save by replaying its history from the initial
    /// position. The returned session sits at the resumed player's `awaitingRoll`
    /// (or `gameOver` if the recorded game already ended). Call `start()` afterward
    /// — exactly as for a new game — so the AI takes its turn if it owns the move.
    /// A save taken mid-turn carries that turn's `pendingRoll` (#171): the session is
    /// returned at `.awaitingRoll` with those dice set and published, and `start()`
    /// re-enters the turn with them (human → `.picking`, AI → plays them) instead of
    /// rolling — regardless of auto-roll.
    /// `config` defaults to the save's own variant (#136; Plakoto for pre-variant saves).
    public static func resume(from save: GameSave,
                              config: GameConfig? = nil,
                              agent: Agent? = nil,
                              searchConfig: SearchConfig = .standard,
                              animationTimings: AnimationTimings = .standard,
                              autoRoll: Bool = false,
                              inPlayAnalysis: Bool = false,
                              handicapAgent: Agent? = nil) -> GameSession {
        let starting = Color(rawValue: save.startingPlayer) ?? .black
        let aiColor = save.aiColor.flatMap { Color(rawValue: $0) }
        let session = GameSession(startingPlayer: starting,
                                  config: config ?? GameConfig(variantID: save.variant),
                                  agent: agent,
                                  aiColor: aiColor,
                                  searchConfig: searchConfig,
                                  animationTimings: animationTimings,
                                  autoRoll: autoRoll,
                                  inPlayAnalysis: inPlayAnalysis,
                                  handicap: save.handicap?.setup,
                                  handicapAgent: handicapAgent)
        // Restore the tokens left (#148); the start position already has the head start.
        if let saved = save.handicap, let live = session.handicap {
            session.handicap = HandicapGameState(setup: live.setup,
                                                 rerollsLeft: saved.rerollsLeft,
                                                 hintsLeft: saved.hintsLeft)
        }
        session.replay(save.history)
        // Restore the roll of the turn in progress (#171); `start()` re-enters that
        // turn with it. Invalid dice (already dropped on decode) or a finished game
        // fall back to awaiting a roll, as before.
        if let roll = save.pendingRoll, roll.isValid, !session.isTerminal {
            session.game.dice.set(roll.die1, roll.die2)
            session.pendingRoll = roll
            session.restoreRollOnStart = true
        }
        return session
    }

    /// Apply each recorded half-move directly to the board, alternating the mover
    /// every ply (a pass still passes the turn). Uses the variant's `applyHalfMove`
    /// without re-deriving legal moves, so the
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
        pendingRoll = nil
        restoreRollOnStart = false

        for ply in plies {
            for pair in ply.halfMoves where pair.count == 2 {
                let from = pair[0], to = pair[1]
                guard (0...upper).contains(from), (0...upper).contains(to) else { continue }
                game.variant.applyHalfMove(
                    HalfMove(from: board.points[from], to: board.points[to], color: mover),
                    on: board)
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

        if game.isOver() {
            phase = .gameOver(winner: recordOutcome().winner)
        } else {
            phase = .awaitingRoll
            refreshEvaluation()
        }
    }
}
