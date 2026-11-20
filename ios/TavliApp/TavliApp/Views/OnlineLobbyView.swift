import SwiftUI
import GameKit
import TavliEngine

private typealias SColor = SwiftUI.Color

/// Online multiplayer entry point (#134). Switches between the Game Center lobby and
/// a live match, both driven by a single `GameKitCoordinator`. Observing the
/// coordinator means the view flips to the game the moment a match's session exists
/// (created, joined, or resumed) and back to the lobby when it's cleared.
struct OnlineRootView: View {
    @ObservedObject var coordinator: GameKitCoordinator
    /// Return to the main mode picker.
    let onExit: () -> Void

    var body: some View {
        OnlineRootContent(coordinator: coordinator, controller: coordinator.controller, onExit: onExit)
            .onAppear { coordinator.authenticate(presentUI: true) }
    }
}

/// Observes the match controller so the screen flips to the game the moment a match is
/// open (created, joined, resumed, or opened from a notification) and back to the lobby
/// when it's closed.
private struct OnlineRootContent: View {
    @ObservedObject var coordinator: GameKitCoordinator
    @ObservedObject var controller: OnlineMatchController
    let onExit: () -> Void

    var body: some View {
        if let session = controller.session {
            OnlineGameView(coordinator: coordinator, controller: controller, session: session)
        } else {
            OnlineLobbyView(coordinator: coordinator, controller: controller, onExit: onExit)
        }
    }
}

/// Localized copy for the controller's status.
enum OnlineStatusText {
    static func text(_ status: OnlineMatchStatus?) -> String? {
        switch status {
        case nil: return nil
        case .waitingForOpponentToStart: return String(localized: "Waiting for opponent to start…")
        case .opponentLeft: return String(localized: "Your opponent left the match. You win!")
        case .matchEnded: return String(localized: "Match ended.")
        case .sendFailed: return String(localized: "Couldn’t send your move. It’s saved and will be sent when you’re back online.")
        case .yourTurnElsewhere(let name):
            return name.isEmpty ? String(localized: "It’s your turn in another game.")
                                : String(localized: "It’s your turn against \(name).")
        case .error(let message): return message
        }
    }
}

/// A live online game: the ordinary `GameView` with an `Online` context, so the chrome
/// locks the board off-turn, shows the waiting state, offers Back (keeps the match) and
/// a confirmed forfeit. `isLocalTurn` comes from the controller on every publish.
private struct OnlineGameView: View {
    @ObservedObject var coordinator: GameKitCoordinator
    @ObservedObject var controller: OnlineMatchController
    @ObservedObject var session: GameSession

    private var opponentName: String { controller.opponentName ?? String(localized: "Opponent") }

    /// Best-of-three context (#145), present only for a multi-game match. The session
    /// advances behind the overlay, so the result overlay is driven by the controller's
    /// `pendingGameResult` rather than the session phase.
    private var matchContext: GameView.Match? {
        guard controller.matchState.isMatch else { return nil }
        return GameView.Match(
            state: controller.matchState,
            localColor: controller.localColor,
            opponentName: opponentName,
            lastGameResult: controller.pendingGameResult,
            showResultOverlay: controller.pendingGameResult != nil,
            onNextGame: { controller.continueToNextGame() },
            onRematch: nil,
            onExit: { coordinator.closeMatch() }
        )
    }

    var body: some View {
        GameView(
            session: session,
            humanColor: controller.localColor,
            onBack: { coordinator.closeMatch() },
            showsBackButton: true,
            online: GameView.Online(
                localColor: controller.localColor,
                isLocalTurn: controller.isLocalTurn,
                isMatchOver: controller.isMatchOver,
                opponentName: opponentName,
                banner: OnlineStatusText.text(controller.status),
                onBack: { coordinator.closeMatch() },
                onLeave: { coordinator.forfeitMatch() }
            ),
            match: matchContext
        )
    }
}

/// The Game Center lobby: sign-in state, "Invite a friend", and the list of the
/// player's ongoing matches to resume.
private struct OnlineLobbyView: View {
    @ObservedObject var coordinator: GameKitCoordinator
    @ObservedObject var controller: OnlineMatchController
    let onExit: () -> Void

    /// Match length for the next invite (#145). Defaults to best-of-three.
    @AppStorage(SettingsKey.onlineMatchLength) private var matchLength: MatchLengthSetting = .bestOfThree
    /// Variant for the next invite (#143), shared with the start screen / Settings.
    @AppStorage(SettingsKey.variant) private var variant: GameVariantSetting = .plakoto

