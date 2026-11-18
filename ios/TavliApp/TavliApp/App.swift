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
        Self.styleDarkSegmentedControls()
    }

    /// #191: the stock dark segmented control is a neutral system grey that clashes with
    /// the espresso chrome. Restyle it for the **dark** trait only (light keeps the
    /// system look, unchanged): a recessed espresso track, a warm raised segment and the
    /// cream / tan chrome inks.
    private static func styleDarkSegmentedControls() {
        let seg = UISegmentedControl.appearance(for: UITraitCollection(userInterfaceStyle: .dark))
        seg.backgroundColor = UIColor(hex: 0x0e0805)
        seg.selectedSegmentTintColor = UIColor(hex: 0x4a3320)
        seg.setTitleTextAttributes([.foregroundColor: UIColor(hex: 0xcf9f62)], for: .normal)
        seg.setTitleTextAttributes([.foregroundColor: UIColor(hex: 0xf4d7a4)], for: .selected)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modifier(AppearanceOverride())
        }
    }
}

/// Applies the Appearance setting (#191: System / Light / Dark, default System) as
/// every window's `overrideUserInterfaceStyle`. A window-level override (rather than
/// `.preferredColorScheme`) also reaches sheets, alerts and Game Center's own view
/// controllers, and returns cleanly to the system style on `.system`.
private struct AppearanceOverride: ViewModifier {
    @AppStorage(SettingsKey.appearance) private var appearance: AppearanceSetting = .system

    func body(content: Content) -> some View {
        content
            .onAppear { apply(appearance) }
            .onChange(of: appearance) { _, new in apply(new) }
    }

    private func apply(_ setting: AppearanceSetting) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = setting.interfaceStyle
            }
        }
    }
}
