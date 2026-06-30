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
        Group {
            if let session = coordinator.session {
                OnlineGameView(coordinator: coordinator, session: session)
            } else {
                OnlineLobbyView(coordinator: coordinator, onExit: onExit)
            }
        }
        .onAppear { coordinator.authenticate() }
    }
}

/// A live online game: the ordinary `GameView`, fed an `Online` context so the chrome
/// locks the board off-turn, shows the waiting state, and exits to the lobby. `isLocalTurn`
/// is recomputed here on every session publish (this view observes the session), so the
/// lock tracks the turn without the coordinator having to publish it.
private struct OnlineGameView: View {
    @ObservedObject var coordinator: GameKitCoordinator
    @ObservedObject var session: GameSession

    private var isLocalTurn: Bool {
        session.currentPlayer == coordinator.localColor && !session.isTerminal
    }

    /// Best-of-three context (#145), present only for a multi-game match. The session
    /// advances behind the overlay, so the result overlay is driven by the coordinator's
    /// `pendingGameResult` rather than the session phase.
    private var matchContext: GameView.Match? {
        guard coordinator.matchState.isMatch else { return nil }
        return GameView.Match(
            state: coordinator.matchState,
            localColor: coordinator.localColor,
            opponentName: coordinator.opponentName,
            lastGameWinner: coordinator.pendingGameResult,
            showResultOverlay: coordinator.pendingGameResult != nil,
            onNextGame: { coordinator.continueToNextGame() },
            onRematch: nil,
            onExit: { coordinator.leaveMatch() }
        )
    }

    var body: some View {
        GameView(
            session: session,
            humanColor: coordinator.localColor,
            showsBackButton: false,
            online: GameView.Online(
                localColor: coordinator.localColor,
                isLocalTurn: isLocalTurn,
                opponentName: coordinator.opponentName,
                banner: coordinator.statusBanner,
                onLeave: { coordinator.leaveMatch() }
            ),
            match: matchContext
        )
    }
}

/// The Game Center lobby: sign-in state, "Invite a friend", and the list of the
/// player's ongoing matches to resume.
private struct OnlineLobbyView: View {
    @ObservedObject var coordinator: GameKitCoordinator
    let onExit: () -> Void

    /// Match length for the next invite (#145). Defaults to best-of-three.
    @AppStorage(SettingsKey.onlineMatchLength) private var matchLength: MatchLengthSetting = .bestOfThree

    var body: some View {
        ZStack {
            SColor(hex: 0xece6dc).ignoresSafeArea()
            VStack(spacing: 24) {
                header
                Text("Play Online")
                    .font(ChromeType.wordmark)
                    .foregroundStyle(CaramelPalette.frameText)

                if coordinator.isAuthenticated {
                    authenticatedBody
                } else {
                    signInPrompt
                }
                Spacer(minLength: 0)
            }
            .padding(40)
            .frame(maxWidth: 520)
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
    }

    @ViewBuilder
    private var authenticatedBody: some View {
        Picker("Match length", selection: $matchLength) {
            ForEach(MatchLengthSetting.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .tint(ChromeTheme.undoTint)
        .frame(maxWidth: 392)

        Button {
            coordinator.presentInvite(targetWins: matchLength.targetWins)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                Text("Invite a friend")
            }
        }
        .buttonStyle(ChromeButton(role: .primary, fullWidth: true))
        .frame(maxWidth: 392)

        if let banner = coordinator.statusBanner {
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
        .chromeCard(padding: 24)
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

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                Text(opponentName)
                Spacer(minLength: 12)
                Text(isLocalTurn ? "Your turn" : "Their turn")
                    .foregroundStyle(isLocalTurn ? ChromeTheme.doneTint : ChromeKit.inkSecondary)
                Image(systemName: "chevron.right")
                    .foregroundStyle(ChromeKit.inkSecondary)
            }
        }
        .buttonStyle(ChromeButton(role: .secondary, fullWidth: true))
    }
}
