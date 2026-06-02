import Foundation

/// Knobs for the iterative-deepening expectimax search, mirroring the CLI's
/// `config/config.yml` search section so on-device play matches `./run.sh play`.
///
/// | Swift field      | config.yml key          |
/// |------------------|-------------------------|
/// | `timeBudget`     | `play_time_budget_s`    |
/// | `beamThreshold`  | `beam_threshold`        |
/// | `relativeCutoff` | `search_relative_cutoff`|
/// | `maxBranch`      | `search_max_branch`     |
/// | `maxDepth`       | `search_max_depth`      |
public struct SearchConfig: Sendable, Hashable {
    /// Safety ceiling per move (seconds); the search usually finishes earlier via `maxDepth`.
    public var timeBudget: TimeInterval
    /// Absolute beam fallback, used only when `relativeCutoff` is nil.
    public var beamThreshold: Float
    /// Keep replies whose score is within this relative fraction of the best (`score >= best*(1-cutoff)`).
    public var relativeCutoff: Float?
    /// Hard cap on moves expanded per search node, applied on top of `relativeCutoff`.
    public var maxBranch: Int?
    /// Iterative-deepening ceiling.
    public var maxDepth: Int?

    public init(timeBudget: TimeInterval = 20.0,
                beamThreshold: Float = 0.08,
                relativeCutoff: Float? = 0.08,
                maxBranch: Int? = 5,
                maxDepth: Int? = 2) {
        self.timeBudget = timeBudget
        self.beamThreshold = beamThreshold
        self.relativeCutoff = relativeCutoff
        self.maxBranch = maxBranch
        self.maxDepth = maxDepth
    }

    /// Defaults matching `config/config.yml` (the values the CLI plays with).
    public static let standard = SearchConfig()
}
