# Tournament — "Weltsensation" super-app (throwaway branch)

A tournament organizer layered on top of the Tavli app for a one-off family/friends
event. **Lives only on this branch — never merged to `main`, no issue tracking.** The
whole shell is **German**; the AI ("TavTav") is a **regular ranked player**.

Round robin (everyone plays everyone once) → the two strongest play a **finale**.
Matches involving TavTav are played in-app and recorded automatically; human-vs-human
matches are entered by hand. All results are freely overwritable.

## Where the code lives

- **Pure logic + persistence + sync: `TavliEngine`** (covered by `swift test`):
  - `Tournament.swift` — `TournamentPlayer` / `TournamentMatch` / `Finale` /
    `TournamentStanding` + `Tournament` (reconcile pairings preserving results,
    `standings()` = wins ↓ then head-to-head then name, `isRoundRobinComplete`,
    `startFinale`/`topTwo`, `aiGameWinner` colour→player mapping). Also the
    **multi-iPad merge**: per-entity `Stamp`s, `removedPlayers` tombstones, fixed
    seed ids, `merged(with:)` / `mergingForSync(_:)` (entity-level LWW). Every
    mutating method takes `by device:`.
  - `Sync.swift` — `SyncTransport` protocol + the in-process `LoopbackTransport` /
    `LoopbackHub` (tests + a possible single-process two-window dev mode).
  - `TournamentStore.swift` — JSON at `Documents/Tournament/tournament.json`
    (synchronous, schema-versioned; modeled on `SaveStore`).
  - `TournamentGameStore.swift` — `SavedTournamentGame` (one in-app AI game: move
    history + who played / colour / kind / outcome / dice mode) + its file-backed
    store (one JSON per game under `Documents/Tournament/Games`; **local-only, never
    synced**). Replay-based like `GameSave`; `gameSave` adapts a record for
    `GameSession.resume`.
  - Tests: `TournamentTests.swift` (logic) + `TournamentSyncTests.swift` (merge
    conflict resolution + 3-node loopback convergence) +
    `TournamentGameStoreTests.swift` (per-game save round-trip + resume parity).
- **Views + model: this folder** (`ios/TavliApp/TavliApp/Tournament/`):

