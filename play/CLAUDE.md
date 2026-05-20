# Play UI Reference

The interactive `./run.sh play` loop lets a human play a single game of Plakoto against a trained model, with full undo, save/load, and per-move evaluation. This document is the authoritative reference for *what the UI does today*.

This file lives in `play/` so it auto-loads into Claude Code's context whenever you work on this package. It doubles as the user-facing reference for `./run.sh play`. Two parts:

- **Part 1 — User reference**: how to invoke the game, every command, every prompt, every special flow.
- **Part 2 — Developer internals**: module layout, session/snapshot state, undo mechanics, persistence schema, testing patterns.

Historical design documents — [`docs/play_ui_concept.md`](../docs/play_ui_concept.md) and [`docs/play_ui_implementation_plan.md`](../docs/play_ui_implementation_plan.md) — are *not* authoritative; they describe the original intent before the code landed. When the design and the implementation diverge, this file wins.

---

## Part 1 — User reference

### 1. Invocation

There are three ways to launch the play loop.

| Command | What it does |
|---|---|
| `./run.sh play` | Loads `trained_model.pth` (the live training checkpoint). Prompts for color and dice mode. |
| `./run.sh play <model_path>` | Same, but with a specific checkpoint. Useful for playing against a gold model: `./run.sh play models/gold_v9.pth`. |
| `python main.py play [--network PATH] [--load NAME]` | Direct invocation. Supports `--load NAME` to resume from a saved game (which `run.sh` does not surface). |

#### `run.sh` quirk: the model path is positional, not flagged

`run.sh` wraps its `$2` argument as `--network "$2"` before forwarding to `main.py`. So:

- ✅ `./run.sh play models/gold_v9.pth` — works (becomes `main.py play --network models/gold_v9.pth`).
- ❌ `./run.sh play --network models/gold_v9.pth` — double-wraps. The literal string `"--network"` becomes the model path and you get `Model file not found at --network.`

If you want `--load`, drop into Python directly: `python main.py play --load mygame`.

The default model path is `trained_model.pth` if `--network` is omitted. If both `--network` and `--load` are passed, `--load` wins: the network is taken from the save file's `ai_checkpoint_path` field, and the `--network` argument is ignored unless the save's checkpoint is missing.

### 2. Startup prompts

Two prompts appear before the first turn (skipped entirely when `--load NAME` is used — those settings come from the save).

```
Pick your color [w/b/r] (default w):
```

- `w` (or empty) — you play White.
- `b` — you play Black.
- `r` — randomised (50/50 between White and Black).

White always moves first in the game, regardless of which color you pick.

```
Dice mode [auto/manual] (default auto):
```

