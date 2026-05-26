import SwiftUI

@main
struct TavliApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.12, blue: 0.14).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Plakoto")
                    .font(.custom("Cormorant Garamond", size: 84))
                    .foregroundStyle(.white)
                Text("Tavli for iPad")
                    .font(.custom("Inter", size: 22))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}
