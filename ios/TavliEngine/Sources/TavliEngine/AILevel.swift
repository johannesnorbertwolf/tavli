import Foundation

/// The AI's playing level, 1…8 (#189) — replaces the #108 strength slider. Each level maps
/// onto the two `SearchConfig` difficulty knobs (`maxDepth`, `selectionNoise`):
///
/// | Level | Search | Selection noise σ |
/// |---|---|---|
/// | 8 | 2-ply (full strength) | 0 |
/// | 7 | 1-ply | 0 |
/// | 6 | 1-ply | 0.010 |
/// | 5 | 1-ply | 0.020 |
/// | 4 | 1-ply | 0.035 |
/// | 3 | 1-ply | 0.050 |
/// | 2 | 1-ply | 0.070 |
/// | 1 | 1-ply | 0.100 (= the old slider's weakest, `legacySigmaMax`) |
///
/// The noise curve is convex on purpose: σ is Gaussian noise on win-probability move
/// scores, so a small σ only swaps near-equal moves (barely weaker) while larger σ starts
/// passing up clearly better ones. Spacing the steps wider toward level 1 keeps each step
/// a noticeable change instead of bunching the weak end together. The noise only touches
/// `getBestMove`'s final 1-ply pick; analysis stays full-strength and noise-free.
public enum AILevel {
    /// The valid levels, weakest first.
    public static let range: ClosedRange<Int> = 1...8
    /// Full strength (the default).
    public static let max = 8
    public static let min = 1

    /// `UserDefaults` key of the stored level (an `Int`).
    public static let storageKey = "settings.aiLevel"
    /// The retired #108 strength slider's key (`Double` 0…1); read once by `migrate`.
    public static let legacyStrengthKey = "settings.aiStrength"
    /// The old slider's largest σ (its weakest end) — level 1 keeps it.
    public static let legacySigmaMax: Float = 0.10

    /// Selection-noise σ per level (index = level − 1).
    static let noiseTable: [Float] = [0.100, 0.070, 0.050, 0.035, 0.020, 0.010, 0, 0]

    /// `level` forced into `range`.
    public static func clamped(_ level: Int) -> Int {
        Swift.min(Swift.max(level, range.lowerBound), range.upperBound)
    }

    /// Search depth for `level`: 2-ply at full strength, else 1-ply.
    public static func maxDepth(for level: Int) -> Int {
        clamped(level) == max ? 2 : 1
    }

    /// Selection-noise σ for `level` (0 at levels 7 and 8).
    public static func selectionNoise(for level: Int) -> Float {
        noiseTable[clamped(level) - 1]
    }

    /// The play search for `level`: `base` with only `maxDepth` / `selectionNoise` changed,
    /// so the analysis-facing fields stay standard.
    public static func searchConfig(for level: Int, base: SearchConfig = .standard) -> SearchConfig {
        var c = base
        c.maxDepth = maxDepth(for: level)
        c.selectionNoise = selectionNoise(for: level)
        return c
    }

    /// The level nearest a legacy slider value (0…1): 1.0 was full strength (→ 8); below
    /// that the slider played 1-ply with σ = `legacySigmaMax`·(1 − strength), mapped to
    /// the 1-ply level (7…1) with the closest σ (ties → the stronger level).
    public static func nearest(toLegacyStrength strength: Double) -> Int {
        if strength >= 1.0 { return max }
        let s = Swift.max(0, strength)
        let sigma = legacySigmaMax * Float(1.0 - s)
        var best = 7
        var bestDistance = Float.infinity
        for level in stride(from: 7, through: 1, by: -1) {
            let d = abs(selectionNoise(for: level) - sigma)
            if d < bestDistance - 1e-6 {
                best = level
                bestDistance = d
            }
        }
        return best
    }

    /// The stored level (default full strength), clamped.
    public static func load(from defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: storageKey) != nil else { return max }
        return clamped(defaults.integer(forKey: storageKey))
    }

    /// One-time migration of the retired strength slider (#189): when no level is stored
    /// but a slider value is, store its nearest level and drop the old key. Idempotent.
    public static func migrate(_ defaults: UserDefaults = .standard) {
        guard let strength = defaults.object(forKey: legacyStrengthKey) as? Double else { return }
        if defaults.object(forKey: storageKey) == nil {
            defaults.set(nearest(toLegacyStrength: strength), forKey: storageKey)
        }
        defaults.removeObject(forKey: legacyStrengthKey)
    }
}

/// The human's side for new games (#189): `white`, `random` (a side drawn per new game)
/// or `black` ("Red" in the UI). Replaces #77's `ask`, which `migrate` rewrites to
/// `random`. The raw values are the persisted `UserDefaults` strings.
public enum PlayAsPreference {
    public static let storageKey = "settings.preferredColor"
    /// The retired "ask on the start screen" value.
    public static let legacyAsk = "ask"
    public static let random = "random"

    /// Rewrites a stored `ask` to `random`. Idempotent.
    public static func migrate(_ defaults: UserDefaults = .standard) {
        if defaults.string(forKey: storageKey) == legacyAsk {
            defaults.set(random, forKey: storageKey)
        }
    }
}
