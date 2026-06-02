import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// #64 — the human's win/loss record against the AI, the iPad analogue of the
/// CLI's post-game summary box. A **pure** view of a `HumanGameStats`: overall
/// W/L + win rate, a last-20 sparkline (oldest→newest), and the current streak.
/// Hosted both inside the win overlay (auto-shown after each game) and from the
/// mode picker (`RootView`). No persistence or game logic lives here.
struct StatsPanelView: View {
    let stats: HumanGameStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Human vs AI")
                .font(.custom("Cormorant Garamond", size: 32))
                .foregroundStyle(Palette.ink)

            if stats.total == 0 {
                emptyState
            } else {
                overall
                sparkline
                streak
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(Palette.card)
        .cornerRadius(18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.border, lineWidth: 1.5))
        .accessibilityIdentifier("statsPanel")
    }

    // ── Sections ──────────────────────────────────────────────────────────────

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No games yet")
                .font(.headline)
                .foregroundStyle(Palette.ink)
            Text("Play a game to start your record.")
                .font(.subheadline)
                .foregroundStyle(Palette.ink.opacity(0.65))
        }
    }

    private var overall: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(stats.wins)W – \(stats.losses)L")
                    .font(.title2.bold())
                    .foregroundStyle(Palette.ink)
                Text("(\(percentString))")
                    .font(.title3)
                    .foregroundStyle(Palette.ink.opacity(0.65))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.ink.opacity(0.12))
                    Capsule()
                        .fill(Palette.win)
                        .frame(width: proxy.size.width * stats.winRate)
                }
            }
            .frame(height: 8)
        }
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stats.total <= 20 ? "All \(stats.total)" : "Last 20")
                .font(.caption.bold())
                .foregroundStyle(Palette.ink.opacity(0.65))
            HStack(spacing: 4) {
                ForEach(Array(stats.recent.enumerated()), id: \.offset) { _, won in
                    Circle()
                        .fill(won ? Palette.win : Palette.loss)
                        .frame(width: 11, height: 11)
                }
            }
        }
    }

    private var streak: some View {
        HStack(spacing: 6) {
            Text("Streak")
                .font(.caption.bold())
                .foregroundStyle(Palette.ink.opacity(0.65))
            Text(streakString)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(stats.streakIsWin ? Palette.win : Palette.loss)
        }
    }

    // ── Formatting ────────────────────────────────────────────────────────────

    private var percentString: String {
        String(format: "%.0f%%", stats.winRate * 100)
    }

    private var streakString: String {
        let word = stats.streakIsWin ? "win" : "loss"
        let plural = stats.streakCount == 1 ? word : (stats.streakIsWin ? "wins" : "losses")
        let arrow = stats.streakIsWin ? "↑" : "↓"
        return "\(stats.streakCount) \(plural) in a row \(arrow)"
    }

    private enum Palette {
        static let card = SColor(hex: 0xf3ecdf)
        static let ink = CaramelPalette.frameText
        static let border = CaramelPalette.frameBot
        static let win = SColor(hex: 0x6a8a4a)   // muted olive-green
        static let loss = SColor(hex: 0xb0563f)  // muted brick-red
    }
}

// MARK: - Previews

#Preview("Mixed record") {
    let recs = [true, false, true, true, false, true, true, true]
        .map { HumanGameRecord(date: Date(), humanWon: $0) }
    return StatsPanelView(stats: HumanGameStats(records: recs))
        .padding()
        .background(SColor(hex: 0xece6dc))
}

#Preview("Empty") {
    StatsPanelView(stats: .empty)
        .padding()
        .background(SColor.black.opacity(0.55))
}
