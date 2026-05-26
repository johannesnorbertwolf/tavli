import Foundation

/// Mirrors `game/game.py`.
public final class Game {
    public let board: GameBoard
    public let dice: Dice
    public private(set) var player: Color

    public init(config: GameConfig = .standard, startingPlayer: Color = .black) {
        self.board = GameBoard(config: config)
        self.board.initializeBoard()
        self.dice = Dice(numberOfSides: config.dieSides)
        self.player = startingPlayer
    }

    public var currentPlayer: Color { player }

    public func switchTurn() {
        player = (player == .white) ? .black : .white
    }

    public func isOver() -> Bool {
        board.hasWon(.white) || board.hasWon(.black)
    }

    public func getWinner() -> Color? {
        if board.hasWon(.white) { return .white }
        if board.hasWon(.black) { return .black }
        return nil
    }

    public func checkWinner(_ color: Color) -> Bool {
        board.hasWon(color)
    }
}
