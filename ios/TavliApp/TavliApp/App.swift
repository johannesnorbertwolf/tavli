import SwiftUI
import UIKit
import BoardGeometry

@main
struct TavliApp: App {
    init() {
        // Compact chrome type on a phone-sized screen (#109); 1 (unchanged) on iPad.
        ChromeType.scale = ChromeLayout.fontScale(forScreen: UIScreen.main.bounds.size)
        // Retired settings (#189): strength slider → level, Play as "Ask" → Random.
        // Before RootView's init, whose cold-launch resume reads the search config.
        AppSettings.migrateLegacySettings()
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
