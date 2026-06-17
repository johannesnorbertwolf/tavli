import SwiftUI

@main
struct TavliApp: App {
    init() {
        // Weltsensation is German-only, even on a Dutch (or any) device: pin the
        // main bundle to `de` so the reused game chrome's `String(localized:)` /
        // `NSLocalizedString` lookups (turn indicator, dice subtitle, "White"/"Red")
        // resolve German — those ignore SwiftUI's environment locale. Skipped for the
        // `-uiTestGame` path, whose UI test asserts the English base strings.
        if !ProcessInfo.processInfo.arguments.contains("-uiTestGame") {
            GermanLocale.pinMainBundle()
        }
    }

    var body: some Scene {
        WindowGroup {
            // Weltsensation super-app: the password gate + tournament shell.
            // (The original Play-vs-AI flow lives on in `RootView`, reused for
            // tournament games and the `-uiTestGame` path.)
            AppRoot()
        }
    }
}
