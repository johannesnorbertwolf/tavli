import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// What an in-app game is being played for. A `match`/`finale` records its
/// outcome onto the tournament; `practice` is an unscored game vs the AI;
/// `resume` re-opens a previously-saved game (from the Setup list) at its last
/// position, carrying its own identity so a resumed match still records its result.
enum GameContext: Identifiable {
    case match(TournamentMatch)
    case finale(Finale)
    case practice
    case resume(SavedTournamentGame)

    var id: String {
        switch self {
        case .match(let m):   return "match-\(m.id.uuidString)"
        case .finale:         return "finale"
        case .practice:       return "practice"
        case .resume(let g):  return "resume-\(g.id.uuidString)"
        }
    }
}

/// The tournament shell: a three-tab Caramel `TabView` (Tabelle / Spiele / Setup)
/// over one shared `TournamentModel`, plus the full-screen game coordinator. Any
/// tab can launch an AI game via `onPlay`; the result is written back to the model
/// automatically when the game ends.
struct TournamentRootView: View {
    @StateObject private var model = TournamentModel()
    @State private var game: GameContext?

    var body: some View {
        TabView {
            StandingsView(model: model, onPlay: launch)
                .tabItem { Label("Tabelle", systemImage: "trophy.fill") }
            MatchesView(model: model, onPlay: launch)
                .tabItem { Label("Spiele", systemImage: "square.grid.2x2.fill") }
            SetupView(model: model, onPlay: launch)
                .tabItem { Label("Setup", systemImage: "person.2.fill") }
        }
        .tint(ChromeTheme.undoTint)
        // Persistent brand mark across all three tabs. Top-trailing is the only
        // corner free on every tab (titles sit centred/leading; the tab bar owns
        // the bottom). Non-interactive so it never eats a tap; hidden during a
        // game (the full-screen cover sits on top, and the game has its own
        // in-chrome mascot).
        .overlay(alignment: .topTrailing) {
            TavTavLogo()
                .frame(width: 96)
                .padding(.top, 14)
                .padding(.trailing, 16)
                .allowsHitTesting(false)
        }
        .fullScreenCover(item: $game) { ctx in
            TournamentGameFlow(model: model, context: ctx, onClose: {
                game = nil
                model.reloadSavedGames()   // surface the just-played/-saved game in Setup
            })
        }
    }

    private func launch(_ ctx: GameContext) { game = ctx }
}

/// Drives one in-app AI game: pick the human's colour → opening roll → the full
/// `GameView` (a `.resume` context skips straight to the board). The game is
/// **auto-saved after every move** under a stable per-game record, so an interrupted
/// game is never lost and can be re-opened from the Setup list. On game over the
/// result is recorded onto the originating match or finale (practice records
/// nothing). The win overlay / back both route to `onClose`.
private struct TournamentGameFlow: View {
    @ObservedObject var model: TournamentModel
    let context: GameContext
    let onClose: () -> Void

    @State private var humanColor: EngineColor?
    @State private var session: GameSession?

    /// The persistent record for the live game (its stable identity + metadata).
    /// Set once the session is built; `persist()` rewrites it after every move.
    @State private var saved: SavedTournamentGame?

    /// Whether this game is played on the real board with the dice keyed in by hand
    /// (the quiet "Am echten Brett" opt-in on the colour screen). Off = the obvious
    /// path: auto-roll on the iPad. Reset per game (a fresh flow each launch).
    @State private var manualDice = false

    // Resolve the human / AI sides up front (captured into the saved record). A
    // `resume` game carries its own identity, so these are unused there.
    private var ai: TournamentPlayer? {
        switch context {
        case .match(let m):  return model.humanAndAI(in: m)?.ai
        case .finale(let f): return model.humanAndAI(in: f)?.ai
        case .practice:      return model.aiPlayer
        case .resume:        return nil
        }
    }

    private var human: TournamentPlayer? {
        switch context {
        case .match(let m):  return model.humanAndAI(in: m)?.human
        case .finale(let f): return model.humanAndAI(in: f)?.human
        case .practice:      return nil
        case .resume:        return nil
        }
    }

    private var isResume: Bool {
        if case .resume = context { return true }
        return false
    }

