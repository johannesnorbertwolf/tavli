# Handicap system: concept for phases 2–4 (#148)

Status: **concept, decisions taken 2026-11-18. Tier 1 (§9, E1 §10) and tier 2 (E3 §11, iOS §12)
implemented in the iOS app and the Python harness.** Builds on the
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

**E1 harness support (2026-11-18).** `python main.py handicap-sweep` now has the tier-1 dice kinds
`weighted_dice:β` and `rerolls:N` (both on the same duplicate-dice uniforms as fair play, so β = 0 is
the fair game exactly), combinations with any other kind (`weighted_dice:2+rerolls:1+first_mover`),
and a *net est.* column: the net's start-position estimate for position-only cells (baseline, moves
first, head start). `scripts/run_e1_tier1.sh` runs the E1 grid (1-ply, 1 000 pairs/cell; ~6 CPU-hours,
≈1–1.5 h on 6 workers) into `docs/handicap-e1-tier1.{json,md}`. Head start uses 6-pip advances only;
the 12-pip variant is not implemented yet. Design and alignment: `ai/REFERENCE.md` (handicap_sweep).

**E3 pipeline (2026-11-18, code only; no training run yet).** One handicap-aware model, variant
`plakoto_hc` (`config/config-handicap.yml`). Exactly two models exist: gold_v11 (unchanged) and this one.
- **Rules** live on `HandicapBoard` (domain/handicap.py): `overshoot:1` and `safe_point:p` for the
  favoured side, `checkers:n` (13/14 favoured, 16/17 the other side), `smaller_house:k` for the other
  side; overshoot bear-off via `domain/handicap_moves.py` (standard-Plakoto rule: higher die only from the
  farthest occupied point, own pinned checkers count). Safe-point candidates 2/4/6/8/10/12 (favoured
  side's numbering): the opponent's home and the near outer board, where its runners get pinned; point 1
  would be the rejected mother protection.
- **Encoder** `unary_v3_hc1` (606 inputs) = unary_v3 unchanged + overflow units for 16/17-checker stacks
  + 2×34 per-side handicap features, all zero in a normal game. **Warm start** = gold_v11 with zero
  columns for the new inputs (`main.py handicap-init`): identical values on normal positions
  (max |Δ| 1.2e-7, float rounding).
- **Bear-off DB** stays on, gated per position (`HandicapBoard.bearoff_exact`): exact for smaller homes and
  fewer checkers, off for overshoot and > 15 checkers.
- **Self-play mix:** 70 % of games one random side gets a random tier-2 combination (each lever on
  independently: overshoot 0.5, safe point 0.5, checkers 0.4, smaller home 0.4; ≥ 1 lever, ≈ 2 levers per
  handicapped game on average), the other side none; 30 % normal games.
- **Promotion** (plateau driver, handicap mode): (b) paired eval vs the previous rung on random tier-2
  setups (z ≥ 2, ≥ 52 %), and (a) before every promotion a paired eval vs gold_v11 on normal games whose
  one-sided 95 % lower bound must be ≥ 49 %. Stages: depth-1 bootstrap (50k-game rounds), then depth 2
  (20k-game rounds), the gold_v11 setting.
- **Launch:** `.venv/bin/python main.py --config config/config-handicap.yml plateau` (resumable;
  `plateau-status`). Measurement: `main.py --config config/config-handicap.yml handicap-sweep --tier2
  --model models/plakoto_hc_gold_vK.pth`; app table `ios/scripts/make_handicap_table.py ... --tier2 <json>`
  (same additive log-odds model). The Swift engine/encoder must port the same rules and layout (P3b).

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

## 9. Implementation notes: iOS tier 1 (#148)

Engine detail: `ios/REFERENCE.md` ("Handicaps, tier 1"); views: `ios/TavliApp/TavliApp/Views/REFERENCE.md`
("Handicap views").

- **Data.** `HandicapSetup` (versioned, per side: head start 0…8, moves first, weighted-dice β,
  rerolls 0…4, hints 0…5) is stored with the game as the optional `GameSave.handicap` (setup +
  tokens left). No schema bump: an old build ignores the key and loads the game unhandicapped; a
  normal game's save is unchanged. Finished handicap games go to the stats log with their setup and
  are kept out of the vs-Computer record.
- **Head start** reproduces `pip_headstart` (6 pips; White 1 → 7, Black 24 → 18), pinned against
  Python-generated boards. 12-pip advances are not offered (E1 decides).
- **Weighted dice** follow the harness exactly: 1-ply roll values (pass = 1 − opponent's static
  value), `p' ∝ p·exp(β·v)`, `weighted_faces` inverse-CDF draw; β = 0 is the fair die. App steps
  Off / Slight / Moderate / Strong / Very strong = β 0 / 2 / 4 / 8 / 16, in one place
  (`HandicapSetup.diceTiltSteps`) so they can be retuned after E1. The tilt is disclosed only in the
  Handicap tag ("Dice favour Red moderately"), never per roll.
- **Rerolls.** Human: a "Reroll (n left)" button while picking (built half-moves are taken back).
  Computer: the harness rule — reroll while tokens remain and v(roll) < E_p[v] − 0.02 with p its own
  (tilted) distribution; the human sees "Computer used a reroll (n left)". A human reroll tumbles
  the dice like a normal roll; a computer roll restored from a save gets the same reroll decision;
  undoing a move across a reroll replays the same (rerolled) dice, without refunding tokens. Not
  offered on a roll with no legal move (the turn passes at once) — a known limitation, kept.
- **Hints**: the level-8 search (2-ply) shown as a blue move highlight, not played; charged when
  shown. Human sides only.
- **Estimate.** Position levers on device from the net (the starter's mean 1-ply value over its 21
  rolls from the handicap start; the roll-off averages both starters, matching the app's opening
  roll; "moves first" or a forced first move fixes the starter). Dice levers from the bundled
  `HandicapTable.json` (keyed like the E1 cells, `weighted_dice:4`, `rerolls:2`, `+` combos;
  regenerate with `ios/scripts/make_handicap_table.py`), combined by adding log-odds. Until E1
  lands every dice cell is `null`: the line shows the position estimate plus "Weighted dice and
  rerolls: not measured yet". Hints mark it "approx." and are left out.
- **Where it applies.** House Plakoto, offline, vs the computer or two players: a single game or
  every game of a Best of 3 (each game with fresh rerolls/hints; "moves first" gives the favoured
  side the start of every game, overriding the alternation). Full Tavli and online never. Every game
  of a handicap match counts in the separate handicap record.
- **Open.** E1 numbers for the table; whether head-start positions need the E2 fine-tune; the
  Swift side has no bear-off database, so its race values (dice tilt, reroll decisions, estimate)
  are the net's own rather than the DB's exact ones.


## 10. E1 results: tier-1 calibration (2026-11-18)

Full table: `docs/handicap-e1-tier1.md` / `.json` (gold_v11, 1-ply, 1 000 duplicate-dice pairs per
cell). Gains are percentage points for the favoured side.

| Lever | Steps → gain |
|---|---|
| Moves first | +3.0 |
| Head start (m checkers) | 1: +2.1 · 2: +4.1 · 4: +8.0 · 6: +9.2 · 8: +7.6 (saturates, so the app caps at 4) |
| Weighted dice β | 0.3: +3.7 · 0.6: +6.2 · 1.2: +13.6 · 2.0: +22.0 (the app's steps) |
| Rerolls | 1: +4.9 · 2: +8.0 · 3: +11.4 · 4: +14.7 |

**Analytic check.**
- Win probability is a martingale under fair play, so weighted dice shift it by
  ΣE_tilt[v] − E_fair[v] over the favoured turns, ≈ β·Σ Var(v) for small β.
- From 400 fair games: β 0.25/0.5/1 → +3.2/+6.6/+13.5 pp.
- This matches the measurement for β ≤ 0.6, and overestimates beyond that as the effect
  saturates.

**Net start-position estimate.** Within ≈ 1 pp for head start ≤ 4 (incl. moves first). It is
3–5 pp off at m = 6–8, which is why the cap is 4.

**Additivity in log-odds.**
- Holds for dice-only combos (within ≈ 1 pp).
- Head start × dice levers is super-additive: the dice shift counts ≈ 1.4× at m = 4. The app
  multiplies the dice shift by 1 + 0.1·m (`HandicapEstimator.headStartDiceInteraction`).
- Moves-first combos are within noise (±3 pp CI).

## 11. E3 results: the handicap-aware model and tier-2 measurement (2026-11-19)

**Training** (`docs/handicap-e3-training.log`). The plateau driver ran both stages: depth-1
(4 rounds × 50k games) and depth-2 (4 rounds × 20k games), 280k self-play games, 70 % with random
tier-2 setups. The net did learn the new inputs (mean |w| on the 68 handicap columns 0.20, on the old
inputs 1.27), but **no candidate ever beat the warm start** on handicapped pairs: depth-1 dropped to
−5 pp and recovered to −1 pp; depth-2 ended at exactly 50.0 % (pooled −0.9 pp, 8 000 pairs). The ladder
top is still `plakoto_hc_gold_v1` = gold_v11 with zero-initialised new inputs. On normal games it is
gold_v11 (50.0 % over 4 000 games).

**Consequence.** The handicap-aware model *is* gold_v11 with a wider input that it ignores. gold_v11
already plays the tier-2 rules as well as anything 280k games of retraining produced, because the rules
reach it through the legal moves, not through the encoding. So the app needs **no second model**: the
regular Core ML model plays tier-2 games, with the encoder capping a stack's unary units at 15 (stacks of
16/17 only occur with extra checkers). This is the user's "one regular + one handicap model" policy with
the second model collapsed into the first. If a future idea makes retraining pay off, the pipeline
(`config/config-handicap.yml`, `plateau`) is ready.

**Measurement** (`docs/handicap-e3-tier2.{json,md}`; `plakoto_hc_gold_v1`, 1-ply, 1 000 pairs/cell).
Shift = change in the *handicapped* (spec `side`) colour's win rate:

| Lever | Shift for the handicapped side (pp) |
|---|---|
| Overshoot bear-off for the opponent | −25.5 |
| Smaller home 5 / 4 / 3 | −7.3 / −13.2 / −24.2 |
| Safe point for the opponent at 2 / 4 / 6 / 8 / 10 / 12 | −1.0 / −2.2 / −3.3 / −2.3 / −2.5 / −2.3 |
| Opponent plays with 13 / 14 checkers | **+21.5 / +12.6** |
| Handicapped side plays with 16 / 17 checkers | **+11.6 / +16.8** |

- **More checkers is the advantage**, not fewer: the design assumption (§3, "favoured side plays with
  fewer") is backwards in house Plakoto. 15 vs 13 is worth +21.5 pp for the 15 side. Extra checkers mean
  more blockers and more pinning material, which outweighs the longer bear-off. The app offers a per-side
  checker count (13…17); the estimator uses the measured sign.
- **Safe point is weak** (≤ 3.3 pp; best at point 6). Kept as a fine knob.
- **Overshoot** is a single strong step (≈ 25 pp); smaller home is a 3-step slider up to ≈ 24 pp.
- **Combinations are super-additive** in log-odds: pairs are within 0.3–6 pp of the additive model,
  three/four levers 9 pp stronger (e.g. overshoot + safe point 6 + 14 checkers: measured 23.1 %, additive
  32.3 %). The app uses the exact measured combo cell when one exists, else the additive sum.
- The net's start-position estimate is useless for tier 2 (≈ 50 % everywhere: the new inputs are zero
  weights), so tier-2 levers come only from the table.

`ios/TavliApp/TavliApp/Resources/HandicapTable.json` now carries the 22 tier-2 cells too
(`make_handicap_table.py ... --tier2 docs/handicap-e3-tier2.json`); the Swift reader uses them since the
P3b port (§12).

## 12. Implementation notes: iOS tier 2 (P3b, 2026-11-19)

Engine detail: `ios/REFERENCE.md` ("Handicaps, tier 2"); views: `ios/TavliApp/TavliApp/Views/REFERENCE.md`
("Handicap views").

- **One model.** Per §11 the regular `PlakotoValue` net plays tier-2 games; the Swift encoder caps a
  stack's unary units at 15. No `plakoto_hc` Core ML model ships.
- **Rules.** `HandicapItems` (setup version 2) adds per side overshoot, safe point (2/4/6/8/10/12),
  checkers (13…17) and home size (6/5/4/3), each the side's own rules. They ride on
  `GameConfig.handicapRules`, so every board copy (search, hints, review, drill, move builder) plays
  them. The move generator ports `legal_moves_tier2` and is pinned to Python on 1 041 positions
  (`ios/scripts/make_tier2_fixtures.py`). With no tier-2 item the config and the move generator are
  exactly the old ones.
- **Builder.** A "Rule changes" group: Overshoot bear-off and Safe point and Home size with a side
  picker, Checkers as a neutral count per side (more checkers is the advantage, so no "favoured" side).
- **Estimate.** The net estimates the normal 15/15 start with the head start only; tier-2 levers come
  from the E3 cells, grouped by the handicapped colour, exact combo cell in any order when measured,
  else the singles summed in log-odds, then added to tier 1 in logit.
- **Board cues.** A small shield in the side's colour on the frame at its safe point; for a smaller
  home the points that no longer count are dimmed and a line in the side's colour marks the counting
  home. Light and dark palettes.
- **Where it applies.** As tier 1: house Plakoto, offline, single game or every game of a Best of 3,
  vs the computer or two players; never online or Full Tavli. Saves, resume and review replay carry
  the rules through the setup.
- **Open.** No Swift bear-off database (race values are the net's). A version-1 build reading a
  tier-2 save ignores the rules and would replay it as a normal game.
