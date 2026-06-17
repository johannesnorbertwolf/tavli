import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// "Tabelle" tab — the app's main view. The top two ranks get an elevated gold
/// **podium** (they play the finale); the rest follow in a compact ranked table.
/// Below sits the finale flow: once every round-robin game has a result, the
/// "Finale starten" button appears; if the AI is a finalist, starting it launches
/// the in-app game directly. A champion banner crowns the winner afterwards.
struct StandingsView: View {
    @ObservedObject var model: TournamentModel
    let onPlay: (GameContext) -> Void

    @State private var showFinaleResult = false

    var body: some View {
        ZStack {
            Weltsensation.page.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 22) {
                    title
                    if let champ = model.champion { ChampionBanner(name: champ.name) }
                    content
                    finaleSection
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Finale-Ergebnis", isPresented: $showFinaleResult, titleVisibility: .visible) {
            if let f = model.finale {
                Button(model.name(f.a)) { model.setFinaleWinner(f.a) }
                Button(model.name(f.b)) { model.setFinaleWinner(f.b) }
                if f.winner != nil {
                    Button("Kein Ergebnis", role: .destructive) { model.setFinaleWinner(nil) }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Wer hat das Finale gewonnen?")
        }
    }

    // MARK: - Header

    private var title: some View {
        VStack(spacing: 2) {
            Text("Tabelle")
                .font(ChromeType.statsTitle)
                .foregroundStyle(ChromeTheme.ink)
            Text("Jeder gegen jeden")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
    }

    // MARK: - Standings

    @ViewBuilder
    private var content: some View {
        let table = model.standings
        if table.count < 2 {
            emptyState
        } else {
            podium(table)
            if table.count > 2 {
                restTable(Array(table[2...]))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 40))
                .foregroundStyle(ChromeKit.inkSecondary)
            Text("Noch zu wenige Spieler")
                .font(ChromeType.headline)
                .foregroundStyle(ChromeTheme.ink)
            Text("Füge im Tab „Setup“ Spieler hinzu, um die Tabelle zu starten.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .chromeCard()
    }

    private func podium(_ table: [TournamentStanding]) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            PodiumCard(standing: table[1], place: 2)
            PodiumCard(standing: table[0], place: 1)
        }
    }

    private func restTable(_ rows: [TournamentStanding]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, s in
                StandingRow(standing: s)
                if idx < rows.count - 1 {
                    Divider().background(ChromeTheme.ink.opacity(0.08))
                }
            }
        }
        .chromeCard(padding: 10)
    }

    // MARK: - Finale

    @ViewBuilder
    private var finaleSection: some View {
        if let f = model.finale {
            FinaleCard(model: model,
                       finale: f,
                       onPlay: { onPlay(.finale(f)) },
                       onEnter: { showFinaleResult = true },
                       onReset: { model.clearFinale() })
        } else if model.isRoundRobinComplete {
            Button(action: startFinale) {
                Label("Finale starten", systemImage: "flag.checkered")
            }
            .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
        } else if model.standings.count >= 2 {
            VStack(spacing: 6) {
                Label("Finale", systemImage: "flag.checkered")
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeTheme.ink)
                Text(openHint)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .chromeCard()
        }
    }

    private var openHint: String {
        let n = model.openMatchCount
        return n == 1 ? "Noch 1 Spiel offen bis zum Finale" : "Noch \(n) Spiele offen bis zum Finale"
    }

    /// Snapshot the top two into the finale and — if the AI is a finalist — launch
    /// the game immediately (the user's "if the AI is part of the finale, start it").
    private func startFinale() {
        model.startFinale()
        if let f = model.finale, model.humanAndAI(in: f) != nil {
            onPlay(.finale(f))
        }
    }
}

// MARK: - Podium

/// One elevated podium card for rank 1 or 2. Rank 1 carries the strongest gold
/// and a crown; rank 2 a lighter gold and a "2." medal.
private struct PodiumCard: View {
    let standing: TournamentStanding
    let place: Int