| File | What it is |
|---|---|
| `AppRoot.swift` | App entry: `-uiTestGame` → original `RootView`; locked → `LockView`; unlocked → `TournamentRootView`. Bound to `@AppStorage(WeltsensationKey.unlocked)`. Also defines `GermanLocale` (the German-pinning helper) + the `de`-only `GermanBundle`. |
| `LockView.swift` | Password gate. Hardcoded `Weltsensation.password` (`"Tavli"`); pass once, remembered; "App sperren" in Setup re-locks. Insecure on purpose. |
| `TournamentModel.swift` | `@MainActor ObservableObject` wrapping `Tournament` + `TournamentStore` + a `SyncTransport`; **persists + broadcasts after every mutation** via `mutate(_:)`, stamping edits with a persisted `deviceID`. Merges incoming peer state in `receive(_:)` (gossips onward only if it changed). Publishes `peerNames`. Default seeds TavTav. Also owns a **`TournamentGameStore`** for the local (un-synced) saved games: `persistGame` (per-move autosave, no republish), `reloadSavedGames` (publishes `savedGames` when the list is shown), `deleteSavedGame`, and `recordOutcome(for:winner:)` (maps a finished saved game's winner back onto its match/finale). |
| `MultipeerTransport.swift` | The real-radio `SyncTransport`: a MultipeerConnectivity mesh over the `tavli-turnier` service. Both advertises + browses; lower `deviceID` invites, advertiser auto-accepts (trusted event); encrypted; sends the whole `Tournament` on each change. |
| `TournamentRootView.swift` | TabView shell (Tabelle / Spiele / Setup; persistent TavTav logo pinned top-trailing, non-interactive, hidden during a game) + `GameContext` (`match`/`finale`/`practice`/**`resume(SavedTournamentGame)`**) + `TournamentGameFlow` (colour choice → `OpeningRollView` → `GameView`; `onGameOver` records the result). **Every in-app game is auto-saved after every move** (`GameView.onAutosave` → `persist()` rewrites one `SavedTournamentGame` keyed by a stable per-game id), so an interrupted game is never lost; a `.resume` context skips the colour/opening-roll screens, rebuilds the session via `GameSession.resume`, restores its dice mode, and re-arms result recording so a resumed match still counts (a finished game replays to its win overlay for review only — `onGameOver` doesn't re-fire on replay). The game has **no back button** (`showsBackButton: false`); the only way out is **Aufgeben** (`onGiveUp` → `giveUp()`), which concedes the match in the standings (AI wins) but leaves the session in progress, so the saved game stays resumable — re-open it to continue from the last position (finishing then overwrites the conceded result). The colour screen carries a quiet **"Am echten Brett (Würfel manuell eintragen)"** opt-in: off = auto-roll on the iPad (the obvious path); on = the session is built `manualDiceEntry: true` so every roll incl. the AI's is keyed in by hand and the AI never auto-moves. |
| `StandingsView.swift` | Main view. Gold **podium** for ranks 1–2, ranked table for the rest, finale flow ("Finale starten" once all games entered; AI finalist → launches the game), champion banner. |
| `MatchesView.swift` | "Spiele" list (Offen / Gespielt) + result sheet (winner pick / clear / "Gegen TavTav spielen"). |
| `SetupView.swift` | Players (add/rename/remove, "TavTav hinzufügen") + **"Gespeicherte Spiele"** (every in-app game played/started on this device, newest first, from `model.savedGames`: shows who played + colour + status — running, given up ("Aufgegeben", still resumable), or finished with the winner; tap a row to resume/re-open via `.resume`, trash to delete) + **"Geräte"** sync indicator (live connected-peer count/names from `model.peerNames`) + settings (App sperren, Ergebnisse zurücksetzen, Übungsspiel). |
| `TournamentStyle.swift` | `Weltsensation` tokens (gold, page, German colour names, password), `WeltsensationKey`, `AIBadge`, `PlayerNameLabel` (shows the `TavTavAvatar` smirk face before the name when the player `isAI`, then the "AI" pill). |

## Conventions / gotchas

- **One source of truth.** All mutations go through `TournamentModel.mutate(_:)`,
  which persists **and broadcasts** to the sync mesh. Don't mutate `Tournament`
  anywhere else — and pass the model's `deviceID` (`by:`) so the edit is stamped.
- **Multi-iPad sync (≤3, same WiFi, serverless).** Implemented as an **entity-level
  last-writer-wins** merge over a MultipeerConnectivity mesh. The whole (tiny)
  `Tournament` is broadcast on every change and reconciled with `merged(with:)`;
  concurrent edits to *different* matches both survive, same-entity conflicts resolve
  by `Stamp` (a Lamport counter, device-uuid tiebreak). Three load-bearing pieces:
  (1) **fixed seed ids** (`seedRoster`) so every freshly-launched iPad shares the
  default roster and merging two pristine devices is a no-op; (2) **tombstones**
  (`removedPlayers`) so a removal isn't resurrected by a stale peer; (3) **gossip that
  settles** — `receive` rebroadcasts only when the merge changed something. Live game
  *boards* are **not** synced — only recorded results reach `Tournament` (via
  `onGameOver`). The correctness core is `swift test`-covered (`TournamentSyncTests`);
  the radio (`MultipeerTransport`) is verified by build, and needs two real devices to
  exercise end-to-end (the iOS Simulator can't do MultipeerConnectivity — pair an
  iPhone, or run a native "Designed for iPad" Mac build, against an iPad).
- **Sync needs Info.plist keys.** MultipeerConnectivity on iOS 14+ requires
  `NSLocalNetworkUsageDescription` + `NSBonjourServices`
  (`_tavli-turnier._tcp`/`._udp`) — both already in `Info.plist`. The service-type
  string `tavli-turnier` (≤15 chars) must match the Bonjour entries.
- **Reuses the Caramel chrome** (`ChromeKit`/`ChromeTheme`/`ChromeType`/`CaramelPalette`)
  — no bespoke styling. Gold accent = `CaramelPalette.hl` via `Weltsensation.gold`.
- **AI games reuse `GameSession` + `GameView`** unchanged except additive optional
  hooks: `tournamentExit` (relabels the win-overlay primary to "Zurück zum Turnier"),
  `tournamentOpponentName` (German loss verdict), `onAutosave` (per-move persist),
  `showsBackButton: false` (no back button — give up is the only exit), and `onGiveUp`
  (concede-and-leave: records the loss but keeps the in-progress game resumable,
  instead of the default in-place `session.surrender()`).
- **In-app games are auto-saved per move** to a local `TournamentGameStore` (one
  `SavedTournamentGame` per game, keyed by a stable id, **never synced** — each iPad
  keeps the games it played). Saving starts on the first committed ply (a no-move game
  writes nothing, so backing out of the colour screen leaves no clutter). The Setup
  "Gespeicherte Spiele" list resumes them; finishing a resumed match still records its
  result (the saved record carries its own match/player ids). Only the tournament
  *standings* sync between iPads, not these per-game saves.
- **German, always.** `main` added a String Catalog (`Localizable.xcstrings`, EN
  source + `de`/`nl`). The tournament must read German even on Johannes' Dutch iPad,
  so `AppRoot` pins the app to `de` two ways: `.environment(\.locale, GermanLocale.locale)`
  on the real screens (SwiftUI `Text`/formatting) **and** `GermanLocale.pinMainBundle()`
  at launch (swaps `Bundle.main`'s class so `String(localized:)`/`NSLocalizedString`
  resolve from `de.lproj` — they ignore the environment locale). The `-uiTestGame`
  path is left English (its UI test asserts the base strings).
- **TavTav, by name.** The on-device opponent is branded **"TavTav"**, not "AI"/"KI".
  `main` (#126) renamed the in-play game-chrome strings ("TavTav thinking…", "TavTav
  goes first!", "TavTav starts", "Enter TavTav's dice", "Human vs TavTav") in EN/DE/NL,
  and the tournament shell copy interpolates the live `model.aiPlayer?.name` (default
  "TavTav") — e.g. `Label("Gegen \(ai.name) spielen", …)` — so renaming the AI player
  in Setup carries through everywhere. Only the `AIBadge` pill (the "AI" type-marker
  beside the name) and app-level **technology** references (the "Animate AI moves"
  setting, "Play vs AI", "Review needs the AI model") keep "AI".
- **TavTav, by face.** TavTav also has a **mascot/logo** (the wooden steam-locomotive), wired
  via `Views/TavTavMascot.swift` (`TavTavLogo` / `TavTavLogoTile` / `TavTavAvatar` / `TavTavLoco`).
  The full logo (loco + wordmark + dice) is **its own tile on top of the in-game chrome and the
  opening-roll panel** (full-width in landscape, same max size in portrait) and is **pinned
  top-trailing across all tournament tabs** (`TournamentRootView`). The win/loss overlay and the
  `PlayerNameLabel` row use the `TavTavAvatar` face (smirk if TavTav won/leads, friendly if it
  lost). Concept, rollout, and the asset-creation prompts live in `ios/TavliApp/MASCOT.md`;
  assets in `Resources/Assets.xcassets/TavTav*`.
- **App name** is set via `Info.plist` `CFBundleDisplayName = Weltsensation` (the
  bundle/product name is unchanged). Adding new files here requires re-running
  `bash ios/TavliApp/setup.sh` so xcodegen re-globs sources.
