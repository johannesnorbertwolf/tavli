import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// "Spiele" tab — the list of all round-robin pairings, split into open and
/// played. Tapping a pairing opens a sheet to enter / change / clear the result;
/// for a pairing that involves the AI (TavTav) the sheet also offers
/// "Gegen die AI spielen", which plays the game in-app and records the result
/// automatically. Every result is overwritable.
struct MatchesView: View {
    @ObservedObject var model: TournamentModel
    let onPlay: (GameContext) -> Void

    @State private var selected: TournamentMatch?

    private var openMatches: [TournamentMatch] { model.matches.filter { !$0.isPlayed } }
    private var playedMatches: [TournamentMatch] { model.matches.filter { $0.isPlayed } }

    var body: some View {
        ZStack {
            Weltsensation.page.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    title
                    if model.matches.isEmpty {
                        emptyState
                    } else {
                        if !openMatches.isEmpty { group("Offen", openMatches) }
                        if !playedMatches.isEmpty { group("Gespielt", playedMatches) }
                    }
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(item: $selected) { match in
            MatchResultSheet(model: model,
                             match: match,
                             onPlay: { selected = nil; onPlay(.match(match)) })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var title: some View {
        VStack(spacing: 2) {
            Text("Spiele")
                .font(ChromeType.statsTitle)
                .foregroundStyle(ChromeTheme.ink)
            Text("Ergebnisse eintragen oder gegen \(model.aiPlayer?.name ?? "TavTav") spielen")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 40))
                .foregroundStyle(ChromeKit.inkSecondary)
            Text("Noch keine Paarungen")
                .font(ChromeType.headline)
                .foregroundStyle(ChromeTheme.ink)
            Text("Füge im Tab „Setup“ mindestens zwei Spieler hinzu.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .chromeCard()
    }

    private func group(_ heading: String, _ matches: [TournamentMatch]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(heading) (\(matches.count))")
                .font(ChromeType.headline)
                .foregroundStyle(ChromeKit.inkSecondary)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element.id) { idx, match in
                    Button { selected = match } label: {
                        MatchRow(model: model, match: match)
                    }
                    .buttonStyle(.plain)
                    if idx < matches.count - 1 {
                        Divider().background(ChromeTheme.ink.opacity(0.08))
                    }
                }
            }
            .chromeCard(padding: 10)
        }
    }
}

/// One pairing row: the two players (winner bolded + checked, loser dimmed) and a
/// trailing affordance — a play glyph for an unplayed AI pairing, otherwise a
/// chevron.
private struct MatchRow: View {
    @ObservedObject var model: TournamentModel
    let match: TournamentMatch

    private var isAIMatch: Bool { model.humanAndAI(in: match) != nil }

    var body: some View {
        HStack(spacing: 10) {
            side(match.a)
            Text("vs.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
            side(match.b)
            Spacer(minLength: 8)
            if !match.isPlayed && isAIMatch {
                Image(systemName: "play.circle.fill")
                    .font(ChromeType.title3)
                    .foregroundStyle(ChromeTheme.undoTint)
            } else {
                Image(systemName: "chevron.right")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func side(_ id: UUID) -> some View {
        let isWinner = match.winner == id
        let dimmed = match.isPlayed && !isWinner
        return HStack(spacing: 4) {
            if isWinner {
                Image(systemName: "checkmark.circle.fill")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeTheme.doneTint)
            }
            PlayerNameLabel(player: model.player(id),
                            font: isWinner ? ChromeType.body.weight(.semibold) : ChromeType.body)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(dimmed ? 0.5 : 1)
        }
    }
}

/// Result sheet for one pairing: optional "play vs AI", a winner picker (live
/// highlight), and a clear action. Reads the match live from the model so the
/// highlight reflects edits immediately.
private struct MatchResultSheet: View {
    @ObservedObject var model: TournamentModel
    let match: TournamentMatch
    let onPlay: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var live: TournamentMatch {
        model.matches.first { $0.id == match.id } ?? match
    }

    var body: some View {
        ZStack {
            Weltsensation.page.ignoresSafeArea()
            VStack(spacing: 20) {
                header

                if let ai = model.humanAndAI(in: match)?.ai {
                    Button(action: onPlay) {
                        Label("Gegen \(ai.name) spielen", systemImage: "play.fill")
                    }
                    .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Wer hat gewonnen?")
                        .font(ChromeType.body.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    winnerButton(match.a)
                    winnerButton(match.b)
                    if live.winner != nil {
                        Button { model.clearResult(matchID: match.id) } label: {
                            Label("Kein Ergebnis", systemImage: "xmark.circle")
                        }
                        .buttonStyle(ChromeButton(role: .quiet))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack {
            Text("Ergebnis")
                .font(ChromeType.title3.bold())
                .foregroundStyle(ChromeTheme.ink)
            Spacer()
            Button("Fertig") { dismiss() }
                .buttonStyle(ChromeButton(role: .secondary))
        }
    }

    private func winnerButton(_ id: UUID) -> some View {
        let isWinner = live.winner == id
        return Button { model.setResult(matchID: match.id, winner: id) } label: {
            HStack(spacing: 10) {
                Image(systemName: isWinner ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isWinner ? ChromeTheme.doneTint : ChromeKit.inkSecondary)
                PlayerNameLabel(player: model.player(id))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isWinner ? ChromeTheme.doneTint.opacity(0.14) : ChromeTheme.ink.opacity(0.05))
            .cornerRadius(ChromeKit.buttonRadius)
        }
        .buttonStyle(.plain)
    }
}
