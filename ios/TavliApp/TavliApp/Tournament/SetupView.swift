import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color

/// "Setup" tab — manage players and app settings. Players (including the AI,
/// Tavtav) can be added, renamed and removed at any time; removing Tavtav reveals
/// a "Tavtav hinzufügen" action to bring the AI back. Settings hold the re-lock,
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
                    devicesSection
                    settingsSection
                }
                .padding(24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
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
                    Label("Tavtav hinzufügen", systemImage: "cpu")
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
                    Label("Übungsspiel gegen \(model.aiPlayer?.name ?? "Tavtav")", systemImage: "gamecontroller")
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
