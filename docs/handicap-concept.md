# Handicap system: concept for phases 2–4 (#148)

Status: **concept, decisions taken 2026-11-18; nothing implemented or trained.** Builds on the
phase-1 measurements in `docs/handicap-phase1.md` (gold_v11 self-play, house Plakoto, 1-ply).

## Decisions (user, 2026-11-18)

| Topic | Decision |
|---|---|
| Audience | **Both:** two players on one device, and vs Computer in either direction |
| Approach | **Two tiers:** tier 1 without retraining (head start, moves first, weighted dice, rerolls, hints) ships first; tier 2 (overshoot bear-off, safe point, more/fewer checkers, smaller home) after one combined retraining. See §3 |
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

## 3. Handicap catalogue (round 2, user review 2026-11-18)

The user reviewed every candidate. The catalogue splits into two tiers. **Tier 1** needs no
retraining and ships first. **Tier 2** needs a handicap-aware net, so it waits for one combined
retraining (E3).

### Tier 1: no retraining

| Lever | How it works | Control | Estimate source | Notes |
|---|---|---|---|---|
| **Head start** | m checkers of the favoured side start further ahead (6 or 12 pips, E1 decides) | Slider | Net + measured | Phase 1: up to 7.2 pp at m=4; E1 extends the range |
| **Moves first** | The favoured side always rolls first | Toggle | Measured (2.8 pp) | |
| **Weighted dice** *(user idea)* | Before each roll, the net rates all 21 rolls for the favoured side by the value of its best move. Each roll's probability is tilted by `exp(β · value)` and renormalised. β = 0 means fair dice | Slider (β) | Measured curve | Continuous, so it's the finest knob. It adapts to the position: in an exact-die bear-off a *low* roll can be the good one. No rules change, any variant. The AI plans as if the dice were fair, so it's slightly off under tilt; the measurement absorbs that. **Disclosed via the in-game Handicap tag** ("Dice favour White slightly"), never per roll |
| **Rerolls** | The favoured side may reroll N times per game, choosing when | Slider 0…N | Measured | AI policy for self-play: reroll when the rolled position's value is below the expected value of a fresh roll by more than a threshold. Simple and close to what a human would do |
| **Hints** | The favoured side may ask for the best move N times per game | Slider 0…N | **Rough** (simulated with a weaker AI level getting N best moves), labelled "approx." | Value depends on the human; it also teaches |

### Tier 2: needs a handicap-aware net (one combined retraining)

| Lever | How it works | Why retraining |
|---|---|---|
| **Overshoot bear-off** | The favoured side may bear off with a higher die (standard-Plakoto rule); the other side keeps exact-die | The net must know which bear-off rule each side has; a per-side flag in the encoder |
| **Safe point** | One point where the favoured side's single checkers can't be pinned | Per-side safe-point feature in the encoder |
| **More / fewer checkers** *(user idea)* | Favoured side plays with fewer, the other with more (e.g. 13…17) | Fewer behaved oddly in phase 1 (off-distribution). More than 15 exceeds the encoder's per-point capacity, so the input format grows |
| **Smaller home** | The other side may only bear off from its last 5/4/3 points | Per-side home-size feature; the bear-off DB assumes 6 |

### Rejected by the user

Joker die (choose a die's value), mother protection, bonus third die, match head start (Best of 3
lead / double wins), takebacks, pin release after N turns, move clock, pip-count/threat assist.
Also the phase-1 inverted dice levers (dice ceiling/floor, forced low roll, skipped turns,
no doubles).

## 4. The handicap builder (UI model)

A list of handicap items, each a **toggle** or a **slider** and each assigned to a side. Tier 1
first; tier-2 rows appear once their retraining lands. Below the list, one live line:

> **Estimated win chance: White 61 % · Red 39 %**
> *if both played at the computer's full strength*

"Optimal play" can't be computed for Plakoto. The closest honest proxy is the full-strength
computer playing both sides, and the footnote says so. Levers with a rough estimate (hints) mark
the line "approx.".

## 5. The win-chance estimator

