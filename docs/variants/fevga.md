# Fevga — rules spec

Implementation spec for `FevgaRules` (issue #138). Fevga is a running/blocking game:
both sides move in the **same** rotational direction, a single checker holds a point,
nothing is ever hit or pinned. Items marked **DECISION** are open for review; the
recommendation is what engineers should implement unless overruled.

## Sources

- [B] bkgm.com, Fevga: https://www.bkgm.com/variants/Fevga.html
- [T] bkgm.com, Tavli overview (scoring, who starts): https://www.bkgm.com/variants/Tavli.html
- [W] Wikipedia, Fevga: https://en.wikipedia.org/wiki/Fevga
- [GR] Greek Wikipedia, general Tavli rules: https://el.wikipedia.org/wiki/Κανόνες_του_ταβλιού
- [GF] Greek Wikipedia, Fevga: https://el.wikipedia.org/wiki/Φεύγα

## Coordinates (DECISION — recommended mapping)

Storage stays **physical**: slots 1..24 are the 24 points, `n/color` arrays as in Plakoto.
White's path is the slot order; Black starts at the diagonally opposite corner (12 points
ahead) and travels the same way round, wrapping from 24 to 1.

| | start | path (in order) | home (last 6) | off slot |
|---|---|---|---|---|
| White (+1) | slot 1 | 1, 2, …, 24 | 19–24 | 25 |
| Black (−1) | slot 13 | 13, …, 24, 1, …, 12 | 7–12 | 0 |

Per-colour **path index** `p ∈ 1..24` (`p = 25` means borne off):
- White: `p = s`, `s = p`.
- Black: `p = s - 12` if `s ≥ 13` else `s + 12`; inverse `s = p + 12` if `p ≤ 12` else `p - 12`.

All rules below are stated in path indices. A half-move is computed as
`dst = slot(p(src) + die)`, or the colour's off slot if `p(src) + die ≥ 25` (subject to
bear-off rules). `HalfMove(src, dst)` always carries **physical** slots; Black's off
slot is 0, White's 25 (so `is_off_board` and `borne_off` keep their meaning). Example:
Black 22→3 with a 5 (path 10→15); Black 10→0 bears off (path 22→off).

Consequences: `dst = src + color*die` does **not** hold for Fevga Black; any shared code
that assumes `sign(dst - src) == color` must go through the rule set. The encoder's
perspective flip for Black is a **rotation by 12** (`s → p`), not the mirror `s → 25-s`.
Rejected alternative: storing Black in path coordinates in the same arrays — one board
would then hold two incompatible coordinate systems, which breaks occupancy checks.

## Rules

1. **Setup.** White 15 on slot 1, Black 15 on slot 13 [B][W][GF].
2. **Opening.** Each side rolls one die; higher starts and rolls both dice afresh; in a
   match the previous winner starts [B][W][T]. **DECISION:** single game → random starter.
3. **Landing.** A point is open for `c` iff it holds no opponent checker. One checker
   holds a point; no hitting, no pinning [B][W].
4. **Combined move** with one checker requires an open intermediate point (doubles: each
   intermediate point) [B][W]. The merged single-half notation of the Plakoto engine is
   fine here (intermediate landings have no lasting effect); examples use it.
