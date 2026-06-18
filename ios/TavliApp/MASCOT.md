# TavTav — mascot concept & rollout

The on-device AI opponent is branded **TavTav** (not "AI"/"KI"; see
`Tournament/CLAUDE.md` → "TavTav, by name"). This doc is the concept for giving
that name a *face* — the wooden steam-locomotive mascot — and the plan for where
it appears in the app.

## Status

**Implemented** (`Views/TavTavMascot.swift`, wired into `GameView` and `OpeningRollView`;
build verified via `xcodebuild`). The tournament-shell surfaces mentioned below (player-row
avatar, corner logo) live on the separate tournament branch, not on `main`. Two source images
were provided and map to the two personas:

- **`.smirk`** — the confident face (with the "TAVTAV" nameplate). The default opponent face;
  the player-row avatar, the opening-roll smirk, and the tournament corner logo.
- **`.friendly`** — the gentle, steam-puffing face. Shown when TavTav is gracious: clearly
  behind on win probability, a loss, or the human winning the opening roll.

Key behaviour (per feedback):

- **Full logo as its own tile, always on top.** The in-game chrome shows the full `TavTavLogo`
  (loco + wordmark + dice). In **landscape**, `TavTavLogoTile` spans the 280pt side panel on top.
  In **portrait**, the logo floats in the **top-right** corner (180pt) over the empty band while
  the debug toggle + borne-off counters move to the left to clear that space — so the logo never
  pushes the full-width board down. (The opening-roll panel uses the same top tile.) The earlier
  flashing badge / win-probability mood coordinator was removed.
- **Face reacts at the verdict.** The win/loss overlay still shows the `TavTavAvatar` face —
  smirk if TavTav won, friendly if it lost. Player rows show the smirk face.
- **Corner logo.** The full logo is pinned **top-trailing** across all tournament tabs (the
  only corner free on every tab — titles sit centred/leading, the tab bar owns the bottom).
  Non-interactive; hidden during a game (which has the logo tile in its own chrome).

The full logo (`TavTavLogo`, from `full logo.png`) and the circular face crops (`TavTav*Face`)
were cropped to content with a CoreGraphics tool, then downscaled (logo → 768²-fit, fulls →
512², faces → 256²).

**Not yet done:** the mono glyph; explicit loss/coaching *expression* variants (the loss reuses
`.friendly`); and the P2 coaching / stats / empty-state / app-icon surfaces.

## Creative principle

TavTav is the **engine that drives the game** — a little locomotive that's quietly
sure it'll beat you (the smirk does the work). The train metaphor gives us a motion
language for free:

- **steam puffing = thinking** (the engine is computing its move)
- **wheels turning = working** (animating a turn)
- **whistle / smirk = a move landing / a win**

The mascot's palette — warm wood browns, cream, and the **backgammon-diamond inlays
on the boiler and wheels** — already matches `CaramelPalette` (`Views/BoardView.swift`:
`frame*`, `triangleFill 0xfbeed1`, `diamond*`, ink `0x2a1408`, amber `hl 0xf4b400`).
No re-tinting needed; it drops straight into the Caramel chrome.

**Restraint.** Chrome is sized large for older players (`ChromeType`). The mascot
*decorates* — it never crowds the board, replaces legible text, or animates during
the player's own turn. Personality is strongest where TavTav is genuinely present
(playing you live); quietest where it's just a label in a list.

## Asset set

One illustration won't cover every slot. Cut these from the source art:

| Variant | What it is | Drives |
|---|---|---|
| **Hero** | Full piece (loco + wordmark + dice) | Lock screen, about, big empty states |
| **Loco-only** | Engine, no wordmark | Decorative headers, win/loss overlays |
| **Face avatar** | Circular crop of the smirking face | The workhorse — player rows, turn indicator, badges |
| **Animated loco** | Steam puff + wheel spin | "TavTav thinking…", dice roll (see "Animation" below) |
| **Mono glyph** | Single-colour silhouette | Tiny badges where full colour clashes |

Expression variants are a *nice-to-have*, not required to ship: ideally a confident
smirk (opponent / win), a good-natured "you got me" (loss), and a thoughtful face
(coaching). P0 ships with the single smirk; state is carried by the caption text.

## Placement map

### P0 — In the live game (core app — merges to `main`, not just the tournament branch)

