import Foundation

/// Static game parameters. Matches `config/config.yml` (board_size 24, pieces 15,
/// home 6, 6-sided dice) and the `board_spec` baked into `gold_v9.pth`.
public struct GameConfig: Sendable, Hashable {
    public let boardSize: Int
    public let piecesPerPlayer: Int
    public let homeSize: Int
    public let dieSides: Int

    public init(boardSize: Int = 24, piecesPerPlayer: Int = 15, homeSize: Int = 6, dieSides: Int = 6) {
        self.boardSize = boardSize
        self.piecesPerPlayer = piecesPerPlayer
        self.homeSize = homeSize
        self.dieSides = dieSides
    }

    public static let standard = GameConfig()
}
