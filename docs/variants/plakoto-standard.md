# Standard Plakoto — rules spec and diff vs. the current engine

Implementation spec for `StandardPlakotoRules` (issue #139). Items marked **DECISION** were
reviewed and **approved as recommended**; the Python implementation
(`domain/plakoto_standard_*.py`, variant `plakoto_standard`) follows them.

## Bottom line

The current engine (`rules.md`, `domain/`) is **not** standard Plakoto. It differs in
**move legality** (bear-off with a larger die, must-use-both-dice, play-the-larger-die),
in **end-of-game** (mother-checker exception, draw), and in **scoring** (single vs double
win). Because legal-move sets differ and the value target changes from P(win) to
expected points, `plakoto_standard` needs its **own network** (and its own bear-off DB:
the current `ai/bearoff.py` DB encodes exact-only bear-off).

## Sources

- [B] bkgm.com, Plakoto: https://www.bkgm.com/variants/Plakoto.html
- [T] bkgm.com, Tavli overview (scoring, who starts): https://www.bkgm.com/variants/Tavli.html
- [W] Wikipedia, Plakoto: https://en.wikipedia.org/wiki/Plakoto
- [GR] Greek Wikipedia, general Tavli rules: https://el.wikipedia.org/wiki/Κανόνες_του_ταβλιού
- [GP] Greek Wikipedia, Plakoto: https://el.wikipedia.org/wiki/Πλακωτό

## Coordinates (unchanged from the current engine)

Slots 1..24 are points. `WHITE=+1`, `BLACK=-1`, a half-move is `dst = src + color*die`.
Slot 25 = White's off slot, slot 0 = Black's off slot. White home = 19–24, Black home = 1–6.
"Distance to off" of a White checker at `s` is `25-s`; of a Black checker it is `s`.

## Rules

1. **Setup.** White 15 on slot 1, Black 15 on slot 24 (each starts on the opponent's
   ace point) [B][W]. White moves 1→24, Black 24→1.
2. **Opening.** Each side rolls one die, higher starts and then rolls both dice afresh
   (doubles allowed as first roll); in a match the previous game's winner starts [B][T].
   [GR] lists an alternative where the two single dice are the first roll. **DECISION:**
   for a single game the engine just picks the starter uniformly at random and rolls two
   dice — distributionally identical to the bkgm convention. (Current engine: Black always
   starts in self-play, White in eval.)
3. **Landing.** Legal on: empty point, own point (including own point with a pinned
   opponent under it), a single unpinned opponent checker (→ pin). Illegal on: 2+ opponent
   checkers, or any point where the opponent is the owner of a pin [B][W]. Unchanged.
4. **Pinning.** A pinned checker cannot move until all of the pinner's checkers leave the
   point; then it is a normal blot again [B][W][GP]. Unchanged.
5. **Combined move.** One checker may use both dice if at least one intermediate point
   is landable [B]. Touching a blot at the intermediate point pins it only transiently; it
   is free again when the checker moves on. Unchanged (keep the repo's merged single-half
   `Move((HalfMove(src, src+color*(d1+d2)),))` notation; it is unambiguous in Plakoto).
6. **Doubles** are played four times [B][W].
7. **Dice obligation.** Let `M` = the largest number of dice usable by any play sequence.
   Only sequences that use `M` dice are legal ("use both numbers if possible, or all four
   on doubles" [B][W]). If `M = 1` on a non-double and either die alone could be played,
   only plays of the **larger** die are legal [GR]. **DECISION:** [B]/[W] are silent on the
   larger-die rule, [GR] states it for all Tavli games and bkgm states it for Fevga;
   recommend enforcing it.
8. **Bearing off** only when all 15 own checkers are in the home board; a checker pinned
   outside home blocks bearing off [GR][GP]. A die equal to a checker's distance bears it
   off. A die larger than the distance may bear off a checker only from the **highest
   occupied point** (no own checker farther from off); otherwise a larger die must be
   played as a normal move from a farther point [B][W]. Own pinned checkers count as
   occupying their point for this test. Half-move notation: `(src, 25)` / `(src, 0)` even
   when the die exceeds the distance.
9. **Pinned own checker inside home. DECISION.** [GP] says you may not bear off while any
   own checker is pinned (even inside home); [B][W] only require "all fifteen in home".
   Recommend the bkgm reading (a pinned checker in home does not stop bearing off), which
   is also the current engine's behaviour.
10. **Mother checker.** The mother is a player's last checker still on its starting slot
   (White: slot 1, Black: slot 24). `mother_pinned(X)` ⇔ X's start slot is owned by `-X`
   with X pinned under it. Evaluate after every complete move (all halves applied):
   - both mothers pinned → **draw, 0 points** [B][W][GR];
   - else if `mother_pinned(X)` and the pinner `Y=-X` has **no** own checkers on Y's own
     start slot → Y wins, **2 points** [B][W][GP];
   - else if `mother_pinned(X)` but Y still has checkers on Y's start → game continues
     (Y's own mother may still be pinned, which would make it a draw) [B][W]. The game ends
     (2 points to Y) at the end of the first later move after which Y's start is empty
     while X's mother is still pinned [GP].
   - [GP] notes a regional variant where any mother pin ends the game immediately (no
     draw possible). **DECISION:** implement the bkgm rule above.
11. **Win by bear-off.** First to bear off 15 wins **1 point**, or **2 points** if the
   loser has borne off none [B][T]. No triple, no cube.

## DIFF: current engine vs standard

| # | Topic | Current engine | Standard | Source |
|---|---|---|---|---|
| 1 | Larger die bearing off | Exact die only; `_all_halves` never generates `dst` past the off slot | Larger die bears off from the highest occupied point | [B][W] |
| 2 | Must use both dice | `_emit_rule_2` also emits a single-die play whenever *that* first choice blocks the other die, even if another play uses both | Only maximal plays are legal | [B][W] |
| 3 | Only one die playable | Either die may be played | Must play the larger | [GR] |
| 4 | Doubles | Maximal number of halves (verified: shorter sequences only appear when no longer one exists) — but inherits #1 | Same, plus #1 | [B] |
| 5 | Mother pinned, pinner still has checkers on own start | `captured_starting` → immediate win | Game continues | [B][W] |
| 6 | Both mothers pinned | Unreachable (first pin ends game); if constructed, `get_winner` returns WHITE | Draw, 0 points | [B][W][GR] |
| 7 | Scoring | Binary win/loss | 1 point, or 2 for mother-win or opponent with 0 borne off | [B][T] |
| 8 | Who starts | Fixed (Black in self-play, White in eval) | Random/opening roll | [B][T] |

Unchanged: setup, direction, landing/pinning, combined moves, home boards, "all 15 home"
(with pinned-outside counting as outside), pinned-in-home bear-off (per DECISION 9).

## Worked examples (unit-test material)

Unlisted checkers are irrelevant; pad to 15 with immobile checkers as shown. "Current"
sets were produced by running `domain.move_generation.legal_moves` on this commit.

**E1 — larger-die bear-off (legality diff #1).** White 10@23, 5@24; Black 15@3. White
rolls 6-5. Current: `[]` (pass). Standard: `{(23→25, 23→25)}`.

**E2 — must use both dice (diff #2).** White 13@24, 1@5, 1@10; Black 2@9, 2@20, 11@3.
White rolls 6-4. Current: `{(5→11, 10→14), (5→15), (10→16)}`. Standard:
`{(5→11, 10→14), (5→15)}` — `(10→16)` is illegal because a two-die play exists.

**E3 — larger die (diff #3).** White 14@24, 1@10; Black 2@19, 13@3. White rolls 6-3
(10→16 and 10→13 are open, 16→19 and 13→19 blocked, 10→19 blocked). Current:
`{(10→13), (10→16)}`. Standard: `{(10→16)}`.

**E4 — mother exception (result diff #5).** White 3@1, 11@20, 1@24 pinning Black's last
checker on 24 (`set_point(24, WHITE, 1, pinned=True)`); Black 14@5. Current:
`has_won(WHITE) == True`. Standard: game continues. If White later empties slot 1 with
the pin intact → White wins 2 points.

**E5 — both mothers pinned (diff #6).** White 1@1 (mother), 13@20, 1@24 pinning Black's
mother; Black 1@2, 13@5. Black rolls 1-2 and plays `(2→1, 5→3)`, pinning White's mother.
Standard: draw, 0 points. Current: `has_won` true for both colours; `get_winner()` = WHITE.

**E6 — gammon (diff #7).** White bears off its 15th checker while `borne_off[BLACK] == 0`
→ White +2. If `borne_off[BLACK] >= 1` → White +1.

**E7 — mother win when pinner's start is empty.** White 0@1, 14@20, 1@24 pinning Black's
mother; Black 14@4. Position after White's move → White wins 2 points (current: 1 win).

**E8 — no diff: transient pin on combined move.** White 1@10, 14@24; Black 2@11, 1@13,
12@3. White rolls 3-1. Both engines: `{(10→14)}` (via 13; the Black blot on 13 is
unpinned afterwards). The only route is 10→13→14; 10→11 is blocked.

**E9 — pinned own checker in home (DECISION 9).** White 14@23; Black pins a White
checker on 20 (`set_point(20, BLACK, 1, pinned=True)`), Black 14@2. White rolls 2-1.
bkgm reading and current engine: `{(23→25, 23→24)}`. Under the [GP] reading bearing off
is forbidden: `{(23→24)}` only (then the 2 is unplayable).

**E10 — higher-die must move from farther point.** White 1@20, 14@23; Black 15@3. White
rolls 6-5. Standard: `{(20→25, 23→25)}` (5 bears off 20 exactly, then 6 bears off from
the highest point 23; or 6 from 20 as highest point, then 5 from 23). 5 may not bear off
from 23 while 20 is occupied. Current: `{(20→25)}` only (6 has no exact target).
