import SwiftUI

/// TavTav — the branded face of the on-device AI opponent (#126). Two personas:
/// `.smirk` (the confident opponent) and `.friendly` (good-natured: a loss, or
/// the coaching screens). Art + rollout plan: `ios/TavliApp/MASCOT.md`.
enum TavTavPersona {
    case smirk, friendly

    /// Square face crop, for the circular avatar badge.
    var faceAsset: String { self == .smirk ? "TavTavSmirkFace" : "TavTavFriendlyFace" }
    /// Full locomotive (transparent), for larger / celebratory contexts.
    var locoAsset: String { self == .smirk ? "TavTavSmirk" : "TavTavFriendly" }
}

/// Circular face badge — the workhorse: player rows, the opening-roll verdict,
/// and (large) the win/loss overlay. A cream fill sits behind the transparent
/// corners of the crop so the circle never shows the page background through the
/// head.
struct TavTavAvatar: View {
    var persona: TavTavPersona = .smirk
    var size: CGFloat = 32
    var ringed: Bool = true

    var body: some View {
        Image(persona.faceAsset)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .background(CaramelPalette.triangleFill)
            .clipShape(Circle())
            .overlay {
                if ringed {
                    Circle().strokeBorder(ChromeTheme.ink.opacity(0.30),
                                          lineWidth: max(1, size * 0.03))
                }
            }
            .accessibilityHidden(true)
    }
}

/// Full-locomotive mascot, scaled to fit a height. For the opening-roll ceremony
/// and other large, decorative spots.
struct TavTavLoco: View {
    var persona: TavTavPersona = .smirk
    var height: CGFloat = 96

    var body: some View {
        Image(persona.locoAsset)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// The full TavTav logo — loco + wordmark + dice (the brand mark). Transparent
/// background; size it via a `.frame`. Used as the in-game chrome header tile and
/// the tournament corner mark.
struct TavTavLogo: View {
    var body: some View {
        Image("TavTavLogo")
            .resizable()
            .scaledToFit()
            .accessibilityLabel("TavTav")
    }
}

/// The chrome header tile: the full logo as its own element on top of the chrome.
/// Spans the chrome column's width in landscape (the panel is 280pt wide); in
/// portrait it keeps the same max width, centred, and `scaledToFit` lets it
/// shrink to whatever vertical space is left above the board rather than push the
/// board off-screen.
struct TavTavLogoTile: View {
    var maxWidth: CGFloat = 280

    var body: some View {
        TavTavLogo()
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)   // centre in portrait; a no-op in the 280pt panel
    }
}

#Preview {
    VStack(spacing: 24) {
        HStack(spacing: 16) {
            TavTavAvatar(persona: .smirk, size: 64)
            TavTavAvatar(persona: .friendly, size: 64)
            TavTavAvatar(persona: .smirk, size: 28, ringed: false)
        }
        TavTavLogoTile(maxWidth: 220)
        HStack(spacing: 16) {
            TavTavLoco(persona: .smirk, height: 80)
            TavTavLoco(persona: .friendly, height: 80)
        }
    }
    .padding(40)
    .background(Color(hex: 0xece6dc))
}
