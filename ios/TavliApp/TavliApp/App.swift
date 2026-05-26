import SwiftUI
import TavliEngine

@main
struct TavliApp: App {
    /// Plakoto start position (15 white@1, 15 black@24 → rendered red).
    private static let startBoard: GameBoard = {
        let board = GameBoard()
        board.initializeBoard()
        return board
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(hex: 0xece6dc).ignoresSafeArea()
                ZStack {
                    BoardView()
                    CheckersView(points: Self.startBoard.points)
                }
                .padding(24)
            }
        }
    }
}
