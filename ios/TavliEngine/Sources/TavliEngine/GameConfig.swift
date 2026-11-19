import Foundation

/// Static game parameters. Matches `config/config.yml` (board_size 24, pieces 15,
/// home 6, 6-sided dice) and the `board_spec` baked into `gold_v9.pth`, plus the
/// rules `variant` (#136) — the single place the shared infrastructure learns which
/// game it is playing. `.standard` is Plakoto.
public struct GameConfig: Sendable, Hashable {
    public let boardSize: Int
    public let piecesPerPlayer: Int
    public let homeSize: Int
    public let dieSides: Int
    /// The rules in force. Equality/hashing go by `variant.id`.
    public let variant: any GameVariant
    /// Tier-2 handicap rules (#148 P3b; house Plakoto only), `nil` = the normal game.
    /// Part of the config so every board copy (`GameBoard(config: board.config)`) plays
    /// the same rules. `piecesPerPlayer` stays the model's 15; per-side counts live here.
    public let handicapRules: HandicapRules?

    public init(boardSize: Int = 24, piecesPerPlayer: Int = 15, homeSize: Int = 6, dieSides: Int = 6,
                variant: any GameVariant = GameVariants.plakoto, handicapRules: HandicapRules? = nil) {
        self.boardSize = boardSize
        self.piecesPerPlayer = piecesPerPlayer
        self.homeSize = homeSize
        self.dieSides = dieSides
        self.variant = variant
        self.handicapRules = handicapRules
    }

    public static let standard = GameConfig()

    /// The standard config for a persisted variant id. An id this build doesn't know
    /// (a save from a newer build) falls back to Plakoto.
    public init(variantID: String) {
        self.init(variant: GameVariants.variant(forID: variantID) ?? GameVariants.plakoto)
    }

    public static func == (lhs: GameConfig, rhs: GameConfig) -> Bool {
        lhs.boardSize == rhs.boardSize && lhs.piecesPerPlayer == rhs.piecesPerPlayer
            && lhs.homeSize == rhs.homeSize && lhs.dieSides == rhs.dieSides
            && lhs.variant.id == rhs.variant.id && lhs.handicapRules == rhs.handicapRules
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(boardSize)
        hasher.combine(piecesPerPlayer)
        hasher.combine(homeSize)
        hasher.combine(dieSides)
        hasher.combine(variant.id)
        hasher.combine(handicapRules)
    }
}
