import SwiftUI
import TavliEngine

/// Shared constants + tiny shared views for the **Weltsensation** tournament
/// shell. Everything else reuses the existing Caramel chrome (`ChromeKit`,
/// `ChromeTheme`, `ChromeType`, `CaramelPalette`); this just adds the few
/// tournament-specific tokens and German helpers. The whole shell is German.
enum Weltsensation {
    /// Hardcoded gate — a deliberate, insecure deterrent (keeps the family out
    /// of the app until the tournament starts), entered once then remembered.
    static let password = "Tavli"
    static let appTitle = "Weltsensation"

    /// Shared caramel page background (matches the rest of the app).
    static let page = SwiftUI.Color(hex: 0xece6dc)

    /// Podium / finalist gold accent (the board's highlight amber).
    static let gold = CaramelPalette.hl
    static let goldEdge = CaramelPalette.hlEdge

    /// German display name for a checker color (engine `.black` renders as "Rot").
    static func colorName(_ c: TavliEngine.Color) -> String { c == .white ? "Weiß" : "Rot" }
}

/// UserDefaults keys owned by the tournament shell.
enum WeltsensationKey {
    /// Whether the password gate has been passed (sticky; cleared by "App sperren").
    static let unlocked = "weltsensation.unlocked"
}

/// Small "AI" pill marking the AI player (TavTav) wherever a player is shown.
struct AIBadge: View {
    var body: some View {
        Text("AI")
            .font(ChromeType.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(ChromeTheme.undoTint)
            .clipShape(Capsule())
            .accessibilityLabel("Künstliche Intelligenz")
    }
}

/// A player's name with the AI badge appended when it's TavTav. `fallback` covers
/// a missing player (e.g. a stale id).
struct PlayerNameLabel: View {
    let player: TournamentPlayer?
    var font: Font = ChromeType.body
    var fallback = "—"

    var body: some View {
        HStack(spacing: 6) {
            if player?.isAI == true {
                TavTavAvatar(persona: .smirk, size: 22, ringed: false)
            }
            Text(player?.name ?? fallback)
                .font(font)
                .foregroundStyle(ChromeTheme.ink)
            if player?.isAI == true { AIBadge() }
        }
    }
}
