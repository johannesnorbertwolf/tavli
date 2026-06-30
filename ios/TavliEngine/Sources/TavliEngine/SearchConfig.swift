import Foundation

/// Knobs for the on-device expectimax search. The leaf scoring and the inner
/// pruning mirror the CLI's `config/config.yml` search section so move *evaluation*
/// matches `./run.sh play`, but the **root search strategy is iOS-specific**: an
/// anytime, best-first root expansion with a time-gated branching factor (see
/// `Agent.getBestMove`), rather than the CLI's plain iterative deepening.
///
/// | Swift field      | config.yml key          |
/// |------------------|-------------------------|
/// | `timeBudget`     | `play_time_budget_s`    |
/// | `beamThreshold`  | `beam_threshold`        |
/// | `relativeCutoff` | `search_relative_cutoff`|
/// | `maxBranch`      | `search_max_branch`     |
/// | `maxDepth`       | `search_max_depth`      |
///
/// `rootSoftBudget`, `minRootBranches`, and `maxRootBranches` have no CLI equivalent —
/// they tune the on-device root expansion only. On-device play defaults to **2-ply**
/// (`maxDepth: 2`): fast, with typical turns effectively instant. The search still
/// *supports* anytime deepening to 3-ply (set `maxDepth: 3`), but that's opt-in — the
/// 3-ply worst case (a huge-branching doubles roll) can take the full `timeBudget`.
///
/// **Difficulty (#108).** Two of these knobs double as the AI-strength dial driven by the
/// settings slider: full strength is the default 2-ply argmax (`maxDepth: 2`,
/// `selectionNoise: 0`); a weaker opponent drops to `maxDepth: 1` and raises
/// `selectionNoise` so the 1-ply move pick is perturbed (see `Agent.getBestMove`). The
/// noise lives *only* in the final root selection, so the leaf scoring used by analysis
/// (`evaluateMovesNply`) stays full-strength and noise-free regardless of this setting.
public struct SearchConfig: Sendable, Hashable {
    /// Hard wall-clock cap per move (seconds). The root expansion never starts a new
    /// branch past this, and a branch that overruns it is abandoned (best-so-far kept).
    public var timeBudget: TimeInterval
    /// Absolute beam fallback, used only when `relativeCutoff` is nil.
    public var beamThreshold: Float
    /// Keep replies whose score is within this relative fraction of the best (`score >= best*(1-cutoff)`).
    public var relativeCutoff: Float?
    /// Cap on replies expanded per **inner** (2nd/3rd-level) search node, on top of `relativeCutoff`.
    public var maxBranch: Int?
    /// Target search depth. The default `2` runs a 2-ply search; `3`+ enables anytime
    /// deepening on top of the 2-ply baseline (see `Agent.getBestMove`).
    public var maxDepth: Int?
    /// Soft budget (seconds) for *widening* the root during deepening: after
    /// `minRootBranches`, a new branch is only deepened while elapsed time is under this.
    /// Only relevant when `maxDepth >= 3`.
    public var rootSoftBudget: TimeInterval
    /// Candidates always deepened (subject to `timeBudget`), regardless of the soft budget.
    /// Only relevant when `maxDepth >= 3`.
    public var minRootBranches: Int
    /// Hard ceiling on the root candidate set (the moves scored at the baseline depth, and
    /// the most that are ever deepened).
    public var maxRootBranches: Int
    /// Std-dev of the Gaussian noise added to the **root move scores before the final pick**
    /// (#108 difficulty). `0` (the default) is full-strength argmax — identical to the old
    /// behaviour. A positive value makes a weaker opponent occasionally play a non-best move;
    /// `getBestMove` applies it only in the 1-ply path the slider drops to below full strength.
    public var selectionNoise: Float

    public init(timeBudget: TimeInterval = 20.0,
                beamThreshold: Float = 0.08,
                relativeCutoff: Float? = 0.08,
                maxBranch: Int? = 4,
                maxDepth: Int? = 2,
                rootSoftBudget: TimeInterval = 8.0,
                minRootBranches: Int = 2,
                maxRootBranches: Int = 5,
                selectionNoise: Float = 0) {
        self.timeBudget = timeBudget
        self.beamThreshold = beamThreshold
        self.relativeCutoff = relativeCutoff
        self.maxBranch = maxBranch
        self.maxDepth = maxDepth
        self.rootSoftBudget = rootSoftBudget
        self.minRootBranches = minRootBranches
        self.maxRootBranches = maxRootBranches
        self.selectionNoise = selectionNoise
    }

    /// Default on-device search configuration.
    public static let standard = SearchConfig()
}