5. **Doubles** are played four times [B][W].
6. **First-checker rule.** A colour is *unlocked* once it has any checker at path index
   ≥ 14 (strictly past the opponent's starting point, path 13) or borne off [B][W].
   While locked: if all 15 checkers are on the start (path 1), the move may begin with any
   one of them; otherwise only the checker that is off the start may move. Evaluate per
   half-move, so a runner that passes path 13 with the first die unlocks the second die
   (F4). [GF] phrases the threshold as "reaching the opponent's starting quadrant"
   (path 13–18); since path 13 is occupied by the opponent in practice the two coincide.
   **DECISION:** use "path ≥ 14".
7. **Starting-table rule (R1).** A move may not end with the player holding all six points
   of its own starting table, path 1–6 (White slots 1–6, Black slots 13–18) [B][GF].
8. **Six-prime rule (R2).** A move may not end with the player holding six consecutive
   points (consecutive in the **opponent's** path indices `q..q+5`) while **no** opponent
   checker is ahead of it (opponent path index `> q+5`, or borne off). Sources disagree:
   - [B]: you may not keep a six-prime when the opponent has gathered all checkers on the
     point behind it — you must break it.
   - [W]: primes are forbidden in your first quadrant and the opponent's first quadrant;
     never leave the opponent completely blocked; prime rules are regional.
   - [GF]: six-primes are allowed except (a) one that leaves the opponent no legal roll,
     (b) directly in front of the opponent's start (opponent path 2–7); a further variant
     concerns the bear-off quadrant.
   **DECISION:** implement R2 as stated — a static end-of-move check that generalises the
   bkgm case, matches issue #138's "no prime-lock", and needs no lookahead over opponent
   rolls (unlike [W]'s "complete block" test).
9. **Illegal endings vs dice obligation.** Generate all play sequences, drop those whose
   final position violates R1/R2, then apply the dice obligation (rule 10) to what
   remains; a shorter prefix that is itself R1/R2-clean counts as a legal play. If nothing
   remains the player passes. **DECISION** ([W]: if no move can release a block, the
   opponent misses turns — this falls out naturally).
10. **Dice obligation.** Let `M` = most dice usable; only `M`-dice sequences are legal; if
   `M = 1` on a non-double and either die alone is playable, only the **larger** [B][W].
11. **Bearing off** only when all 15 are in home (path 19–24). Exact die bears off; a
   larger die bears off only from the highest occupied point (lowest path index in home);
   otherwise it must be played as a normal move [B][W].
12. **Win/scoring.** First to bear off 15 wins **1 point**, **2** if the loser has borne off
   none (mars) [B][W][T]. No triple, no cube, no draws.

## Worked examples (unit-test material)

Every checker is listed (15 per side).

**F1 — opening non-double.** White 15@1, Black 15@13. White 6-5: `{(1→12)}` (locked:
both dice must go on one checker; 6 and 7 both open).

**F2 — opening 6-6.** Same. `{(1→7)}` — 7→13 is blocked by Black's start and no second
checker may leave slot 1 while locked. Black mirror (White 15@1, Black 15@13, Black 6-6):
`{(13→19)}` (path 7→13 = slot 1 is White's start).

**F3 — opening 3-3.** Same. `{(1→4, 4→7, 7→10)}` (fourth 3 would land on 13).

**F4 — unlock mid-turn.** White 14@1, 1@10; Black 15@13. White 5-2:
`{(10→17), (10→15, 1→3)}`. Playing the 2 first with a start checker is illegal (locked).

**F5 — Black wraps.** Black 14@13, 1@22 (path 10); White 15@1. Black 5-3:
`{(22→6), (22→3, 13→16)}`. The 3 first (path 13 = slot 1) is blocked; the 5 lands on
slot 3 (path 15), which unlocks Black.

**F6 — Black bears off with larger dice.** Black 15@10 (path 22); White 15@22.
Black 6-4: `{(10→0, 10→0)}`.

**F7 — locked and blocked: pass.** White 14@1, 1@7; Black 13@13, 2@9. White 6-2:
`{}` (7→13 and 7→9 blocked; start checkers may not move while locked).

**F8 — R1 starting table.** White 9@1, 1 each on 2, 3, 4, 5, 10, 14; Black 15@13. White
5-2: `(1→6, 14→16)` is **illegal** (White would hold 1–6; R2 also fires). `(1→6, 4→6)`
is **legal** (point 4 is vacated).

**F9 — R2 six-prime.** White 9@1, 1@11, 1 each on 16–20. White 4-1, candidate
`(11→15, 1→2)` builds slots 15–20 = Black path 3–8.
(a) Black 14@13, 1@14 (all behind): **illegal**.
(b) Black 14@13, 1@22 (path 10, ahead of the prime): **legal**.

**F10 — larger-die obligation.** White 1@10, 14@24; Black 1@19, 14@13. White 5-4
(10→15 and 10→14 open, 15→19 and 14→19 blocked): `{(10→15)}`.
