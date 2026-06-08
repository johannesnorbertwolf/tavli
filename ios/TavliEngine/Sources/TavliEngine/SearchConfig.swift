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
/// they tune the on-device root expansion only. `maxDepth` also intentionally differs:
/// the CLI caps at 2, but on-device play targets a full 3-ply search.
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
    /// Target search depth. The default `3` aims for a full 3-ply search (the CLI caps at 2).
    public var maxDepth: Int?
    /// Soft budget (seconds) for *widening* the root: after `minRootBranches`, a new
    /// root branch is only started while elapsed time is under this.
    public var rootSoftBudget: TimeInterval
    /// Root branches always expanded at `maxDepth` (subject to `timeBudget`), regardless of the soft budget.
    public var minRootBranches: Int
    /// Hard ceiling on how many root branches are ever expanded at `maxDepth`.
    public var maxRootBranches: Int

    public init(timeBudget: TimeInterval = 20.0,
                beamThreshold: Float = 0.08,
                relativeCutoff: Float? = 0.08,
                maxBranch: Int? = 4,
                maxDepth: Int? = 3,
                rootSoftBudget: TimeInterval = 8.0,
                minRootBranches: Int = 2,
                maxRootBranches: Int = 5) {
        self.timeBudget = timeBudget
        self.beamThreshold = beamThreshold
        self.relativeCutoff = relativeCutoff
        self.maxBranch = maxBranch
        self.maxDepth = maxDepth
        self.rootSoftBudget = rootSoftBudget
        self.minRootBranches = minRootBranches
        self.maxRootBranches = maxRootBranches
    }

    /// Default on-device search configuration.
    public static let standard = SearchConfig()
}