    var body: some View {
        Group {
            if let session {
                GameView(session: session,
                         humanColor: humanColor ?? .white,
                         onAutosave: persist,
                         tournamentExit: onClose,
                         tournamentOpponentName: saved?.aiName,
                         showsBackButton: false,
                         onGiveUp: giveUp)
            } else if isResume {
                // Build the resumed session once, then fall into the GameView branch.
                Weltsensation.page.ignoresSafeArea()
                    .onAppear(perform: startResume)
            } else if ai == nil {
                invalidView
            } else if let hc = humanColor {
                OpeningRollView(humanColor: hc,
                                onStart: { starter in start(humanColor: hc, starter: starter) },
                                onBack: onClose)
            } else {
                colorChoice
            }
        }
    }

    // MARK: - Colour choice

    private var colorChoice: some View {
        ZStack {
            Weltsensation.page.ignoresSafeArea()
            VStack(spacing: 24) {
                HStack {
                    Button("Abbrechen", action: onClose)
                        .buttonStyle(ChromeButton(role: .secondary))
                    Spacer()
                }

                Spacer(minLength: 0)

                VStack(spacing: 8) {
                    Text(titleText)
                        .font(ChromeType.title3.bold())
                        .foregroundStyle(ChromeTheme.ink)
                        .multilineTextAlignment(.center)
                    Text("Welche Farbe möchtest du spielen?")
                        .font(ChromeType.body)
                        .foregroundStyle(ChromeKit.inkSecondary)
                }

                HStack(spacing: 16) {
                    colorButton(.white)
                    colorButton(.black)
                }
                .frame(maxWidth: 420)

                manualEntryToggle

                Spacer(minLength: 0)
            }
            .padding(28)
        }
    }

    private var titleText: String {
        let opponent = ai?.name ?? "TavTav"
        switch context {
        case .match, .practice:
            if let human { return "\(human.name) gegen \(opponent)" }
            return "Übungsspiel gegen \(opponent)"
        case .finale:
            if let human { return "Finale: \(human.name) gegen \(opponent)" }
            return "Finale gegen \(opponent)"
        case .resume:
            return ""
        }
    }

    private func colorButton(_ color: EngineColor) -> some View {
        Button { humanColor = color } label: {
            VStack(spacing: 12) {
                Circle()
                    .fill(ChromeTheme.checkerColor(color))
                    .overlay(Circle().stroke(ChromeTheme.ink.opacity(0.25), lineWidth: 1.5))
                    .frame(width: 56, height: 56)
                Text(Weltsensation.colorName(color))
                    .foregroundStyle(ChromeTheme.ink)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(ChromeButton(role: .secondary))
    }

    /// Quiet, deliberately low-key opt-in. The obvious path is to pick a colour and
    /// just play on the iPad (auto-roll). Arming this instead plays the game on the
    /// real board: every roll — including the AI's — is keyed in by hand, and the AI
    /// never auto-moves. Ignorable if you're not looking for it.
    private var manualEntryToggle: some View {
        Button { manualDice.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: manualDice ? "checkmark.circle.fill" : "circle")
                Text("Am echten Brett (Würfel manuell eintragen)")
            }
            .font(ChromeType.caption)
        }
        .buttonStyle(ChromeButton(role: .quiet))
    }