    var body: some View {
        ZStack {
            ChromeKit.pageColor.ignoresSafeArea()
            // Scrolls on a phone (#109) when the lobby outgrows a landscape screen.
            FitOrScroll(enabled: ChromeType.isCompact) {
                VStack(spacing: 24) {
                    header
                    Text("Play Online")
                        .font(ChromeType.wordmark)
                        .compactSingleLine()
                        // One line on iPad too: let the wordmark run wider than the
                        // 520 pt column rather than wrap (the screen has the room).
                        .fixedSize(horizontal: !ChromeType.isCompact, vertical: false)
                        .foregroundStyle(CaramelPalette.frameText)

                    if coordinator.isAuthenticated {
                        authenticatedBody
                    } else {
                        signInPrompt
                    }
                    Spacer(minLength: 0)
                }
                .compactPadding(40, compact: 16)
                .frame(maxWidth: 520)
            }
        }
    }

    private var header: some View {
        HStack {
            Button(action: onExit) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
            }
            .buttonStyle(ChromeButton(role: .secondary))
            Spacer()
        }
        // Same 392 pt column as the cards and buttons below, so Back lines up with
        // their leading edge.
        .frame(maxWidth: 392)
    }

    @ViewBuilder
    private var authenticatedBody: some View {
        // Variant for the invite (#143) — every variant works online (two humans, no
        // model needed); the match carries it in its payload, so the joiner plays the
        // same rules.
        VariantPickerView(selection: $variant, showsAIAvailability: false)
            .frame(maxWidth: 392)
            .chromeCard(padding: 20)

        Picker("Match length", selection: $matchLength) {
            ForEach(MatchLengthSetting.onlineCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .tint(ChromeTheme.undoTint)
        .frame(maxWidth: 392)

        Button {
            coordinator.presentInvite(targetWins: matchLength.targetWins, variantID: variant.rawValue)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                Text("Invite a friend")
            }
        }
        .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
        .frame(maxWidth: 392)

        if let banner = OnlineStatusText.text(controller.status) {
            Text(banner)
                .font(ChromeType.caption)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
        }

        if coordinator.matches.isEmpty {
            Text("No games in progress. Invite a friend to start one.")
                .font(ChromeType.callout)
                .foregroundStyle(ChromeKit.inkSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        } else {
            VStack(spacing: 10) {
                Text("Your games")
                    .font(ChromeType.subheadline.bold())
                    .foregroundStyle(ChromeTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(coordinator.matches, id: \.matchID) { match in
                    OnlineMatchRow(match: match) { coordinator.open(match) }
                        .contextMenu {
                            if match.status == .ended {
                                Button(role: .destructive) { coordinator.remove(match) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                }
            }
            .frame(maxWidth: 440)
        }
    }

    private var signInPrompt: some View {
        VStack(spacing: 14) {
            Text("Sign in to Game Center to invite a friend and play online.")
                .font(ChromeType.callout)
                .foregroundStyle(ChromeTheme.ink)
                .multilineTextAlignment(.center)
            if let error = coordinator.authError {
                Text(error)
                    .font(ChromeType.caption)
                    .foregroundStyle(ChromeTheme.surrenderTint)
                    .multilineTextAlignment(.center)
            }
            Button("Try again") { coordinator.authenticate() }
                .buttonStyle(ChromeButton(role: .secondary))
        }
        .chromeCard(padding: ChromeType.isCompact ? 16 : 24)
        .frame(maxWidth: 392)
    }
}

/// One resumable match: opponent name and whose turn it is, tappable to open.
private struct OnlineMatchRow: View {
    let match: GKTurnBasedMatch
    let onOpen: () -> Void

    private var opponentName: String {
        let localID = GKLocalPlayer.local.gamePlayerID
        return match.participants
            .first { $0.player?.gamePlayerID != localID }?
            .player?.displayName ?? String(localized: "Opponent")
    }

    private var isLocalTurn: Bool {
        match.currentParticipant?.player?.gamePlayerID == GKLocalPlayer.local.gamePlayerID
    }

    private var isFinished: Bool { match.status == .ended }

    private var stateLabel: String {
        if isFinished { return String(localized: "Finished") }
        return isLocalTurn ? String(localized: "Your turn") : String(localized: "Their turn")
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                Text(opponentName)
                Spacer(minLength: 12)
                Text(stateLabel)
                    .foregroundStyle(isLocalTurn && !isFinished ? ChromeTheme.doneTint : ChromeKit.inkSecondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
    }
}
