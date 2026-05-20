# domain/ — Game Rules and Board State

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

### Race detection

`is_race()` returns True when no future contact between the two players is possible — i.e. they have already passed each other. Since White travels 1→`board_size+1` and Black travels `board_size`→0 (opposite directions), this holds iff every White checker sits at a strictly higher point than every Black checker: `min(white_points) > max(black_points)`. Empty boards and fully-borne-off positions are races (the absent side uses an out-of-range sentinel). A pinned blot is counted toward **its own** color (the blot under slot `i` has color `-color[i]`), because the pinning stack can move off and re-expose the blot to contact — so a lagging pinned blot correctly prevents a race. Used by the MC-grounding training feature (`ai/mc_rollouts.py`) to decide when to replace the TD bootstrap target with a rollout estimate.

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