    private var invalidView: some View {
        ZStack {
            Weltsensation.page.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Kein Spiel gegen \(model.aiPlayer?.name ?? "TavTav") möglich")
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeTheme.ink)
                Text("In dieser Partie spielt \(model.aiPlayer?.name ?? "TavTav") nicht mit.")
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeKit.inkSecondary)
                    .multilineTextAlignment(.center)
                Button("Schließen", action: onClose)
                    .buttonStyle(ChromeButton(role: .primary))
            }
            .padding(28)
        }
    }

    // MARK: - Build the session

    private func start(humanColor hc: EngineColor, starter: EngineColor) {
        // The obvious path is auto-roll (anyone can just play on the iPad). The quiet
        // "Am echten Brett" toggle arms manual entry instead: every roll — including
        // the AI's — is keyed in by hand and the AI never auto-moves. GameView
        // re-syncs `manualDiceEntry` from this shared setting on appear, so write it
        // here to match `manualDice`; the in-game gear can still switch afterwards.
        let mode: DiceModeSetting = manualDice ? .manual : .auto
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.diceMode)

        let s = GameSession(startingPlayer: starter,
                            agent: GameSession.makeAgent(),
                            aiColor: hc.opponent,
                            animationTimings: AppSettings.animationTimings,
                            manualDiceEntry: manualDice)

        let header = makeHeader(humanColor: hc, starter: starter)
        let model = self.model
        // Record the tournament result when the game ends (the per-move autosave
        // captures the final board + outcome via `persist`).
        s.onGameOver = { winner in model.recordOutcome(for: header, winner: winner) }
        s.start()
        saved = header
        session = s
    }

    /// Re-open a saved game at its last position. Skips the colour/opening-roll
    /// screens; restores the dice mode it was played in; re-arms result recording so
    /// finishing a resumed match still counts. A finished game replays straight to
    /// its win overlay (review only — `onGameOver` does not re-fire on replay).
    private func startResume() {
        guard case .resume(let savedGame) = context, session == nil else { return }

        let mode: DiceModeSetting = savedGame.manualDiceEntry ? .manual : .auto
        UserDefaults.standard.set(mode.rawValue, forKey: SettingsKey.diceMode)

        let s = GameSession.resume(from: savedGame.gameSave,
                                   agent: GameSession.makeAgent(),
                                   animationTimings: AppSettings.animationTimings,
                                   manualDiceEntry: savedGame.manualDiceEntry,
                                   autoRoll: AppSettings.autoRoll)
        let model = self.model
        s.onGameOver = { winner in model.recordOutcome(for: savedGame, winner: winner) }
        s.start()
        humanColor = savedGame.humanColor
        saved = savedGame
        session = s
    }

    /// The persistent header (stable identity + who/what/which-colour) for a fresh
    /// game. The `.resume` case never reaches here (it carries its own record).
    private func makeHeader(humanColor hc: EngineColor, starter: EngineColor) -> SavedTournamentGame {
        let kind: SavedTournamentGame.Kind
        var matchID: UUID?
        switch context {
        case .match(let m):  kind = .match; matchID = m.id
        case .finale:        kind = .finale
        case .practice:      kind = .practice
        case .resume(let g): return g
        }
        return SavedTournamentGame(
            kind: kind,
            matchID: matchID,
            humanPlayerID: human?.id,
            aiPlayerID: ai?.id,
            humanName: human?.name,
            aiName: ai?.name ?? "TavTav",
            humanColor: hc,
            startingPlayer: starter,
            manualDiceEntry: manualDice)
    }

    /// Give up = the only way out of a game (there's no back button). Mark the saved
    /// game **conceded** (kept in progress, so it stays resumable and shows as
    /// "Aufgegeben"), concede the match in the standings (AI wins) **without** ending
    /// the session, and return to the tournament. Re-opening it to continue clears the
    /// conceded mark on the next move; finishing it overwrites the conceded result.
    /// Practice records nothing in the standings.
    private func giveUp() {
        save(conceded: true, force: true)
        if let saved { model.recordOutcome(for: saved, winner: saved.aiColor) }
        onClose()
    }

    /// Rewrite the saved game after every move via `GameView.onAutosave`. Active play
    /// clears any earlier "conceded" mark (the game is running again).
    private func persist() { save(conceded: false) }

    /// Write the saved game from the live session. A game with no moves yet writes
    /// nothing (nothing to recover, and it avoids empty list clutter); once it has a
    /// ply, the same file is overwritten with the latest history + outcome + conceded
    /// state. `force` writes even when nothing changed (used by give up so the
    /// conceded mark + timestamp land); without it, re-opening a finished game to
    /// review is a no-op so it isn't bumped to the top of the list for nothing.
    private func save(conceded: Bool, force: Bool = false) {
        guard let saved, let session, !session.record.plies.isEmpty else { return }
        let outcomeRaw = session.record.outcome?.rawValue
        let changed = session.record.plies.count != saved.history.count
            || outcomeRaw != saved.outcomeRaw
            || conceded != (saved.conceded ?? false)
        guard force || changed else { return }

        var record = saved
        record.history = session.record.plies
        record.outcomeRaw = outcomeRaw
        record.conceded = conceded
        record.updatedAt = Date()
        model.persistGame(record)
    }
}