    private var isFirst: Bool { place == 1 }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isFirst ? "crown.fill" : "2.circle.fill")
                .font(.system(size: isFirst ? 34 : 26))
                .foregroundStyle(isFirst ? Weltsensation.gold : Weltsensation.gold.opacity(0.7))

            PlayerNameLabel(player: standing.player,
                            font: isFirst ? ChromeType.title3.bold() : ChromeType.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(winsText)
                .font(ChromeType.callout.bold())
                .foregroundStyle(ChromeTheme.ink)
            Text("\(standing.played) Spiele")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isFirst ? 26 : 18)
        .padding(.horizontal, 12)
        .background(Weltsensation.gold.opacity(isFirst ? 0.16 : 0.08))
        .cornerRadius(ChromeKit.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: ChromeKit.cardRadius)
                .stroke(Weltsensation.gold.opacity(isFirst ? 0.9 : 0.5), lineWidth: isFirst ? 2.5 : 1.5)
        )
        .shadow(color: Weltsensation.gold.opacity(isFirst ? 0.28 : 0.14),
                radius: isFirst ? 12 : 7, x: 0, y: 4)
    }

    private var winsText: String {
        standing.wins == 1 ? "1 Sieg" : "\(standing.wins) Siege"
    }
}

/// A compact ranked row for places 3+.
private struct StandingRow: View {
    let standing: TournamentStanding

    var body: some View {
        HStack(spacing: 12) {
            Text("\(standing.rank).")
                .font(ChromeType.callout.monospacedDigit())
                .foregroundStyle(ChromeKit.inkSecondary)
                .frame(width: 36, alignment: .trailing)
            PlayerNameLabel(player: standing.player)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(standing.wins == 1 ? "1 Sieg" : "\(standing.wins) Siege")
                .font(ChromeType.callout.bold())
                .monospacedDigit()
                .foregroundStyle(ChromeTheme.ink)
            Text("\(standing.played) Sp.")
                .font(ChromeType.caption.monospacedDigit())
                .foregroundStyle(ChromeKit.inkSecondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}

// MARK: - Champion + finale card

private struct ChampionBanner: View {
    let name: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .font(.system(size: 32))
                .foregroundStyle(Weltsensation.gold)
            Text("Weltmeister")
                .font(ChromeType.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(ChromeKit.inkSecondary)
            Text(name)
                .font(ChromeType.winTitle)
                .foregroundStyle(ChromeTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(Weltsensation.gold.opacity(0.18))
        .cornerRadius(ChromeKit.cardRadius)
        .overlay(
            RoundedRectangle(cornerRadius: ChromeKit.cardRadius)
                .stroke(Weltsensation.gold, lineWidth: 2)
        )
    }
}

/// The finale card: the two finalists, the in-app play / manual-entry actions,
/// and a reset. The winner (once decided) is crowned here; the standings tab also
/// shows the big champion banner.
private struct FinaleCard: View {
    @ObservedObject var model: TournamentModel
    let finale: Finale
    let onPlay: () -> Void
    let onEnter: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Label("Finale", systemImage: "flag.checkered")
                .font(ChromeType.title3.bold())
                .foregroundStyle(ChromeTheme.ink)

            HStack(alignment: .top, spacing: 12) {
                finalist(finale.a)
                Text("vs.")
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .padding(.top, 6)
                finalist(finale.b)
            }

            if finale.winner == nil {
                if let ai = model.humanAndAI(in: finale)?.ai {
                    Button(action: onPlay) {
                        Label("Finale gegen \(ai.name) spielen", systemImage: "play.fill")
                    }
                    .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
                }
                Button(action: onEnter) {
                    Label("Ergebnis eintragen", systemImage: "square.and.pencil")
                }
                .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            } else {
                Button(action: onEnter) { Text("Ergebnis ändern") }
                    .buttonStyle(ChromeButton(role: .quiet))
            }

            Button(action: onReset) { Text("Finale zurücksetzen") }
                .buttonStyle(ChromeButton(role: .quiet))
        }
        .frame(maxWidth: .infinity)
        .chromeCard()
        .overlay(
            RoundedRectangle(cornerRadius: ChromeKit.cardRadius)
                .stroke(Weltsensation.gold.opacity(0.8), lineWidth: 2)
        )
    }

    private func finalist(_ id: UUID) -> some View {
        let isWinner = finale.winner == id
        return VStack(spacing: 8) {
            if isWinner {
                Image(systemName: "crown.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Weltsensation.gold)
            }
            PlayerNameLabel(player: model.player(id), font: ChromeType.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(isWinner ? Weltsensation.gold.opacity(0.16) : ChromeTheme.ink.opacity(0.05))
        .cornerRadius(ChromeKit.buttonRadius)
    }
}
