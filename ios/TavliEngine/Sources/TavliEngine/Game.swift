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

    /// The game has ended — a win, or (standard Plakoto) a draw. Via the variant.
    public func isOver() -> Bool {
        variant.isOver(on: board)
    }

    /// The winner once the game is over; `nil` while running **or for a draw**.
    public func getWinner() -> Color? {
        variant.winner(on: board)
    }

    /// `(winner, points)` of the finished game (`winner == nil`: draw). Only
    /// meaningful when `isOver()`.
    public func outcome() -> (winner: Color?, points: Int) {
        variant.outcome(on: board)
    }

    public func checkWinner(_ color: Color) -> Bool {
        variant.hasWon(color, on: board)
    }
}
