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
                // Single caramel (light) design: system controls must not turn
                // dark-styled in system dark mode (Info.plist pins it app-wide too,
                // covering sheets, alerts and Game Center's own controllers).
                .preferredColorScheme(.light)
        }
    }
}
