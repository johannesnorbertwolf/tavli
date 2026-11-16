# Handicap system — phase 1 results (#148)

Gold self-play (`models/gold_v11.pth` vs itself, house-rule `plakoto`, 1-ply) with a handicap on
one side. Harness: `python main.py handicap-sweep` (`ai/handicap_sweep.py`, rules layer
`domain/handicap.py`). Raw numbers: `docs/handicap-phase1.json`.

**Method.** Each seed plays two games on the same duplicate dice stream: handicapped side White
(moves first), then handicapped side Black (moves second). Dice are uniforms mapped through each
side's die, so a modified die stays aligned with the fair stream. First-move edge and dice luck
cancel within a pair. The 95% CI comes from the per-pair standard error. All cells use the same
seeds. With no handicap the two games of a pair are identical, so the baseline is exactly 50%.
The first-move edge, measured from the baseline's game A, is 53.3%. Singles: 600 games
(300 pairs) per cell. Combos: 400 games. The bear-off DB is on, except for geometry cells, where
its 6-point-home race values would be wrong. Total compute was about 30 min on 2 workers.

**Reading the table.** *handicapped side* = the side meant to be weakened (the "stronger
player"). Penalty kinds change that side. Bonus kinds (`dice_floor`, `pre_borne`,
`pip_headstart`, `larger_house`) change its opponent. A **positive shift means the "handicap"
actually helps the side it was put on.**

| handicap | handicapped-side win % [95% CI] | shift (pp) | games | mean plies | pin wins | net reliability |
|---|---|---|---|---|---|---|
| `smaller_house:3 + pip_headstart:4` | 22.0 [18.2, 25.8] | -28.0 | 400 | 109 | 8% | position/geometry off-distribution; DB off |
| `smaller_house:3` | 27.3 [24.5, 30.2] | -22.7 | 600 | 113 | 7% | position/geometry off-distribution; DB off |
| `smaller_house:4 + pip_headstart:2` | 30.2 [26.0, 34.5] | -19.8 | 400 | 108 | 6% | position/geometry off-distribution; DB off |
| `smaller_house:5 + pip_headstart:2` | 37.2 [32.9, 41.6] | -12.8 | 400 | 106 | 6% | position/geometry off-distribution; DB off |
| `smaller_house:4` | 38.3 [35.9, 40.8] | -11.7 | 600 | 110 | 7% | position/geometry off-distribution; DB off |
| `smaller_house:4 + first_mover:1` | 40.0 [33.2, 46.8] | -10.0 | 400 | 109 | 7% | position/geometry off-distribution; DB off |
| `pip_headstart:2 + first_mover:1` | 41.2 [34.6, 47.9] | -8.8 | 400 | 105 | 10% | position/geometry off-distribution |
| `pip_headstart:4` | 42.8 [39.0, 46.6] | -7.2 | 600 | 103 | 7% | position/geometry off-distribution |
| `smaller_house:5 + first_mover:1` | 43.2 [36.4, 50.1] | -6.8 | 400 | 107 | 8% | position/geometry off-distribution; DB off |
| `smaller_house:5` | 44.5 [42.7, 46.3] | -5.5 | 600 | 108 | 7% | position/geometry off-distribution; DB off |
| `pip_headstart:2` | 45.3 [41.6, 49.1] | -4.7 | 600 | 105 | 6% | position/geometry off-distribution |
| `first_mover:1` | 47.2 [41.5, 52.8] | -2.8 | 600 | 106 | 7% | dice/tempo only (net assumes fair dice ahead) |
| `larger_house:9` | 47.5 [46.1, 48.9] | -2.5 | 600 | 105 | 7% | position/geometry off-distribution; DB off |
| `no_doubles:0.5` | 48.0 [44.6, 51.4] | -2.0 | 600 | 107 | 9% | dice/tempo only (net assumes fair dice ahead) |
| `pip_headstart:1` | 48.5 [44.8, 52.2] | -1.5 | 600 | 106 | 6% | position/geometry off-distribution |
| `larger_house:7` | 49.5 [48.8, 50.2] | -0.5 | 600 | 106 | 7% | position/geometry off-distribution; DB off |
| `baseline` | 50.0 [50.0, 50.0] | +0.0 | 600 | 106 | 7% | reference |
| `no_doubles:1` | 52.3 [48.6, 56.1] | +2.3 | 600 | 111 | 6% | dice/tempo only (net assumes fair dice ahead) |
| `pass_turns:1` | 52.7 [50.2, 55.1] | +2.7 | 600 | 108 | 5% | dice/tempo only (net assumes fair dice ahead) |
| `pass_turns:2` | 54.8 [51.9, 57.8] | +4.8 | 600 | 107 | 6% | dice/tempo only (net assumes fair dice ahead) |
| `dice_ceiling:3` | 55.2 [51.4, 58.9] | +5.2 | 600 | 126 | 0% | dice/tempo only (net assumes fair dice ahead) |
| `pass_turns:4` | 57.2 [53.7, 60.6] | +7.2 | 600 | 110 | 4% | dice/tempo only (net assumes fair dice ahead) |
| `dice_ceiling:5` | 57.8 [53.9, 61.8] | +7.8 | 600 | 109 | 3% | dice/tempo only (net assumes fair dice ahead) |
| `pass_turns:8` | 58.0 [54.3, 61.7] | +8.0 | 600 | 114 | 6% | dice/tempo only (net assumes fair dice ahead) |
| `forced_low:0.25` | 59.3 [55.5, 63.1] | +9.3 | 600 | 109 | 4% | dice/tempo only (net assumes fair dice ahead) |
| `dice_ceiling:4` | 63.0 [59.2, 66.8] | +13.0 | 600 | 115 | 3% | dice/tempo only (net assumes fair dice ahead) |
| `forced_low:1` | 63.3 [59.4, 67.2] | +13.3 | 600 | 140 | 2% | dice/tempo only (net assumes fair dice ahead) |
| `pre_borne:1` | 65.7 [62.2, 69.1] | +15.7 | 600 | 106 | 6% | position/geometry off-distribution |
| `forced_low:0.5` | 69.0 [65.5, 72.5] | +19.0 | 600 | 116 | 3% | dice/tempo only (net assumes fair dice ahead) |
| `pre_borne:2` | 74.0 [70.6, 77.4] | +24.0 | 600 | 104 | 5% | position/geometry off-distribution |
| `pre_borne:5` | 75.0 [71.6, 78.4] | +25.0 | 600 | 100 | 6% | position/geometry off-distribution |
| `pre_borne:3` | 80.7 [77.6, 83.8] | +30.7 | 600 | 102 | 6% | position/geometry off-distribution |
| `dice_floor:3` | 91.2 [89.1, 93.2] | +41.2 | 600 | 179 | 8% | dice/tempo only (net assumes fair dice ahead) |
| `dice_floor:2` | 94.5 [92.6, 96.4] | +44.5 | 600 | 111 | 5% | dice/tempo only (net assumes fair dice ahead) |

