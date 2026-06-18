import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// "Setup" tab — manage players and app settings. Players (including the AI,
/// TavTav) can be added, renamed and removed at any time; removing TavTav reveals
/// a "TavTav hinzufügen" action to bring the AI back. Settings hold the re-lock,
/// a results reset, and an optional unscored practice game vs the AI.
struct SetupView: View {
    @ObservedObject var model: TournamentModel
    let onPlay: (GameContext) -> Void

    @AppStorage(WeltsensationKey.unlocked) private var unlocked = false

    @State private var newName = ""
    @State private var renaming: TournamentPlayer?
    @State private var renameText = ""
    @State private var pendingDelete: TournamentPlayer?
    @State private var confirmReset = false

    var body: some View {
        ZStack {
            Weltsensation.page.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    title
                    playersSection
                    gamesSection
                    devicesSection
                    settingsSection
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            // The list is kept fresh from disk while a game is running; refresh it
            // whenever this tab reappears so a just-finished game shows up.
            .onAppear { model.reloadSavedGames() }
        }
        .alert("Spieler umbenennen", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Speichern") {
                if let p = renaming { model.renamePlayer(p.id, to: renameText) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .confirmationDialog("Spieler entfernen?",
                            isPresented: deleteBinding,
                            titleVisibility: .visible) {
            if let p = pendingDelete {
                Button("„\(p.name)“ entfernen", role: .destructive) { model.removePlayer(p.id) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Ergebnisse dieses Spielers gehen verloren.")
        }
        .confirmationDialog("Alle Ergebnisse zurücksetzen?",
                            isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) { model.resetResults() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Tabelle und Finale werden geleert. Spieler bleiben erhalten.")
        }
    }

    private var title: some View {
        Text("Setup")
            .font(ChromeType.statsTitle)
            .foregroundStyle(ChromeTheme.ink)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Players

    private var playersSection: some View {
        section("Spieler") {
            VStack(spacing: 10) {
                ForEach(model.players) { player in
                    playerRow(player)
                }
            }

            HStack(spacing: 10) {
                TextField("Neuer Spieler", text: $newName)
                    .font(ChromeType.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(SColor.white.opacity(0.6))
                    .cornerRadius(ChromeKit.buttonRadius)
                    .onSubmit(addPlayer)
                Button(action: addPlayer) {
                    Label("Hinzufügen", systemImage: "plus")
                }
                .buttonStyle(ChromeButton(role: .secondary))
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !model.hasAI {
                Button { model.addAIPlayer() } label: {
                    Label("TavTav hinzufügen", systemImage: "cpu")
                }
                .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            }
        }
    }

    private func playerRow(_ player: TournamentPlayer) -> some View {
        HStack(spacing: 10) {
            PlayerNameLabel(player: player)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                renaming = player
                renameText = player.name
            } label: {
                Image(systemName: "pencil")
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            Button { pendingDelete = player } label: {
                Image(systemName: "trash")
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ChromeTheme.ink.opacity(0.04))
        .cornerRadius(ChromeKit.buttonRadius)
    }

    // MARK: - Saved games

    /// Every in-app game played or started on this device (newest first), each
    /// resumable. In-progress games can be finished where they left off; finished
    /// games re-open at their final board for review. Local-only (never synced).
    private var gamesSection: some View {
        section("Gespeicherte Spiele") {
            if model.savedGames.isEmpty {
                Text("Noch keine Partien. Spiele gegen \(model.aiPlayer?.name ?? "TavTav") werden hier nach jedem Zug gespeichert — auch wenn die App zwischendurch schließt.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.savedGames) { game in
                        TournamentGameRow(
                            game: game,
                            onResume: { onPlay(.resume(game)) },
                            onDelete: { model.deleteSavedGame(id: game.id) })
                    }
                }
            }
        }
    }

    // MARK: - Devices (sync)

    /// Live indicator for the multi-iPad sync mesh. Sync is automatic on the same
    /// WiFi — this just shows who's currently connected (the count, then names).
    private var devicesSection: some View {
        section("Geräte") {
            let peers = model.peerNames
            HStack(spacing: 10) {
                Image(systemName: peers.isEmpty ? "wifi" : "checkmark.circle.fill")
                    .font(ChromeType.title3)
                    .foregroundStyle(peers.isEmpty ? ChromeKit.inkSecondary : ChromeTheme.doneTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(peers.isEmpty
                         ? "Keine weiteren iPads verbunden"
                         : (peers.count == 1 ? "1 iPad verbunden" : "\(peers.count) iPads verbunden"))
                        .font(ChromeType.body.weight(.semibold))
                        .foregroundStyle(ChromeTheme.ink)
                    Text(peers.isEmpty
                         ? "Im selben WLAN finden sich die Geräte automatisch."
                         : peers.joined(separator: ", "))
                        .font(ChromeType.caption)
                        .foregroundStyle(ChromeKit.inkSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        section("Einstellungen") {
            if model.hasAI {
                Button { onPlay(.practice) } label: {
                    Label("Übungsspiel gegen \(model.aiPlayer?.name ?? "TavTav")", systemImage: "gamecontroller")
                }
                .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            }
            Button { confirmReset = true } label: {
                Label("Ergebnisse zurücksetzen", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
            Button { unlocked = false } label: {
                Label("App sperren", systemImage: "lock.fill")
            }
            .buttonStyle(ChromeButton(role: .destructive, fullWidth: true))
            Text("Beim Sperren wird wieder das Passwort verlangt.")
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
        }
    }

    // MARK: - Helpers

    private func addPlayer() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addPlayer(name: trimmed)
        newName = ""
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func section<Content: View>(_ heading: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading)
                .font(ChromeType.headline)
                .foregroundStyle(ChromeKit.inkSecondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chromeCard(padding: 20)
    }
}

/// One saved-game row: who played + which colour + status (running with its move
/// count, or finished with the winner). Tapping the body resumes/re-opens the game;
/// the trailing trash button deletes it.
private struct TournamentGameRow: View {
    let game: SavedTournamentGame
    let onResume: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onResume) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(ChromeType.title3)
                        .foregroundStyle(iconColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(ChromeType.body.weight(.semibold))
                            .foregroundStyle(ChromeTheme.ink)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(ChromeType.caption)
                            .foregroundStyle(ChromeKit.inkSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ChromeTheme.ink.opacity(0.04))
        .cornerRadius(ChromeKit.buttonRadius)
    }

    private var title: String {
        if let human = game.humanName { return "\(human) gegen \(game.aiName)" }
        return "Übungsspiel gegen \(game.aiName)"
    }

    private var subtitle: String {
        let color = Weltsensation.colorName(game.humanColor)
        if let won = game.humanWon {
            let winner = won ? (game.humanName ?? "Du") : game.aiName
            return "\(color) · Beendet · Sieg: \(winner)"
        }
        let plies = game.plyCount == 1 ? "1 Zug" : "\(game.plyCount) Züge"
        let status = game.isConceded ? "Aufgegeben" : "Läuft"
        return "\(color) · \(status) · \(plies)"
    }

    private var icon: String {
        if game.isFinished { return "checkmark.seal.fill" }
        return game.isConceded ? "flag.fill" : "play.circle.fill"
    }

    private var iconColor: SColor {
        if game.isFinished { return ChromeTheme.doneTint }
        return game.isConceded ? ChromeTheme.surrenderTint : Weltsensation.gold
    }
}