| Surface | Where | Treatment |
|---|---|---|
| **Turn indicator** | `Views/GameView.swift:508` ("TavTav thinking…") | **Animated loco** — steam while the expectimax search runs. The single best slot. |
| **Opening roll** | `Views/OpeningRollView.swift:167,183` ("TavTav goes first!" / "TavTav starts") | Face avatar beside the verdict; mono glyph on the button. |
| **Manual dice** | `Views/GameView.swift:520` ("Enter TavTav's dice") | Face avatar so the player knows whose dice they're keying in. |
| **Win / loss overlay** | `Views/GameView.swift:279` ("… war stärker.") | Face avatar; smirk on a TavTav win, good-natured on a loss. |

### P1 — Identity & the tournament shell (TavTav is a *ranked player*)

| Surface | Where | Treatment |
|---|---|---|
| **Player portrait** | `Tournament/TournamentStyle.swift:32,47` (`AIBadge` / `PlayerNameLabel`) | Face avatar as TavTav's portrait in standings / matches / podium. Keep the "AI" pill as the tech type-marker; the avatar makes it a personality, not a row. |
| **Play actions** | `Tournament/MatchesView.swift:52`, `Tournament/SetupView.swift:196` ("Gegen/Übungsspiel gegen TavTav") | Mono glyph on the buttons. |
| **Re-add** | `Tournament/SetupView.swift:102` ("TavTav hinzufügen") | Face avatar — bringing the character back. |
| **Lock screen** | `Tournament/LockView.swift` | Hero art above the password gate (sets the "Weltsensation" tone). |

### P2 — Coaching & ambient (TavTav as coach)

| Surface | Where | Treatment |
|---|---|---|
| **Review / drill** | `Views/GameReviewView.swift`, `Views/DrillView.swift` | Face avatar framing blunder feedback — a thoughtful expression (≠ smug opponent). |
| **Stats** | `Views/StatsPanelView.swift:16` ("Human vs TavTav") | Small loco-only mark as the section header. |
| **Empty states** | Setup "Noch keine Partien…", empty saved-games list | Hero / loco-only so blank screens feel intentional. |
| **App icon** | App target | Loco-face candidate — test the smirk at 60pt. |

### Don'ts
- No animation during the player's own turn (distracts from the board).
- Below ~28pt, drop to the mono glyph — the expressive face needs room.
- One consistent avatar crop everywhere, so TavTav is instantly the same character.

## Implementation

### 1. Assets → asset catalog
Add the variants to an `.xcassets` (e.g. `Assets.xcassets/TavTav/` with one imageset
per variant, `@1x/@2x/@3x` or a single PDF/SVG vector set). New asset catalogs/files
need xcodegen to re-glob: **re-run `bash ios/TavliApp/setup.sh`** after adding them
(see `ios/CLAUDE.md`).

### 2. A reusable avatar view
`TavTavAvatar` (size param, optional expression) → one source of truth, used by the
turn indicator, `PlayerNameLabel`/`AIBadge`, overlays, and coaching screens. Style it
with the existing `ChromeKit`/`CaramelPalette` tokens — no bespoke gradients.

### 3. Wire into the P0 surfaces
Swap the avatar into the four P0 slots above. These read `session.phase` /
`rollState` state that already exists; this is presentation only (no game logic in
views — `Views/CLAUDE.md`).

### 4. The "thinking" animation
Two options:
- **SwiftUI-native (recommended):** drive steam puffs (offset/opacity) + a wheel
  rotation with `withAnimation`/`TimelineView`. No dependency, fits the offline,
  dependency-light app. Keep it to the `aiThinking` phase only.
- **Lottie:** smoother, but adds a SwiftPM dependency. Only if the native version
  can't carry the personality.

### 5. Docs
Update `Tournament/CLAUDE.md` ("TavTav, by name") and `Views/CLAUDE.md` to point at
this file and the `TavTavAvatar` view once it lands.

## Who makes what

**Needs new illustration (you / an image tool — cannot be code-generated):**
- The high-res **source art**, ideally a **transparent-background PNG** (the shared
  art has a cream background; a clean cutout lets the loco-only + avatar crops be
  isolated cleanly).
- Any **expression variants** (smug-win / good-natured-loss / thoughtful-coach) —
  these are fresh drawings, not crops.

**Can be produced from the source (code / tooling):**
- **Face-avatar** and **loco-only** crops, masked + exported `@1x/2x/3x` — deterministic
  image processing from a clean source PNG.
- The **mono glyph** as hand-authored SVG.
- All **asset-catalog scaffolding**, the **`TavTavAvatar`** view, the **P0 wiring**,
  and the **code-driven thinking animation**.

**Minimal path to ship P0:** hand over one transparent-background mascot PNG → the
avatar + loco crops are derived from it, wired into the four P0 slots, using the
single smirk everywhere (state via caption). Expressions and the tournament/coaching
surfaces follow.
