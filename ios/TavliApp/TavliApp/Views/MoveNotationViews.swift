import SwiftUI
import TavliEngine

/// Rendering of the engine's `MoveNotation` (#178), shared by the move history, the
/// post-game review and the drill: the notation tokens (`13/7^`, `bar/22`, `6/off`)
/// stay English; only the phrases "No move" / "Mother pinned" are localized.

/// A move's notation as one `Text`: `^` (a pin) slightly bold in the accent colour,
/// `*` (a hit) in the text colour; "No move" in secondary ink.
struct MoveNotationText: View {
    let notation: MoveNotation
    var font: Font = ChromeType.callout
    var color: SwiftUI.Color = ChromeTheme.ink
    var accent: SwiftUI.Color = ChromeTheme.undoTint

    var body: some View {
        if notation.noMove {
            Text("No move")
                .font(font.italic())
                .foregroundStyle(ChromeKit.inkSecondary)
        } else {
            styled
                .font(font.monospaced())
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var styled: Text {
        var out = Text(verbatim: "")
        for (i, seg) in notation.segments.enumerated() {
            if i > 0 { out = out + Text(verbatim: " ") }
            out = out + Text(verbatim: seg.from.text)
            for stop in seg.stops {
                out = out + Text(verbatim: "/" + stop.place.text)
                switch stop.mark {
                case .pin?: out = out + Text(verbatim: "^").fontWeight(.heavy).foregroundColor(accent)
                case .hit?: out = out + Text(verbatim: "*").fontWeight(.bold)
                case nil: break
                }
            }
            if seg.count > 1 { out = out + Text(verbatim: "(\(seg.count))") }
        }
        return out
    }
}

/// The roll as two small die faces, high die first.
struct NotationDice: View {
    let notation: MoveNotation
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: size * 0.25) {
            DieFace(value: notation.highDie, size: size)
            DieFace(value: notation.lowDie, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(notation.highDie) \(notation.lowDie)"))
    }
}

/// The small "Mother pinned" tag (standard Plakoto: the move that decides the game).
struct MotherPinnedLabel: View {
    var body: some View {
        Text("Mother pinned")
            .font(ChromeType.caption2.bold())
            .foregroundStyle(ChromeTheme.undoTint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(ChromeTheme.undoTint.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(ChromeTheme.undoTint.opacity(0.45), lineWidth: 1))
            .fixedSize()
    }
}

/// Notation + (when it applies) the mother label: inline when the row has room, else
/// stacked under the move.
struct MoveNotationLine: View {
    let notation: MoveNotation
    var font: Font = ChromeType.callout
    var color: SwiftUI.Color = ChromeTheme.ink

    var body: some View {
        if notation.motherPinned {
            // Inline at the end of the row when it fits, else under the move.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    MoveNotationText(notation: notation, font: font, color: color).fixedSize()
                    MotherPinnedLabel()
                }
                VStack(alignment: .leading, spacing: 3) {
                    MoveNotationText(notation: notation, font: font, color: color)
                    MotherPinnedLabel()
                }
            }
        } else {
            MoveNotationText(notation: notation, font: font, color: color)
        }
    }
}

#Preview("Notation") {
    let b = GameBoard(config: GameConfig(variant: GameVariants.plakotoStandard))
    b.clear()
    b.setPoint(1, pieces: Array(repeating: .white, count: 13))
    b.setPoint(18, pieces: [.white])
    b.setPoint(12, pieces: [.white])
    b.setPoint(24, pieces: [.black])
    b.setPoint(13, pieces: Array(repeating: .black, count: 14))
    let n = MoveNotation.describe([[18, 24], [12, 15]], die1: 6, die2: 3, mover: .white, before: b)
    let pass = MoveNotation(highDie: 6, lowDie: 6, segments: [])
    return VStack(alignment: .leading, spacing: 12) {
        HStack { NotationDice(notation: n); MoveNotationLine(notation: n) }
        HStack { NotationDice(notation: pass); MoveNotationLine(notation: pass) }
    }
    .padding()
}
