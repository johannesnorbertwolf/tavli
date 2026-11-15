# Portes — rules spec

Implementation spec for `PortesRules` (issue #137). Portes is Western backgammon without
the doubling cube and without the triple (backgammon) win. Items marked **DECISION** are
open for review; the recommendation is what engineers should implement unless overruled.

## Sources

- [B] bkgm.com, Portes: https://www.bkgm.com/variants/Portes.html
- [T] bkgm.com, Tavli overview (scoring, who starts): https://www.bkgm.com/variants/Tavli.html
- [WT] Wikipedia, Tavli: https://en.wikipedia.org/wiki/Tavli
- [GR] Greek Wikipedia, general Tavli rules: https://el.wikipedia.org/wiki/Κανόνες_του_ταβλιού
- [GPo] Greek Wikipedia, Portes: https://el.wikipedia.org/wiki/Πόρτες_(τάβλι)

## Coordinates

Points are slots 1..24. `WHITE=+1`, `BLACK=-1`; every half-move, including bar entry, is
`dst = src + color*die`. White moves 1→24, home 19–24; Black moves 24→1, home 1–6.

**Bar (DECISION — recommended):** White's bar is **slot 0**, Black's bar is **slot 25**.
- White enters with die `d` at `0 + d` = slot `d` (in Black's home, 1–6).
- Black enters with die `d` at `25 - d` (in White's home, 19–24).
- Off: White bears off to `dst = 25`, Black to `dst = 0`. Borne-off checkers are only
  counted (`borne_off[c]`), **never stored** in `n[0]`/`n[25]`, so slot 0 only ever holds
  White bar checkers and slot 25 only Black bar checkers. `HalfMove(0, d)` is unambiguously
  a White entry, `HalfMove(s, 25)` with `s ≥ 19` a White bear-off (mirror for Black).
- Why: bar entry needs no special case in `dst = src + color*die`, and the pip count of a
  bar checker (25 for either side) falls out naturally. Alternative: a separate
  `bar[c]` counter with entry as a special half-move — rejected (two code paths, and the
  Swift port would diverge from the Python slot layout).
- Note this differs from the Plakoto `Board`, whose `apply_half` writes bear-offs into
  `n[0]/n[25]`; Portes must not.

**Move notation (DECISION — recommended): no merged halves in Portes.** A checker that
uses both dice is written as two halves, e.g. `(10→13, 13→14)`, because whether the
intermediate landing **hits** changes the result (see P4). Legal-move sets are compared
as sets of resulting positions; generators should de-duplicate sequences reaching the
same position (keep one canonical sequence).

## Rules

1. **Setup** (standard backgammon) [B]: White 2@1, 5@12, 3@17, 5@19. Black 2@24, 5@13,
   3@8, 5@6. (Backgammon own-point `p` → White slot `25-p`, Black slot `p`.)
2. **Opening.** Each side rolls one die; higher starts and then rolls both dice afresh, so
   a double may open [B][WT]. Later games in a match: previous winner starts [T].
   **DECISION:** single game → choose starter uniformly at random, roll two dice.
3. **Landing.** Legal on empty, own, or a single opponent checker (a **hit**); illegal on
   2+ opponent checkers [B].
4. **Hit.** The hit checker moves to its owner's bar (White → slot 0, Black → slot 25).
   A combined move hits on the intermediate point if it lands there [B][GPo].
5. **Bar entry first.** While a player has any checker on the bar, every half-move must be
   a bar entry until the bar is empty; only then may remaining dice move other checkers
   (including the just-entered checker) [B][GPo]. If no entry is possible the turn is
   forfeited; if only some bar checkers can enter, enter as many as possible and forfeit
   the rest [B].
6. **Combined move** with one checker is allowed only via a landable intermediate point
   (doubles: every intermediate point) [B].
7. **Doubles** are played four times [B].
8. **Dice obligation.** Let `M` = the largest number of dice usable by any play sequence;
   only sequences using `M` dice are legal [B]. If `M = 1` on a non-double and either die
   alone could be played, only plays of the **larger** die are legal [GR]
   (standard backgammon; [B] is silent — **DECISION:** enforce it).
9. **Bearing off** only when all 15 own checkers are in home (none on the bar, none
   outside) [B][GR]. A die equal to a checker's distance to off bears it off; a larger die
   bears off only from the **highest occupied point** (no own checker farther from off);
   otherwise the die must be played as a normal move [B]. A checker hit during bear-off
   must re-enter and come home before bearing off resumes [GR][GPo].
10. **Win and scoring.** First to bear off all 15 wins **1 point**, or **2 points** if the
   loser has borne off none (regardless of bar/home-board stragglers — **no triple**)
   [B][T]. No doubling cube [B]. No draws.
11. **Not adopted:** [WT] mentions "no hit-and-run in the home board" without definition;
   neither bkgm nor Greek Wikipedia has it. **DECISION:** ignore.

## Worked examples (unit-test material)

Positions list every checker; 15 per side. White checkers parked on slot 24 are
immobile while bearing off is not yet allowed and the dice are not 1.

**P1 — dance on the bar.** White 1@bar(0), 14@24; Black 2@3, 2@5, 11@6. White 5-3:
both entry points (5, 3) blocked → `{}` (pass; the 24-stack may not move while on bar).

**P2 — enter with the only open die, then play the other.** Same position, White 5-2:
`{(0→2, 2→7)}`. Entering with 5 is impossible; 24 cannot move.

**P3 — two on the bar, doubles.** White 2@0, 13@24; Black 2@3, 2@5, 11@6. White 4-4:
both entries first, then two more 4s:
`{(0→4, 0→4, 4→8, 4→8), (0→4, 0→4, 4→8, 8→12)}`.

**P4 — hit on the intermediate point matters.** White 1@10, 14@24; Black 1@14, 14@3.
White 4-1: two distinct legal moves:
- `(10→14, 14→15)` — hits; result White@15, Black 1@25 (bar).
- `(10→11, 11→15)` — no hit; Black blot stays on 14.
Both are "10→15", so a merged single-half notation would be ambiguous.

**P5 — Black entry.** Black 1@25 (bar), 14@3; White 14@24, 1@15. Black 1-1: entry
`25→24` blocked → `{}`. Black 6-1: `{(25→19, 19→18), (25→19, 3→2)}` (24 is blocked
for the 1, and the bar must be emptied before 3→2).

**P6 — larger-die bear-off.** White 10@23, 5@24; Black 15@3. White 6-5:
`{(23→25, 23→25)}`.

**P7 — larger die only from the highest point.** White 1@20, 14@23; Black 15@3. White
6-5: `{(20→25, 23→25)}`. Playing the 5 as `23→25` while 20 is occupied is illegal.

**P8 — larger-die obligation.** White 1@10, 14@24; Black 2@19, 13@3. White 6-3 (10→16 and
10→13 open; 16→19, 13→19 blocked): `{(10→16)}` — `(10→13)` is illegal.

**P9 — no bear-off with a checker on the bar.** White 1@0, 14@22; Black 2@4, 13@1.
White 6-3: sequences `(0→6, 6→9)` and `(0→3, 3→9)`; `22→25` is never legal (the entered
checker is outside home). Both reach the same position, so the de-duplicated result set
is exactly one position: White 1@9, 14@22.

**P10 — initial position membership.** From the setup, White 3-1:
`(17→20, 19→20)` ("make the 5-point") is legal; `(1→4, 1→2)` is legal; no move may leave
a White checker on 13 (Black owns 5 there).