*Net reliability*: "dice/tempo only" means the positions are ones the gold net knows, but it
evaluates them as if both sides keep rolling fair dice with no skipped turns. "Off-distribution"
means the start position, or a bear-off rule the encoder cannot see, never occurred in training.
Its numbers say as much about how the net misplays as about the handicap itself.

## Analysis

**The headline: in house Plakoto, low dice are not a handicap.** Bear-off needs the exact die
(`domain/move_generation.py`: a checker on distance *d* leaves only with a *d*). A side rolling
5s and 6s in the bear-off can't use them. It is forced to move checkers deeper and piles them on
the last point. Then it stalls on rolls without a 1: one inspected `dice_ceiling:1` game ended
with the fair side passing 40 times holding 9 checkers on its 1-point. Smaller dice cost a little
in the running game and win much more in the bear-off. So `dice_ceiling`, `forced_low` and even
`pass_turns` (fewer moves, so less forced wreckage of the position) *help* the side that gets
them. `dice_floor` (no 1s, or no 1s and 2s) is catastrophic: checkers on the last point(s) can
never bear off. It is **binary, discard.** `no_doubles` is a wash (−2 to +2 pp, inside noise),
**too weak.**

These dice/tempo kinds are **inverted levers**: they move the result reliably, but towards the
side that receives them. As a rule of the house game they read as nonsense to a player ("you
win more by skipping turns"). They would also flip sign under an overshoot bear-off rule (as in
`plakoto_standard`). Keep them out of the player-facing catalogue for house Plakoto.

**`pre_borne` is also inverted.** Removing 1–5 of the weaker side's checkers *hurts* it
(+16 to +31 pp for the opponent) and is not monotone (3 > 5). Likely causes, all
off-distribution: the net misjudges positions where checkers are borne off from move 1. A
thinner start stack also leaves the start point open to the instant start-pin loss sooner. The
favoured side still faces the exact-die bear-off tail. **Not usable without retraining.** Phase 2
could re-test it, but its non-monotone shape makes it a poor calibration lever. Fewer checkers
was not run separately, because mechanically it is the same game as `pre_borne` (see below).