- `auto` (or `a`, or empty) — the game rolls dice for every turn (yours and the AI's).
- `manual` (or `m`) — you enter dice for every turn, including the AI's. Useful for replaying a recorded game, or for AI-vs-human analysis from a specific position.

Source: [main.py:515-535](../main.py).

### 3. Header, footer, and board layout

Every time it's your turn, the loop prints a three-part block:

```
Ply 5 — White to move — dice 3 5 — eval depth 4
<board diagram>
                                                        1: 1/4, 1/6 (54.21%)
<board info column>                                     2: 1/4, 1/8 (53.10%)
                                                        3: 6/9, 6/11 (51.88%)
                                                        ...
[1-N] play   u undo   h history   e eval   save <n>   q quit
```

- **Header line** — [renderer.py:48-55](renderer.py). Shows the current ply number, who moves, the dice if they've been set, and the current eval depth (`session.eval_depth`). The dice section is omitted before dice are rolled or entered.
- **Board+ranked-moves block** — [renderer.py:9-40](renderer.py). The board is on the left; on the right is a numbered list of every legal move with the agent's win-probability estimate for the resulting position (higher = better for you). Moves are sorted best-first. Long lists wrap into multiple columns.
- **Footer line** — [renderer.py:6](renderer.py). Constant reminder of available commands.

After the AI plays, you see a similar block without the move list:

```
Ply 6 — Black (AI) — dice 4 2
<board diagram>
AI played: 13/15, 13/17 (47.83%)
```

The score is the agent's evaluation of the position *after* it played (from its own perspective). Source: [renderer.py:72-80](renderer.py).

### 4. Command reference

Every command accepted at the main turn prompt (`>`). Aliases are case-insensitive. Source: [parser.py](parser.py).

#### `1`..`N` — play a move

Type the rank of the move you want to play, as shown in the ranked list. `1` is the agent's top pick, `2` is second-best, etc.

- Leading zeros are accepted: `01` is the same as `1`.
- Whitespace around the number is fine: ` 2 ` works.
- `0` and negative numbers are rejected.

After you commit a move, the AI takes its turn automatically (unless it has no legal moves — see §6).

#### `u` / `undo` `[N]` — rewind to your previous decision

Rolls back to your most recent decision point. In practice this means popping **both** the AI's last ply *and* your own preceding ply, so you're back at the moment of your last move with the same dice you originally had.

- `u` — undo one decision (typically pops 2 plies).
- `u 3` or `u3` — undo 3 decisions.
- `N` must be ≥1; `u 0` is rejected.

If you haven't made any moves yet (e.g. AI opened and you have no decisions on the stack), undo is a no-op — you'll see `nothing to undo`.

In **AUTO** dice mode, undo restores the *original* dice from your previous ply, so re-playing the same situation is deterministic. In **MANUAL** mode, dice are cleared after undo — the next prompt asks you to re-enter them.

Source: [session.py::undo_to_my_decision](session.py), [loop.py::_human_turn](loop.py).

#### `h` / `history` — list plies played

Prints every ply in the game so far, one per line:

```
1.  W  d=3 5  1/4, 1/6
2.  B  d=4 2  24/22, 22/20
3.  W  d=6 6  (pass)
```

Format per ply: `<index>.  <W|B>  d=<die1> <die2>  <move-or-pass>`.

If no moves have been played yet, prints `(no history yet)`.

Source: [session.py::history_lines](session.py), summary format at [session.py::_format_summary](session.py).

#### `e` / `eval` `[N]` — re-rank moves at depth N

Re-evaluates all legal moves at a deeper lookahead (more plies searched).

- `e` (no argument) — re-rank at the current session depth.
- `e 5` (or `e5`) — set the session depth to 5 and re-rank. The new depth sticks: subsequent turns also use depth 5 until you change it again.
- `N` must be ≥1.

The default depth comes from `play.eval_lookahead_plies` in `config/config.yml` (default `4`). After invoking `e`, a confirmation line `(re-ranking at depth N…)` is printed before the new block.

Source: [loop.py::_human_turn](loop.py), [session.py::ranked_moves](session.py).

#### `drill [N]` — interactive blunder training

Available **only at the post-game prompt** (after someone has won). Like `review`, it scans all your plies and flags moves that were more than N% worse than the best (relative gap; default 10%). But instead of showing a summary, it steps through each blunder interactively, asking you to find a better move.

At each flagged position the board is shown with what you played and the size of the gap. You then enter the source point(s) of the move you'd like to try:

```
── Blunder 1/3 — Ply 5 — dice 3 5 ──
<board>
You played: (18->21,18->23)  (62.3%)  ← there's a 11.8% better move
Your move (solution / skip / back) > 8 18
```

**Move input format:** enter only the **source point(s)**, space-separated. The system derives the destinations from the current dice and resolves to a single move deterministically (no menu).

| Input | Dice | Meaning |
|---|---|---|
| `18 6` | `3 5` | Move from 18 using the **first** die (→21), and from 6 using the **second** die (→11). |
| `6 18` | `3 5` | The order is significant: 6 uses the first die (→9), 18 uses the second (→23). |
| `8` | `3 5` | One checker from 8: tries the merged move (8→16) first, else a single die. |
| `1 1 1 1` | `4 4` | Doubles: four die-steps from point 1. |

The order of the numbers maps to the printed dice order: the *i*-th number uses the *i*-th die. To get a different die assignment, reverse the numbers.

**Doubles (pasch).** All four dice must usually be played, and a single checker often *walks* several steps. List one entry per die-step. Repeat a point to walk the same checker:

| Input | Dice | Resolves to |
|---|---|---|
| `3 3 3 8` | `2 2` | walk the 3-checker three steps (3→5→7→9) and move the 8-checker once (8→10) |
| `3 5 7 8` | `2 2` | the same move, written as explicit hop-starts |

Both styles are accepted and equivalent. Two source points cannot describe a mandatory four-die roll, so e.g. `3 8` alone won't match — list all the steps.

**Feedback:**
- Optimal (within the configured tolerance): `Excellent! — that's the best move.` or `Great choice! — very close to optimal.`
- Suboptimal: `Not quite (X%) — think a little harder!` — keeps prompting.
- Illegal sources: `No legal move from those positions.`

**Other commands at the drill prompt:**
- `solution` — reveal the best move and advance to the next blunder.
- `skip` — skip this blunder and advance.
- `back` — go back to the previous blunder (clamps at the first).

After all blunders are resolved (solved or skipped), `Drill complete.` is printed.

The "correct" tolerance is configured via `play.drill_correct_floor` and `play.drill_correct_relative` in `config/config.yml` (defaults: 0.01 floor, 0.03 relative). See §7.

Source: [loop.py::_handle_drill](loop.py), [loop.py::_drill_inner](loop.py), [renderer.py::format_drill_position](renderer.py), [parser.py::parse_move_input](parser.py).

#### `review [N]` — post-game blunder analysis

Available **only at the post-game prompt** (after someone has won). Replays every ply you played and flags moves where your choice was more than N% below the agent's best option.

- `review` — use the default threshold of 10%.
- `review 15` — flag blunders where your move was ≥15% worse than the best.
- `N` must be ≥1.

For each flagged ply, the output shows the board state at that moment, the move you played and its win-probability, and the agent's best move and its win-probability. After scanning all plies, a count of blunders is printed, or `— well played!` if none were found.

The replay uses the same eval depth as the session (`session.eval_depth`, default 4). For long games this can take a few seconds.

Source: [loop.py::_handle_review](loop.py), [renderer.py::format_blunder_block](renderer.py).

#### `save <name>` — write the current session to disk

Writes the session to `saved_games/<name>.json`. The `.json` suffix is auto-appended if you omit it.

- If the file already exists, you're prompted: `<path> exists. Overwrite? [y/N]:`. Anything other than `y` cancels.
- Names preserve case and may include extensions: `save Foo.json` writes `Foo.json`, not `Foo.json.json`.
- Save creates `saved_games/` if it doesn't exist.

Source: [loop.py::_handle_save](loop.py), [persistence.py](persistence.py).

#### `load <name>` — resume a saved game

Loads `saved_games/<name>.json` and replaces the current session.

- If your current session has unsaved changes (`dirty_since_save`):
  - If it has a known save name, it's auto-saved over that file.
  - Otherwise, it's auto-saved as `autosave_YYYYMMDD_HHMMSS.json`.
- If the save's AI checkpoint (`ai_checkpoint_path`) is missing, you're prompted for a replacement path. Enter `c` or a blank line to cancel.
- Mismatched schema versions raise `IncompatibleSave` and refuse to load.

After loading, the session is marked clean (not dirty), so quitting immediately is safe.

Source: [loop.py::_handle_load](loop.py).

#### `?` / `help` — print the command list

Prints the canonical command summary (the same list documented in this file).

#### `q` / `quit` — exit

Exits the loop. If there are unsaved changes:

```
Unsaved progress. [q] discard & quit / [save <n>] save & quit / [c] cancel:
```

- `q` or `quit` — discard and exit.
- `save <name>` — save first, then exit.
- `c` or blank — cancel quit, return to play.

Source: [loop.py::_handle_quit](loop.py).

### 5. Dice input

The dice prompt looks like this:

```
White to move. Enter dice (e.g. '5 2' or '53'):
```

#### Accepted formats

Anything matching the regex `^\d\D*\d$` — a digit, any non-digit characters, another digit. Trailing/leading whitespace is stripped first.

| Input | Parsed as |
|---|---|
| `5 2` | (5, 2) |
| `52` | (5, 2) |
| `5-2` | (5, 2) |
| `5/2` | (5, 2) |
| `5,2` | (5, 2) |
| `5  2` | (5, 2) |

#### Validation

Each die value must be in `1..die_sides`. The default `die_sides` is 6 (from `config/config.yml`). Values outside the range raise `InvalidDiceInput` and the prompt repeats.

Source: [parser.py::parse_dice](parser.py).

#### Commands accepted at the dice prompt

While waiting for dice, the parser also accepts top-level commands. Specifically: `u`/`undo`, `h`/`history`, `?`/`help`, `save`, `load`, `q`/`quit`. **Not accepted**: `e`/`eval` (no moves yet to rank) and rank numbers `1..N` (same reason). Unparseable input prints `unparseable; enter dice (e.g. '5 2') or a command.` and re-prompts.

Source: [loop.py::_dice_prompt](loop.py).

### 6. Special flows

#### When you have no legal moves

The loop prints `<Color> has no valid moves.` and shows:

```
[enter] pass   u undo :
```

- Pressing Enter (empty input) commits a pass and the turn passes to the AI.
- `u` or `u N` undoes to your previous decision.
- **Anything else also commits a pass** — there's no validation here, so typing `save foo` at this prompt will not save; it will pass. Be careful.

Source: [loop.py::_no_moves](loop.py).

#### When the AI has no legal moves

The AI auto-passes silently. You'll see a one-line message: `Black (AI) has no valid moves; passing.`, then the next turn begins immediately.

#### Game over (terminal)

When someone wins, the board is printed with `Game over. White wins.` (or `Black wins.`) followed by a post-game prompt:

```
[u/undo, h/history, review [N], drill [N], save <n>, q] >
```

Accepted commands:

- `u` / `undo [N]` — un-ends the game and lets you keep playing from before the winning move. The terminal state flips back to non-terminal.
- `h` / `history` — print the ply log.
- `review [N]` — scan every human ply and flag moves that were ≥N% worse than the agent's best (relative gap). Default threshold 10%. See §4.
- `drill [N]` — same blunder detection as `review`, but interactive: step through each flagged position and try to find the better move. Enter source points as space-separated numbers (e.g. `18 6`). See §4.
- `save <name>` — save the (terminal) session.
- `q` / `quit` — exit (with the same dirty-quit prompt as during play).
- `?` / `help` — short reminder of what's accepted here.

Not accepted: move ranks (no moves to play), `e`/`eval`, `load`. Anything else prints `post-game accepts: u/undo, h/history, review [N], drill [N], save <n>, q/quit`.

When you exit a completed game, one line is appended to `training_runs/human_game_history.log` recording the result, and a stats summary box is printed.

Source: [loop.py::_post_game](loop.py), [main.py:308-398](../main.py).

### 7. Configuration knobs

Relevant entries in `config/config.yml`:

| Key | Default | Effect |
|---|---|---|
| `play.eval_lookahead_plies` | `4` | Default lookahead depth for ranked moves and what `e` reverts to with no argument. |
| `play.drill_correct_floor` | `0.01` | Absolute floor for the drill "correct" tolerance (1 pp). Prevents impossible standards in nearly-lost positions. |
| `play.drill_correct_relative` | `0.03` | Fraction of `best_score` for "correct" tolerance. At best=0.70, correct means within 0.021 (2.1 pp). |
| `die_sides` | `6` | Range cap for dice input validation. |
| `board_size`, `pieces_per_player`, `home_size` | 24 / 15 / 6 | Standard Plakoto board parameters; not play-UI-specific but affect what moves are legal. |
| `hidden_sizes`, `learning_rate`, etc. | (training) | Don't affect the play loop — the loaded model's saved architecture is what's used. |

Source: [config/config_loader.py:132](../config/config_loader.py).

### 8. Save file format

Files live in `saved_games/<name>.json` (created on first save). The directory is configurable via `play.persistence.SAVED_GAMES_DIR` at the code level — there's no config key.

Example save:

```json
{
  "schema_version": 1,
  "encoder_version": "unary_v3",
  "ai_checkpoint_path": "models/gold_v9.pth",
  "dice_mode": "auto",
  "human_color": "w",
  "eval_depth": 4,
  "starting_player": "white",
  "history": [
    { "dice": [3, 5], "move": [[1, 4], [1, 6]], "was_pass": false },
    { "dice": [4, 2], "move": [[24, 22], [22, 20]], "was_pass": false },
    { "dice": [6, 6], "move": null, "was_pass": true }
  ]
}
```

Top-level fields:

| Field | Meaning |
|---|---|
| `schema_version` | Integer. Currently `1`. Loads with a different value raise `IncompatibleSave`. |
| `encoder_version` | The encoder the model was trained with (`unary_v3`, `unary_v2`, `legacy_unary_v1`). Informational; the actual encoder used is whatever the checkpoint at `ai_checkpoint_path` specifies. |
| `ai_checkpoint_path` | The model file the AI was using. On load, this path must exist (or you'll be prompted for a replacement). |
| `dice_mode` | `"auto"` or `"manual"`. |
| `human_color` | `"w"` or `"b"`. |
| `eval_depth` | Sticky session eval depth at save time. |
| `starting_player` | `"white"` or `"black"`. (White always starts in standard Plakoto; this is here for completeness.) |
| `history` | Ordered list of plies. Each entry has `dice: [d1, d2]`, plus either `move: [[from_point, to_point], ...]` for a normal ply or `move: null, was_pass: true` for a pass. |

#### Board state is reconstructed, not stored

Loading replays every ply in `history` from the initial position. This has two consequences:

1. **Saves are small** — a few KB regardless of game length.
2. **Saves are portable across model upgrades** — a different network can be loaded as long as the recorded sequence of moves is still legal under the same rules.

If you bump `SCHEMA_VERSION`, existing saves stop loading. There's no migration path; the bump is deliberate.

Source: [persistence.py](persistence.py), [session.py::from_save](session.py).

### 9. Game history logging

Each completed game appends one line to `training_runs/human_game_history.log`:

```
2026-05-19 14:30:45 model=models/gold_v9.pth result=win
```

The `result` field is `win` (you won) or `loss` (AI won). Source: [main.py:308-315](../main.py).

When a game ends inside `./run.sh play`, a summary box is printed:

```
┌────────────────────────────────────────────┐
│  Human vs AI                               │
│                                            │
│  Overall   12W – 8L   (60.0%)              │
│  ██████████████░░░░░░░░░░  60%             │
│                                            │
│  Last 20    ●○●●●○●●○●●●●○●●●○●●           │
│  Streak    3 wins in a row ↑               │
└────────────────────────────────────────────┘
```

To see the same summary without playing: `python main.py human-stats`. For an SVG win-rate chart: `python main.py human-graph [last_x]`.

Source: [main.py:318-398](../main.py).

---

## Part 2 — Developer internals

### 10. Module map

```
play/
├── __init__.py          # empty
├── parser.py            # text → Command dataclass (no state)
├── session.py           # PlaySession + Snapshot; game state machine
├── loop.py              # REPL; dispatch over Command variants
├── renderer.py          # string formatting only
└── persistence.py       # JSON dump/load + path resolution
```

Dependencies flow one way: `loop` uses everything; `session` uses `domain`/`game`; `renderer` only touches `domain` and `session` for read; `persistence` reads/writes `session`. `parser` and `renderer` are pure functions of their inputs.

### 11. `PlaySession` and `Snapshot`

`PlaySession` ([session.py:30](session.py)) owns all game state and is the only piece tests need to construct.

Fields:

| Field | Type | Notes |
|---|---|---|
| `config` | `ConfigLoader` | Used for `die_sides`, `play.eval_lookahead_plies`. |
| `agent` | object | Anything with `evaluate_moves` and `get_best_move`. May be `None` for headless tests that only exercise the mechanical layer. |
| `ai_checkpoint_path` | `str` | Persisted to saves; surfaced to the user on load. |
| `dice_mode` | `DiceMode` enum | `AUTO` or `MANUAL`. |
| `human_color` | `Color` | `WHITE` or `BLACK`. |
| `eval_depth` | `int` | Sticky session-wide default for `ranked_moves`. |
| `starting_player` | `Color` | Always `WHITE` in standard play; settable for tests. |
| `game` | `Game` | Owns the board, dice, and turn pointer. |
| `history` | `list[Snapshot]` | Index 0 is the initial state; each subsequent entry is the state *after* one ply. |
| `_pending_dice` | `tuple[int, int] \| None` | Dice set for the current (not yet committed) ply. Cleared on commit. |
| `last_save_name` | `str \| None` | Last `save <name>` invocation; used as the auto-save target on `load`-while-dirty. |
| `dirty_since_save` | `bool` | Set on every commit; cleared on save and on `from_save`. |

`Snapshot` is a frozen dataclass — once appended it's never mutated:

```python
@dataclass(frozen=True)
class Snapshot:
    next_player: Color           # who plays AFTER this snapshot
    move_played: Move | None     # the move that produced this snapshot (None for index 0)
    dice_for_this_ply: tuple[int, int] | None
    was_pass: bool
    last_move_summary: str       # pre-formatted for history display
```

Two constructors:

- `PlaySession.new_game(config, agent, ai_checkpoint_path, dice_mode, human_color, eval_depth)` — fresh session at ply 0.
- `PlaySession.from_save(config, save_file, agent)` — rebuilds a session by replaying every ply from `save_file.history` into a fresh game. After replay, `dirty_since_save` is cleared.

### 12. Undo mechanics

Two layers, both live on `PlaySession`:

**`undo(n=1)`** — the mechanical primitive. Pops `n` plies. For each popped snapshot, calls `board.undo(move_played)` (skipped for passes). Then restores dice: in AUTO mode, the *last popped* snapshot's `dice_for_this_ply` is reinstated; in MANUAL mode, `_pending_dice` is cleared. Used internally by `from_save`, by the post-game un-end-game flow, and by tests.

**`undo_to_my_decision(n=1)`** — the user-facing semantic. Each step walks history backwards to find the most recent snapshot where `next_player == human_color` (excluding the current top), then pops down to it. If no such snapshot exists (e.g. human is Black and AI just opened), returns 0 plies popped. This is what every user-typed `u` in the loop calls.

The split exists because:
- Tests want fine-grained "pop exactly one ply" behavior to verify the board/dice restoration mechanics.
- `from_save` needs to be able to replay without "decision point" semantics.
- Users want `u` to mean "let me re-decide" — which is always at least 2 plies (your move + the AI's response).

Source: [session.py::undo](session.py), [session.py::undo_to_my_decision](session.py).

### 13. Persistence schema

`SCHEMA_VERSION = 1`. The `dump`/`load` pair lives in [persistence.py](persistence.py).

```python
@dataclass
class SaveFile:
    schema_version: int
    encoder_version: str
    ai_checkpoint_path: str
    dice_mode: str           # "auto" | "manual"
    human_color: str         # "w" | "b"
    eval_depth: int
    starting_player: str     # "white" | "black"
    history: list[dict]
```

Each `history` entry: `{"dice": [d1, d2], "move": [[from_pos, to_pos], ...] | None, "was_pass": bool}`. Positions are integer indices into `board.points` (0 = white bear-off, 25 = black bear-off in standard board geometry).

**Bumping the schema** is intentionally breaking: there's no migration code. If you change the shape, increment `SCHEMA_VERSION` and document the new fields here. Old saves raise `IncompatibleSave` on load.

Two named exceptions:

- `MissingCheckpoint(FileNotFoundError)` — raised by `agent_loader` when `ai_checkpoint_path` doesn't exist. The loop catches it and prompts for a replacement.
- `IncompatibleSave(ValueError)` — raised on schema mismatch.

Path resolution: `resolve_path(name)` appends `.json` if absent and joins against `SAVED_GAMES_DIR`. `autosave_name()` returns `autosave_YYYYMMDD_HHMMSS` using `datetime.now()` by default; tests can pass a fixed `datetime` for determinism.

### 14. Loop dispatch

[loop.py::run](loop.py) defines:

```python
def run(session: PlaySession, io: IO, agent_loader: AgentLoader | None = None) -> PlaySession:
```

It returns the *final* session. This matters because the in-game `load` command swaps in a different `PlaySession` instance — the caller (`main.py::play_against_ai`) needs the post-load session to know if a game finished and to write the human history log.

Per-state handlers (all module-private, all return `Action`):

| Handler | When | Notes |
|---|---|---|
| `_human_turn` | Human's turn, dice set, legal moves available | Reads commands at the `> ` prompt. |
| `_dice_prompt` | Dice not set yet (MANUAL mode, or AUTO between turns) | Accepts dice input or a subset of commands. |
| `_no_moves` | Current player has no legal moves | Auto-passes for AI; prompts human with `[enter] pass   u undo`. |
| `_ai_turn` | AI's turn, dice set | Calls `agent.get_best_move(lookahead_plies=2)` and commits. The AI lookahead is hardcoded; this is separate from `session.eval_depth`. |
| `_post_game` | `session.is_terminal()` | Restricted command set: `u`, `h`, `review`, `drill`, `save`, `q`, `?`. |

`Action(kind, session=None)` carries the dispatch result back to `run`:

- `kind="advance"` — handler did something; loop back to the top.
- `kind="quit"` — user confirmed quit; `run` returns the current session.
- `kind="dice_set"` — `_dice_prompt` got dice; loop back (other handlers don't use this).
- `kind="continue"` — handler wants another iteration in the same state (unused today; reserved).

When `_human_turn` or `_dice_prompt` processes a successful `load`, it returns `Action("advance", session=<new>)` and `run` swaps the working session before the next iteration.

`agent_loader: Callable[[str], object]` is injected, not imported. The loop calls it only when `load` needs to instantiate an agent for a different checkpoint. `main.py::play_against_ai` wires it to `load_agent_from_checkpoint`. Tests pass a lambda that returns a `StubAgent`.

### 15. Testing patterns

All play tests live under [tests/play/](../tests/play/) and run with `unittest`. They share two utilities:

**`FakeIO`** ([tests/play/test_loop.py:28](../tests/play/test_loop.py)) — implements the `loop.IO` protocol with a pre-scripted list of inputs and a captured list of outputs. Asserts the script is fully consumed (any unread input is fine, but running out mid-test is a hard error). Use it to drive the full loop with deterministic interactions:

```python
io = FakeIO(["3 5", "1", "u", "6 1", "1", "q", "q"])
final = loop.run(s, io)
```

**`StubAgent`** ([tests/play/test_loop.py:17](../tests/play/test_loop.py)) — returns a constant score for `evaluate_moves` and the first move for `get_best_move`. Use it whenever the test doesn't care about agent quality.

**Patching the save directory** — `unittest.mock.patch.object(persistence, "SAVED_GAMES_DIR", tmpdir)` redirects all saves into a `TemporaryDirectory`. Required for any test that calls `dump`/`load`.

Test files and what they cover:

| File | Covers |
|---|---|
| `test_parser.py` | Command grammar, aliases, validation (rank, undo, eval, save, load, review, drill); `parse_move_input`. |
| `test_dice_parser.py` | Dice input formats, range validation. |
| `test_session_undo.py` | Both `undo` and `undo_to_my_decision`; pin/release, terminal un-end, dice restoration. |
| `test_session_dice_modes.py` | AUTO and MANUAL flows, mixed sequences. |
| `test_persistence.py` | JSON round-trip, replay-from-history, schema-version mismatch. |
| `test_loop.py` | End-to-end scenarios via FakeIO: undo, eval, save/load, post-terminal rejection, no-moves, drill. |
| `test_drill.py` | `_match_move` (non-doubles both colors, ordered die-assignment, merged, doubles walk/hop-start); `_drill_inner` interactive loop; `_collect_blunders` relative-gap detection. |

Run all play tests with `.venv/bin/python -m unittest discover -s tests/ -t .`.

### 16. Extension points

**Add a new command.** Touch four files:

1. [parser.py](parser.py): add a frozen dataclass for the new command. Add a branch (regex or keyword) in `parse_command` that returns it. Watch ordering: when adding aliases, put the longer one first so it doesn't get shadowed by a prefix-match on the shorter alias (e.g. `(?:eval|e)`, not `(?:e|eval)`).
2. [loop.py](loop.py): add an `isinstance(cmd, parser.NewCommand)` branch to whichever handlers should accept it. The five candidates are `_human_turn`, `_dice_prompt`, `_no_moves`, `_post_game`, and (rarely) `_handle_quit`.
3. [renderer.py](renderer.py): if the command needs visible feedback or a new rendered block, add a formatter here.
4. [tests/play/test_parser.py](../tests/play/test_parser.py) and [tests/play/test_loop.py](../tests/play/test_loop.py): cover parsing and at least one end-to-end loop scenario.

**Add a new persisted field.** Bump `SCHEMA_VERSION`, add the field to `SaveFile`, `_serialize_session`, and `PlaySession.from_save`. Update the example in §8 of this doc.

**Change the AI's playing lookahead.** Currently hardcoded at `lookahead_plies=2` in [loop.py::_ai_turn](loop.py). This is intentionally separate from `session.eval_depth` (which is the human-facing rank depth). If you want it user-configurable, add a config key and read it via `session.config.get_…()`.

**Render the board differently.** Everything visible flows through [renderer.py](renderer.py). It depends on `str(board)` for the board grid — to change that, edit `domain/board.py::__str__` (the `GameBoard` class).
