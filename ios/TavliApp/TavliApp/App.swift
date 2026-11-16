import SwiftUI
import UIKit
import BoardGeometry

@main
struct TavliApp: App {
    init() {
        // Compact chrome type on a phone-sized screen (#109); 1 (unchanged) on iPad.
        ChromeType.scale = ChromeLayout.fontScale(forScreen: UIScreen.main.bounds.size)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
