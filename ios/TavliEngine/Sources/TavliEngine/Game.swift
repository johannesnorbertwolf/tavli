import Foundation

/// Mirrors `game/game.py`. Rules come from `config.variant` (#136).
public final class Game {
    public let board: GameBoard
    public let dice: Dice
    public private(set) var player: Color

    public init(config: GameConfig = .standard, startingPlayer: Color = .black) {
        self.board = GameBoard(config: config)
        config.variant.setUpInitialPosition(on: board)
        self.dice = Dice(numberOfSides: config.dieSides)
        self.player = startingPlayer
    }

    /// The rules this game is played under.
    public var variant: any GameVariant { board.config.variant }

    public var currentPlayer: Color { player }

    public func switchTurn() {
        player = (player == .white) ? .black : .white
    }

    public func setPlayer(_ color: Color) {
        player = color
    }

    public func isOver() -> Bool {
        getWinner() != nil
    }

    public func getWinner() -> Color? {
        variant.winner(on: board)
    }

    public func checkWinner(_ color: Color) -> Bool {
        variant.hasWon(color, on: board)
    }
}
