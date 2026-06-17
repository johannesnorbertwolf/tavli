import SwiftUI

/// App entry for the Weltsensation super-app. Three states:
///  1. `-uiTestGame` launch arg → the original `RootView` deterministic game,
///     so the existing board-interaction UI test keeps working (gate bypassed).
///  2. Locked → `LockView` (the one-time password gate).
///  3. Unlocked → `TournamentRootView` (the tournament shell).
///
/// `@AppStorage` on the shared unlock key means unlocking inside `LockView` (or
/// re-locking from Setup) flips this view automatically.
struct AppRoot: View {
    @AppStorage(WeltsensationKey.unlocked) private var unlocked = false

    private var isUITestGame: Bool {
        ProcessInfo.processInfo.arguments.contains("-uiTestGame")
    }

    var body: some View {
        if isUITestGame {
            RootView()
        } else if unlocked {
            TournamentRootView()
                .environment(\.locale, GermanLocale.locale)
        } else {
            LockView()
                .environment(\.locale, GermanLocale.locale)
        }
    }
}

/// Pins the Weltsensation app to German regardless of the device language
/// (Johannes' iPad is set to Dutch). Two layers, because no single one covers
/// everything:
///  - `.environment(\.locale, GermanLocale.locale)` on the real screens drives
///    SwiftUI's own `Text(_:)` / `LocalizedStringKey` resolution and number/date
///    formatting.
///  - `pinMainBundle()` (called once at launch from `TavliApp.init`) swaps the
///    class of `Bundle.main` so `String(localized:)` / `NSLocalizedString` — which
///    the reused game chrome uses and which ignore the environment locale — answer
///    from the bundled `de.lproj`.
enum GermanLocale {
    static let locale = Locale(identifier: "de")

    /// Idempotent; safe to call more than once.
    static func pinMainBundle() {
        guard !(Bundle.main is GermanBundle) else { return }
        object_setClass(Bundle.main, GermanBundle.self)
    }
}

/// A `Bundle` whose localized-string lookups are answered from `de.lproj`, so the
/// whole app reads German no matter the device language. Installed onto `Bundle.main`
/// via `object_setClass` (see `GermanLocale.pinMainBundle`).
private final class GermanBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let path = Bundle.main.path(forResource: "de", ofType: "lproj"),
              let german = Bundle(path: path) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return german.localizedString(forKey: key, value: value, table: tableName)
    }
}
