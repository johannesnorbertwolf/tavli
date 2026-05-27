import SwiftUI
import TavliEngine

@main
struct TavliApp: App {
    /// White-to-move from the start position with dice 3·5 — reproduces the
    /// design's reference highlight scenario (tap point 1 → targets 4, 6, 9) so
    /// T7 input/highlight is testable. Dice UI (T8) and screen assembly (T10)
    /// replace this bootstrap.
    @StateObject private var session: GameSession = {
        let session = GameSession(startingPlayer: .white)
        session.setManualDice(3, 5)
        return session
    }()

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(hex: 0xece6dc).ignoresSafeArea()
                PlayableBoardView(session: session)
                    .padding(24)
            }
        }
    }
}