The estimate must work for *any combination* of items, so a fixed ladder won't do.

1. **Position levers** (head start, moves first): average the net's evaluation of the start
   position over the opening rolls. It's instant and on-device, and valid if E1 shows it lands
   within **≤ 2 pp** of measured self-play.
2. **Dice/tempo levers** (weighted dice, rerolls): a static evaluation can't see them. Measure
   each lever's curve with the paired duplicate-dice harness. Weighted dice and rerolls are
   played out with the same uniforms, so luck still cancels within a pair.
3. **Combining:** phase 1 found levers roughly additive. Model each lever as a shift in
   log-odds and add them. E1 measures a set of combinations to check the additive model, and
   keeps measured cells where it's off by more than 2 pp. The model ships as a small JSON table;
   no runtime search.

## 6. Plan and gates

| # | Step | Kind | Gate / output | Est. cost |
|---|---|---|---|---|
| **E1** | Tier-1 sweep at full strength, 1 000 pairs/cell: head start m = 0…8 (6 and 12 pips) ± moves first; weighted dice β grid; rerolls N = 1…4; ~15 combinations. Record the net's start-position estimate next to each measured result | Experiment, no training | Range: tier 1 together reaches ≳ 25 pp, each lever monotone. Net estimate within 2 pp. Additive model within 2 pp | ~4–6 h CPU |
| **E2** | *Only if the net misjudges head-start positions:* short fine-tune with ~30 % head-start starts, same shape | Training | No regression vs gold_v11 (paired non-inferiority); estimate error ≤ 2 pp | ~½ day |
| **P3a** | Ship tier 1: final table + estimator; iOS builder (§7) | Measurement + implementation | Tests; UI review on device | ~3 h CPU + 1–2 PRs |
| **E3** | Tier 2, one combined retraining: per-side features for bear-off rule, safe point, home size, checker count (widened net, zero-initialised new inputs, so it starts identical to gold_v11). Self-play mix ~50 % normal / ~50 % random tier-2 setups | Training | No regression in normal games vs gold_v11. Each tier-2 lever monotone and measurable | 2–3 days training |
| **P3b** | Ship tier 2: rules in the Swift engine, Core ML model with the new input size, board cues (safe point, shortened home), estimator extended | Measurement + implementation | Same gates | 1–2 PRs |
| Docs | `domain/`, `ai/`, iOS `REFERENCE.md` + this doc | Docs | — | with each PR |

Experiments and training wait until the Fevga run (#141) is done (CPU).

## 7. In the app

**Principle: if you don't use handicaps, nothing changes.** No new rows in the new-game sheet,
no new labels in the game, no new sections in the statistics.

- **Settings → Handicap** (one row, last section, "Off" by default). It opens the builder (§4)
  with the live estimate. The sides are shown as "You / Computer" or "White / Red" depending on
  the mode of the next game. Turning it on applies to new house-Plakoto games until it's turned
  off; other variants ignore it, and the builder says so.
- **During a handicap game:** a small "Handicap" tag in the top bar (only then); tapping it shows
  the setup and the estimate.
- **Engine (tier 1):**
  - Builds the head-start position and skips the opening roll-off for "moves first".
  - Draws weighted dice through the net: it rates the 21 rolls, tilts the probabilities, then
    draws.
  - Offers a "Reroll (n left)" button after a roll, and a "Hint (n left)" button that highlights
    the best move.
  - Review, drill and analysis evaluate ordinary positions and keep working. Their win chances
    still assume fair dice; the review notes that for weighted-dice games.
- **Statistics:** handicap games are stored with their setup and kept out of the vs-Computer
  record. A separate "Handicap games" block appears **only once at least one exists**.
- **Not offered:** online games and Full Tavli/matches (the builder notes this).

## 8. Open points that need no decision now

- Exact wording of the head-start item, and the slider maximum (depends on E1).
- Whether "Head start" uses 6- or 12-pip advances, or both (E1).
- Whether the estimate is computed on-device from the net or looked up (E1 decides; same UI either way).
