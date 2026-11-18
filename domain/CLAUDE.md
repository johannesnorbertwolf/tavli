# domain/ — Game Rules and Board State

## ruleset.py / plakoto_rules.py — the variant seam (#136)

`RuleSet` (ABC) is everything variant-specific: `name`, `initial_board(config)`,
`legal_moves(board, color, dice)`, `has_won(board, c)`, `is_open_for(board, i, c)`,
`result_points(board, winner)` (1/2), `make_encoder(config, version=None)`,
`default_encoder_version`, `supports_bearoff_db`. Registry: `register_ruleset(instance, replace=False)`,
`get_ruleset(name)` (case-insensitive; unknown → `ValueError`), `registered_variants()`. Config key
`variant:` selects one (default `plakoto`).

**Game-outcome seam** (#137; non-abstract, defaults keep Plakoto bit-identical) — the only way shared
code decides game end / winner / terminal reward: `max_points` (default 1), `is_over(board)`,
`outcome(board) -> (winner|None, points)` (None = draw, 0 points; call only when over),
`terminal_value(board, persp) = 0.5 + signed_points / (2*max_points)` ∈ [0,1] (1.0/0.0 when
`max_points == 1`; the TD terminal target and search-leaf value, so a 2-point variant's net learns
normalized expected points and stays symmetric), `random_starting_player` (default False) +
`starting_player(default, rng=None)` (returns `default` without touching the rng unless random).
Module helper `score_for(outcome, color) -> (win_credit 1/0.5/0, signed_points)` for eval.

- `PlakotoRules` (`plakoto_rules.py`, registered as `"plakoto"`) wraps `Board` + `move_generation`
  with no logic of its own; `legal_moves` is a `staticmethod` bound to the generator itself (zero
  wrapper overhead — keep that pattern for new variants). `make_encoder` lazily imports `ai.board_encoder`.
- **New variant**: own board class honouring the duck-typed contract `apply(move, c) -> token`,
  `undo(token)`, `clone()`, `has_won(c)`; own move generator; a `RuleSet` subclass registered at import
  (and imported from `ruleset._load_builtins`); a config with `variant: <name>` and its own output paths.
  `HalfMove`/`Move` are shared. `board.py` / `move_generation.py` below are the Plakoto implementation.
- `PortesRules` (`portes_rules.py`, `"portes"`, #137, spec `docs/variants/portes.md`): `max_points=2`
  (gammon), `random_starting_player=True`, `supports_bearoff_db=False`, encoder `portes_v1`.
  - `portes_board.py` — `PortesBoard`: one signed array `p[26]` (`>0` White, `<0` Black); `p[0]` =
    White's bar, `p[25]` = Black's bar; borne-off only counted in `borne_off[c]`. Hits send the blot
    to its owner's bar; undo entry `(src, dst, color, hit)`. `from_counts(white, black, …)` test helper,
    `key()` hashable position, `result_points(winner)` (2 iff loser bore off none; no triple).
  - `portes_move_generation.py` — `legal_moves`: DFS over dice orders on a mover-relative copy (r = pips
    to off, r=25 = own bar); doubles keep sources non-increasing; one `Move` per distinct resulting
    position; keeps only max-dice sequences, larger die when only one die plays; bar entry first;
    bear-off only all-home, larger die only from the highest point. Two-dice single-checker plays are
    two halves (never merged). Tests cross-check it against a brute-force reference.

## plakoto_standard_*.py — standard (bkgm) Plakoto, `"plakoto_standard"` (#139)

Spec + diff vs the house rules: `docs/variants/plakoto-standard.md` (all DECISIONs implemented as
recommended). Config: `config/config-plakoto-standard.yml`. Encoder `plakoto_std_v1` (ai/REFERENCE.md).

- `plakoto_standard_board.py` — `StandardPlakotoBoard(Board)`: same state/apply/undo; overrides
  `has_won`/`clone`, adds `mother_pinned(c)`, `checkers_on_start(c)`, `mother_win(c)`, `is_draw()`,
  `is_over()`, `outcome() -> (winner|None, points)`. Both mothers pinned = draw (0); mother pinned and the
  pinner's own start empty = 2-point win (otherwise play continues); bear-off win = 1, or 2 if the loser
  has borne off none. Pure functions of the position (= "checked after every complete move").
- `plakoto_standard_moves.py` — independent generator: brute force over half-move sequences on local
  arrays in mover-perspective coordinates; only max-dice plays; single playable die ⇒ the larger;
  larger-die bear-off only from the highest occupied point (own pinned checkers count; any own checker
  pinned outside home forbids bear-off). Doubles enumerate sources in movement order (any legal multiset
  is legal in that order). Non-doubles de-duplicate the two die orders; one checker's net movement ⇒
  merged single half (also `q→p, p→t` ⇒ `q→t`). Bear-off notation `(src, off)` even when the die overshoots.
- `plakoto_standard_rules.py` — `StandardPlakotoRules`: `max_points=2`, `random_starting_player=True`,
  `supports_bearoff_db=False` (DB assumes exact-die bear-off), `is_over`/`outcome` overrides.
- Tests: `tests/domain/test_plakoto_standard.py` pins every spec example under both engines and fuzzes
  the generator against a brute-force reference (`apply_half` on a clone) and the current engine.
## fevga_board.py / fevga_rules.py — Fevga (#138, spec `docs/variants/fevga.md`)

- `FevgaBoard`: physical slots like `Board` (`n`, `color`, `borne_off`; `pinned` is an all-False
  compat list). White path = slots 1..24 → off 25; Black path = 13..24,1..12 → off **0**.
  `SLOT_OF[c][p]` / `PATH_OF[c][s]` convert slot ↔ per-colour path index (25 = off). One colour per
  point; undo token is just `(move, color)` (no hitting ⇒ moving back is exact). `has_won` = all off.
- `fevga_legal_moves` (bound as `FevgaRules.legal_moves`): DFS over play sequences in the mover's
  path coordinates with transposition pruning (additive position hash), recording **every prefix**;
  drops R1 (own path 1–6 all held) / R2 (six-run consecutive in the opponent's path with no opponent
  checker ahead, none borne off) end positions, then keeps most-dice plays and the larger-die rule.
  First-checker lock (unlocked at path ≥ 14 or any off) is checked per half-move. One `Move` per
  distinct resulting position; non-double one-checker plays merge into one half, doubles list steps.
- `FevgaRules`: `max_points = 2` (mars when loser bore off none), `random_starting_player = True`,
  `supports_bearoff_db = False`, encoder `fevga_v1`. Tests: `tests/domain/test_fevga.py` (spec
  examples F1–F10 + a slow spec-literal reference generator cross-check).

## handicap.py — handicap layer over house Plakoto (#148 phase 1)

`HandicapSpec(kind, intensity, side)`: `side` is the *disadvantaged* colour; bonus kinds
(`KINDS[k].bonus`: `dice_floor`, `pre_borne`, `pip_headstart`, `larger_house`) modify the opponent
(`spec.target`). `make_handicapped_rules(specs)` returns the plain `plakoto` singleton when empty
(bit-identical, zero overhead), else `HandicappedPlakotoRules(PlakotoRules)` (unregistered, name
stays `plakoto`) adding `roll(color, u1, u2, q1, q2) -> Dice` (uniform → face on lo..hi, so a
handicapped die maps the same uniform as the fair one; q's drive forced-low / no-doubles),
`first_mover(default)`, `skips_turn(color, own_turn_no)` (`pass_schedule`: evenly spaced over 40 own
turns), and an `initial_board` with pre-borne / advanced checkers. Demoted doubles use a `Dice` subclass
with `is_pasch() == False` so the plain generator plays them as two dice (deduplicated). Per-side home
size = `HandicapBoard(Board)` overriding `is_home`/`clone` — the generator only sees home size through
`is_home`; `board.py`/`move_generation.py` are untouched. Results / rationale: `docs/handicap-phase1.md`.

Tier-1 dice kinds (both bonus, category "dice", on-distribution): `weighted_dice:β` tilts the favoured
side's roll to p'(r) ∝ p(r)·exp(β·v(r)) over the 21 `ROLLS`, with `v` from an injected
`roll_valuer(board, color)` (constructor arg / attribute; or `values=` passed to `roll`), drawn by
`weighted_faces`: inverse CDF of one uniform `(int(6u1)+u2)/6` over the 36 ordered outcomes, which
for β = 0 is exactly `(face(u1), face(u2))` — fair dice bit-for-bit, same uniforms, so pairs stay
aligned. Cannot share a side with the face kinds (ceiling/floor/forced-low/no-doubles).
`rerolls:N` only exposes `reroll_tokens(color)`; when to reroll is a player policy in the game loop
(`ai/handicap_sweep.py`). `needs_roll_values(color)` / `roll_beta(color)` tell the loop when values are needed.

---

## constants.py

Defines the two player constants and a pair of helpers:
- `WHITE = 1`, `BLACK = -1` — the convention that White moves in the positive direction and Black in the negative direction is load-bearing throughout move generation (destination = `src + color * die_value`).
- `color_name(c)` → `"W"`, `"B"`, or `"."` for 0. Used in debug output.
- `other(c)` → `-c`. Convenience alias for flipping color.

---

## move.py

Two immutable named tuples that represent a move at increasing granularity.

**`HalfMove(src, dst)`**: one checker moving from slot `src` to slot `dst`. Both are board indices (0 = Black's bear-off, 1–24 = playable points, 25 = White's bear-off for a standard 24-point board).

**`Move(halves)`**: a complete move consisting of a tuple of `HalfMove`s. Normal rolls produce moves with 2 halves. Doubles produce up to 4 halves. "Merged" single-checker jumps (one checker uses both dice in sequence) produce 1 half with `dst = src + color * (d1 + d2)`. Pass (no legal moves) is represented by an empty move list, not a special Move value.

Both types are hashable and repr-able.

---

## dice.py

**`Die(sides, value)`**: a single die. `roll(rng=None)` sets `self.value` to a random integer in `[1, sides]` and returns it. Accepts an optional `random.Random` instance for seeded/isolated rolling.

**`Dice(sides, rng=None)`**: a pair of `Die` instances (`die1`, `die2`). `roll()` rolls both dice and returns `(die1, die2)`. `set(v1, v2)` forces values without rolling — used in 2-ply expectimax enumeration and tests. `is_pasch()` returns True when both dice show the same value (doubles).

---

## board.py

`Board` is the complete Plakoto game state. It uses three parallel arrays of length `board_size + 2` (default 26 for a 24-point board):

- `n[i]`: number of "owning" checkers at slot `i` (≥ 0)
- `color[i]`: color of those checkers (`WHITE`, `BLACK`, or 0 if empty)
- `pinned[i]`: True iff there is exactly one opponent checker trapped under the owner stack at slot `i`

The "pinned" mechanic is central to Plakoto: landing on a single opponent piece traps it instead of sending it to the bar (as in standard backgammon). The trapped piece has color `-color[i]` and counts toward its own color for win-condition purposes.

`borne_off: Dict[int, int]` counts how many pieces each color has borne off.

**Slot layout**:
- `0`: Black's bear-off
- `1..board_size`: playable points (White starts all pieces at 1, Black at `board_size`)
- `board_size + 1`: White's bear-off

**Initial position** (`Board.initial(config)`): White has `pieces_per_player` checkers at slot 1, Black has `pieces_per_player` at slot `board_size`. No other pieces.

### Key methods

`is_open_for(i, c)`: True if slot `i` can receive a checker of color `c`. A slot is open if it is empty, already owned by `c`, or contains exactly one unguarded opponent piece (which will be pinned).

`is_captured_by(i, c)`: True if the stack at `i` is owned by `c` and has a pinned opponent piece underneath.

`movable_count(i, c)`: number of pieces color `c` can move from slot `i` (0 if wrong color or empty).

`count_outside_home(c)`: number of `c`'s pieces that are not yet in `c`'s home quadrant. A pinned piece counts toward its own color. Used by bear-off legality checks.

`apply_half(src, dst, c)`: atomically applies one half-move and returns an undo entry tuple. Handles all cases: normal move, pin (landing on a blot), unpin (last owner leaves a pinned slot), and bear-off. The undo entry is a 9-tuple of before-values for both src and dst.

`undo_half(entry)`: exact inverse of `apply_half`. Restores both slots and adjusts `borne_off` if the move was a bear-off.

`apply(move, c)` / `undo(token)`: apply/undo all halves of a `Move`, returning/consuming an `UndoToken` (a list of undo entries). This is the interface used by the agent and training loop for try-and-evaluate without copying the board.

### Win conditions

`has_won(c)` returns True if either win condition holds:
1. `all_borne_off(c)`: `borne_off[c] >= pieces_per_player` — all pieces borne off.
2. `captured_starting(c)`: the opponent's starting point is pinned by `c` — White wins by pinning slot 24, Black wins by pinning slot 1.

---

## move_generation.py

`legal_moves(board, color, dice)` is the public entry point. Dispatches to `_pasch_moves` (doubles) or `_normal_moves` (non-doubles).

### Non-pasch moves (`_normal_moves`)

Generates all legal `Move` objects for two distinct die values `d1` and `d2`.

Three categories are emitted:

1. **Two-half independent moves**: pairs `(h1, h2)` where `h1` uses `d1` and `h2` uses `d2`, their sources/destinations don't chain (i.e., `h1.dst ≠ h2.src` and vice versa), both halves are individually valid, and at least one ordering satisfies the bear-off home rule. Same-source pairs require `n[src] >= 2`.

2. **Merged single-checker jumps**: a single checker moves `d1 + d2` in one step (`Move((HalfMove(src, src + color*(d1+d2)),))`). Legal only if at least one of the two intermediate split-points is open, and the bear-off home rule is satisfied via at least one split ordering.

3. **Rule-2 single-die moves** (`_emit_rule_2`): if playing one die leaves the other die with no legal move, the single-die move is emitted. Called once for each die.

Bear-off home rule: a checker may only bear off if all of the player's checkers are in the home quadrant (`count_outside_home == 0` after accounting for the first half of the move).

### Pasch moves (`_pasch_moves`)

Doubles allow up to 4 moves of the same die value. Uses a 4-level nested loop over starting positions (iterating in the direction of movement). A `movable[]` array and `is_open[]` array are pre-computed for performance and mutated in-place during the nested loop (no actual board mutations). Shorter sequences (1, 2, 3 halves) are emitted only when the next level of the loop finds no legal step (`fourth_is_possible`, `third_is_possible`, `second_is_possible` flags). This faithfully replicates the `PaschGenerator` semantics.

`_can_step(point, delta, movable, is_open, bsize, outside_count)`: a fast check on the pre-computed arrays, also enforcing the bear-off home rule.
