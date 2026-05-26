import SwiftUI

@main
struct TavliApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color(hex: 0xece6dc).ignoresSafeArea()
                BoardView()
                    .padding(24)
            }
        }
    }
}
