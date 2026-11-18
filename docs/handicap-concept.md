# Handicap system: concept for phases 2–4 (#148)

Status: **concept, decisions taken 2026-11-18; nothing implemented or trained.** Builds on the
phase-1 measurements in `docs/handicap-phase1.md` (gold_v11 self-play, house Plakoto, 1-ply).

## Decisions (user, 2026-11-18)

| Topic | Decision |
|---|---|
| Audience | **Both:** two players on one device, and vs Computer in either direction |
| Approach | **Head start first:** no rules change; add a rule-changing lever (smaller home) only if the range is too small |
| Choosing | **A handicap builder:** a list of handicaps (toggles and sliders) with a **live win-chance estimate assuming both sides play at full strength**. Built that way from day one, even with one lever |
| Hiding | **Settings only:** the new-game sheet, game screen and stats look exactly as today unless a handicap is active |
| Variants | **House Plakoto only** |
| Statistics | Handicap games are kept **separate** from the vs-Computer record. Players who never use a handicap see **no change at all** |

## 1. What the feature is for

A handicap lets two players of **different strength** have a close game. One side gets a
structural advantage, and both keep playing by the normal rules. It's the same idea as
handicap stones in Go.

- **Two players on one device:** e.g. parent and child; the weaker player gets a head start.
- **Beginner vs Computer:** the computer plays at full strength (no "silly" noise moves) and the
  beginner gets a head start. That makes for a fair, *instructive* game.
- **Strong player vs Computer:** give the *computer* the head start, for a harder game than
  level 8.
- **Online:** out of scope; both devices would need to agree on the rules.

## 2. What phase 1 found

Only three levers reliably weaken a side *in the right direction*. The dice and tempo kinds turn
out inverted or binary under house Plakoto's exact-die bear-off.

| Lever | Effect between equal players | Rules change? | Retraining? |
|---|---|---|---|
| **Head start** (m checkers start 6 pips advanced) | m=1: 1.5 pp, m=2: 4.7, m=4: 7.2 | No, just a start position | Maybe a short fine-tune (E2) |
| **Moves first** | 2.8 pp (= the first-move edge) | No | No |
| **Smaller home** (bear off only from the last 5/4/3 points) | 5.5 / 11.7 / 22.7 pp | **Yes** | **Yes** (encoder + bear-off DB) |

## 3. The handicap builder (UI model)

A list of handicap items. Each item is either a **toggle** or a **slider**, and each is
assigned to a side. In the first version the list has two items:

| Item | Control | Side |
|---|---|---|
| **Head start**: "n checkers start 6 points ahead" (wording to be refined) | Slider 0…N | White / Red (or You / Computer) |
| **Moves first** | Toggle (replaces the opening roll) | White / Red |

(If E1 extends the lever, e.g. to 12-pip advances, it becomes a second slider or a richer
single slider; see §5.)

Below the list there's one result line, updated live as you change anything:

> **Estimated win chance: White 61 % · Red 39 %**
> *if both played at the computer's full strength*

- "Optimal play" can't be computed for Plakoto. The closest honest proxy is the strongest player
  we have: the full-strength computer playing both sides. The footnote says so.
- The builder is generic: adding a lever later (smaller home, other variants) means adding one
  row, and the estimator below handles any combination.

## 4. The win-chance estimator

The estimate must work for *any* combination of items, so a hand-picked ladder of fixed steps
won't do. Two candidate methods, and the plan is to use both:

1. **Net evaluation (primary).** The value network already estimates the win probability of any
   position. For a handicap setup, build the start position, then average the net's
   best-move evaluation over the opening rolls. With "moves first", only the chosen side rolls,
   so the estimate covers its 21 dice combinations; otherwise the opening roll-off is modelled.
   That gives an instant, on-device estimate for every combination, with no table.
   - **Risk:** the net was never trained on head-start positions, so its estimates there might be
     off. Experiment **E1** checks this directly: net estimate vs measured self-play result per
     configuration. Ship it only if the error is **≤ 2 pp** across the range.
2. **Measured table (fallback / validation).** With only head start × moves first, the full grid
   is small (e.g. 9 × 2 = 18 cells), so it can be measured outright with the paired
   duplicate-dice harness (2 000 pairs per cell, ±1.5 pp) and shipped as JSON. If the net
   estimate is inaccurate, the app uses the table; if a short fine-tune (E2) fixes the net, the
   table becomes the regression test.

## 5. Plan and gates

| # | Step | Kind | Gate / output | Est. cost |
|---|---|---|---|---|
| **E1** | Extended head-start sweep: m = 0…8 (and 12-pip advances), with and without moves first, 1 000 pairs/cell at full strength. Record the net's estimate per cell next to the measured result | Experiment, no training | (a) Range: does head start + moves first reach ≳ 25 pp, monotone? (b) Is the net estimate within 2 pp? | ~2 h CPU |
| **E2** | *Only if E1(b) fails or games look odd:* short fine-tune of gold_v11 with ~30 % of self-play games starting from random head-start setups. Same network shape | Training | No regression in normal games vs gold_v11 (paired non-inferiority); estimate error ≤ 2 pp | ~½ day |
| **E3** | *Only if E1(a) fails:* smaller-home lever: rules (Python + Swift), per-side home-size encoder features (widen the net with zero-initialised weights), fine-tune, board shading | Experiment + training | Same gates | 1–2 days training + more UI work |
| **P3** | Final measurement of the shipped grid at full strength | Measurement | Table + validated estimator | ~3–5 h CPU |
| **P4** | iOS (see §6) | Implementation | Tests; UI review on device | 1–2 PRs |
| Docs | `domain/`, `ai/`, iOS `REFERENCE.md` + this doc | Docs | — | with each PR |

Training and experiments wait until the Fevga run (#141) is done (CPU).

## 6. In the app

**Principle: if you don't use handicaps, nothing changes.** No new rows in the new-game sheet,
no new labels in the game, no new sections in the statistics.

- **Settings → Handicap** (one row, last section, "Off" by default). It opens the builder (§3)
  with the live estimate. The sides are shown as "You / Computer" or "White / Red" depending on
  the mode of the next game. Turning it on applies to new house-Plakoto games until it's turned
  off; other variants ignore it, and the builder says so.
- **During a handicap game:** a small "Handicap" tag in the top bar (only then); tapping it shows
  the setup and the estimate.
- **Engine:** the Swift engine builds the head-start start position and skips the opening
  roll-off for "moves first". No rule changes. Review, drill and analysis work unchanged, since
  they evaluate ordinary positions.
- **Statistics:** handicap games are stored with their setup and kept out of the vs-Computer
  record. A separate "Handicap games" block appears **only once at least one exists**.
- **Not offered:** online games and Full Tavli/matches (the builder notes this).

## 7. Open points that need no decision now

- Exact wording of the head-start item, and the slider maximum (depends on E1).
- Whether "Head start" uses 6- or 12-pip advances, or both (E1).
- Whether the estimate is computed on-device from the net or looked up (E1 decides; same UI either way).
