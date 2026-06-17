import SwiftUI
import TavliEngine

private typealias SColor = SwiftUI.Color
private typealias EngineColor = TavliEngine.Color

/// What an in-app game is being played for. A `match`/`finale` records its
/// outcome onto the tournament; `practice` is an unscored game vs the AI.
enum GameContext: Identifiable {
    case match(TournamentMatch)
    case finale(Finale)
    case practice

    var id: String {
        switch self {
        case .match(let m):  return "match-\(m.id.uuidString)"
        case .finale:        return "finale"
        case .practice:      return "practice"
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
        .fullScreenCover(item: $game) { ctx in
            TournamentGameFlow(model: model, context: ctx, onClose: { game = nil })
        }
    }

    private func launch(_ ctx: GameContext) { game = ctx }
}

/// Drives one in-app AI game: pick the human's colour → opening roll → the full
/// `GameView`. On game over the result is recorded onto the originating match or
/// finale (practice records nothing). The win overlay / back both route to
/// `onClose`, returning to the tournament with the standings refreshed.
private struct TournamentGameFlow: View {
    @ObservedObject var model: TournamentModel
    let context: GameContext
    let onClose: () -> Void

    @State private var humanColor: EngineColor?
    @State private var session: GameSession?

    /// Whether this game is played on the real board with the dice keyed in by hand
    /// (the quiet "Am echten Brett" opt-in on the colour screen). Off = the obvious
    /// path: auto-roll on the iPad. Reset per game (a fresh flow each launch).
    @State private var manualDice = false

    // Resolve the human / AI sides up front (captured into `onGameOver`).
    private var ai: TournamentPlayer? {
        switch context {
        case .match(let m):  return model.humanAndAI(in: m)?.ai
        case .finale(let f): return model.humanAndAI(in: f)?.ai
        case .practice:      return model.aiPlayer
        }
    }

    private var human: TournamentPlayer? {
        switch context {
        case .match(let m):  return model.humanAndAI(in: m)?.human
        case .finale(let f): return model.humanAndAI(in: f)?.human
        case .practice:      return nil
        }
    }

    var body: some View {
        Group {
            if ai == nil {
                invalidView
            } else if let session {
                GameView(session: session,
                         humanColor: humanColor ?? .white,
                         onBack: onClose,
                         tournamentExit: onClose,
                         tournamentOpponentName: ai?.name,
                         tournamentRestart: restartManual)
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
        let opponent = ai?.name ?? "Tavtav"
        switch context {
        case .match, .practice:
            if let human { return "\(human.name) gegen \(opponent)" }
            return "Übungsspiel gegen \(opponent)"
        case .finale:
            if let human { return "Finale: \(human.name) gegen \(opponent)" }
            return "Finale gegen \(opponent)"
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
                Text("Kein Spiel gegen \(model.aiPlayer?.name ?? "Tavtav") möglich")
                    .font(ChromeType.headline)
                    .foregroundStyle(ChromeTheme.ink)
                Text("In dieser Partie spielt \(model.aiPlayer?.name ?? "Tavtav") nicht mit.")
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

    /// Recovery for "started in auto by mistake": re-arm manual dice entry and drop
    /// back to the opening roll for the same colour. The in-progress session is
    /// discarded (it recorded nothing — no game-over fired), and the next `start`
    /// rebuilds it in manual mode. Wired to `GameView.tournamentRestart`.
    private func restartManual() {
        manualDice = true
        session = nil
    }

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

        // Capture the resolved sides + context by value: the result is recorded
        // when the game ends, then the user returns to the tournament via onClose.
        let human = self.human
        let ai = self.ai
        let context = self.context
        let model = self.model
        s.onGameOver = { winner in
            guard let ai else { return }
            switch context {
            case .match(let m):
                guard let human else { return }
                model.recordAIMatch(matchID: m.id, human: human, ai: ai,
                                    humanColor: hc, winner: winner)
            case .finale:
                guard let human else { return }
                model.recordFinaleGame(human: human, ai: ai, humanColor: hc, winner: winner)
            case .practice:
                break
            }
        }
        s.start()
        session = s
    }
}