**Usable, correctly-signed levers:**

| lever | range seen | shape | verdict |
|---|---|---|---|
| `smaller_house` (strong side bears off from an h-point home) | h=5: −5.5, h=4: −11.7, h=3: −22.7 pp | monotone, ~accelerating, tight CIs (geometry barely changes play until the bear-off) | **best single lever**, reaches 27% |
| `pip_headstart` (m weak-side checkers start 6 pips ahead) | m=1: −1.5, m=2: −4.7, m=4: −7.2 pp | monotone, small | fine-tuning lever |
| `first_mover` (strong side always moves second) | −2.8 pp | binary, = the first-move edge | fine step, not a range |
| `larger_house` (weak side bears off from 7–9 points) | h=7: −0.5, h=9: −2.5 pp | monotone but tiny (exact-die bear-off from 7+ needs a combined roll) | **too weak** |

**Combinations are roughly additive and orthogonal.** `smaller_house:4 + pip_headstart:2` is
−19.8 pp (sum of singles −16.4). `smaller_house:3 + pip_headstart:4` is −28.0 (sum −29.9).
`pip_headstart:2 + first_mover` is −8.8 (sum −7.5). `smaller_house:4 + first_mover` is −10.0
(sum −14.5; wide CI, since `first_mover` pairs carry no luck cancellation). Together, house size ×
headstart × first move cover the handicapped side's win rate from 50% down to ~22% in steps of
2–8 pp. That is the 50/50 to 78/22 band of the target range. Nothing found pushes the
*strong* side below ~20%. The 20–80% band is symmetric (the weak side's rate is 100 − the
table's value), so the levers cover up to ~78% for the weaker player.

## Recommendation for phase 2 (encoder + retraining) and phase 3 (calibration)

Carry these four into phase 2:

1. **`smaller_house` h ∈ {5, 4, 3}**, on the stronger side. Main lever, smooth, −5 to −23 pp.
   Encoder: per side, a home-size feature (one-hot or (6−h)/3). The current encoder's
   home-board smart features and the bear-off DB are hard-wired to 6, so both need the per-side
   value. Player-facing wording: "Your opponent must bring all checkers into their last *h*
   points before bearing off." The iOS board can shade the shortened home.
2. **`pip_headstart` m ∈ {1, 2, 4}**, for the weaker side. Fine lever, −1.5 to −7 pp. Encoder
   needs nothing new, since it is just a start position (but self-play must start from it).
   "You start with *m* checkers already advanced 6 points."
3. **`first_mover`**. A −3 pp step with zero rules complexity. Encoder: nothing (whoever is on
   roll is encoded). "You always roll first."
4. **Combination `smaller_house × pip_headstart (× first_mover)`** as the calibration grid.
   About 3×3×2 = 18 cells span 50%→~22%, dense enough to hit 50/60/70/80 targets
   within ±3 pp.

Dice handicaps (`dice_ceiling`, `forced_low`, `pass_turns`, `no_doubles`, `dice_floor`) and
`pre_borne` / `larger_house` should **not** go into phase 2 for house Plakoto. If a
dice-type lever is wanted for the player, the measured sign suggests offering
"`forced_low` for the *weaker* player" (+9 to +19 pp for the receiver at p = 0.25–0.5). It is
smooth up to p=0.5 but non-monotone beyond, and counter-intuitive to present. Revisit only
after retraining and with a rules change to overshoot bear-off.

Caveats: smaller house is off-distribution for gold_v11, since the encoder cannot see the
shrunken home. The strong side's net is therefore unaware of its own constraint, and phase-2
retraining may make the handicap *weaker* than measured here (the net will learn to keep
checkers deep). Phase 3 must recalibrate on the retrained net. The 1-ply strength and the
exact-die bear-off pathology also shape every number here.

## Not implemented

- **Fewer checkers.** In this engine a side wins when all its remaining checkers are off, so
  "starts with 15−k checkers" is the same game as `pre_borne:k` on that side; only the encoding
  differs. Removing checkers *helps* the side that loses them in race terms, so as a handicap for
  the stronger player it would be `pre_borne` for the weaker one, which is measured above.
- **Stacked start.** House Plakoto already starts all 15 checkers on one point, so this is the
  identity.
- **Shifted-back start for the stronger side.** The start point is already the farthest-back
  point. The inverse, a headstart for the weaker side, is `pip_headstart`.
