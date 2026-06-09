# Play UI — developer internals

Reimplementation-grade detail for the `play/` package: module layout, session/snapshot state,
undo mechanics, persistence schema, loop dispatch, testing patterns, and extension points.

## 10. Module map

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

## 11. `PlaySession` and `Snapshot`

`PlaySession` ([session.py:30](session.py)) owns all game state and is the only piece tests need to construct.

Fields:

| Field | Type | Notes |
|---|---|---|
| `config` | `ConfigLoader` | Used for `die_sides`, `play.eval_lookahead_plies`. |
| `agent` | object | Anything with `evaluate_moves` and `get_best_move`. May be `None` for headless tests that only exercise the mechanical layer. |
| `ai_checkpoint_path` | `str` | Persisted to saves; surfaced to the user on load. |
| `dice_mode` | `DiceMode` enum | `AUTO` or `MANUAL`. |
| `human_color` | `int` | `WHITE` (+1) or `BLACK` (−1) from `domain.constants`. |
| `eval_depth` | `int` | Sticky session-wide default for `ranked_moves`. |
| `starting_player` | `int` | Always `WHITE` in standard play; settable for tests. |
| `game` | `Game` | Owns the board, dice, and turn pointer. |
| `history` | `list[Snapshot]` | Index 0 is the initial state; each subsequent entry is the state *after* one ply. |
| `_pending_dice` | `tuple[int, int] \| None` | Dice set for the current (not yet committed) ply. Cleared on commit. |
| `last_save_name` | `str \| None` | Last `save <name>` invocation; used as the auto-save target on `load`-while-dirty. |
| `dirty_since_save` | `bool` | Set on every commit; cleared on save and on `from_save`. |

`Snapshot` is a frozen dataclass — once appended it's never mutated:

```python
@dataclass(frozen=True)
class Snapshot:
    next_player: int             # WHITE/BLACK; who plays AFTER this snapshot
    move_played: Move | None     # the move that produced this snapshot (None for index 0)
    dice_for_this_ply: tuple[int, int] | None
    was_pass: bool
    last_move_summary: str       # pre-formatted for history display
    undo_token: list | None      # board.apply() token for undo; runtime-only, not serialized
```

Domain types are from `domain` v2 (array-based): colors are the ints `WHITE`/`BLACK`
(`domain.constants`); `Move`/`HalfMove` are immutable `NamedTuple`s (`Move.halves`,
`HalfMove.src`/`HalfMove.dst`); the board is `domain.board.Board`.

Two constructors:

- `PlaySession.new_game(config, agent, ai_checkpoint_path, dice_mode, human_color, eval_depth)` — fresh session at ply 0.
- `PlaySession.from_save(config, save_file, agent)` — rebuilds a session by replaying every ply from `save_file.history` into a fresh game. After replay, `dirty_since_save` is cleared.

## 12. Undo mechanics

Two layers, both live on `PlaySession`:

**`undo(n=1)`** — the mechanical primitive. Pops `n` plies. For each popped snapshot, calls `board.undo(snap.undo_token)` (the token captured at `commit_move` time; `None` for passes). Then restores dice: in AUTO mode, the *last popped* snapshot's `dice_for_this_ply` is reinstated; in MANUAL mode, `_pending_dice` is cleared. Used internally by `from_save`, by the post-game un-end-game flow, and by tests.

**`undo_to_my_decision(n=1)`** — the user-facing semantic. Each step walks history backwards to find the most recent snapshot where `next_player == human_color` (excluding the current top), then pops down to it. If no such snapshot exists (e.g. human is Black and AI just opened), returns 0 plies popped. This is what every user-typed `u` in the loop calls.

The split exists because:
- Tests want fine-grained "pop exactly one ply" behavior to verify the board/dice restoration mechanics.
- `from_save` needs to be able to replay without "decision point" semantics.
- Users want `u` to mean "let me re-decide" — which is always at least 2 plies (your move + the AI's response).

Source: [session.py::undo](session.py), [session.py::undo_to_my_decision](session.py).

## 13. Persistence schema

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

Each `history` entry: `{"dice": [d1, d2], "move": [[src, dst], ...] | None, "was_pass": bool}`. Positions are board indices: `1..board_size` are playable points, `0` is Black's bear-off slot and `board_size+1` (25) is White's bear-off slot.

**Bumping the schema** is intentionally breaking: there's no migration code. If you change the shape, increment `SCHEMA_VERSION` and document the new fields here. Old saves raise `IncompatibleSave` on load.

Two named exceptions:

- `MissingCheckpoint(FileNotFoundError)` — raised by `agent_loader` when `ai_checkpoint_path` doesn't exist. The loop catches it and prompts for a replacement.
- `IncompatibleSave(ValueError)` — raised on schema mismatch.

Path resolution: `resolve_path(name)` appends `.json` if absent and joins against `SAVED_GAMES_DIR`. `autosave_name()` returns `autosave_YYYYMMDD_HHMMSS` using `datetime.now()` by default; tests can pass a fixed `datetime` for determinism.

## 14. Loop dispatch

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
| `_ai_turn` | AI's turn, dice set | Calls `agent.get_best_move(time_budget_s=…, relative_cutoff=…, max_branch=…, max_depth=…)` (iterative-deepening search, knobs from `session.config`) and commits. This is separate from `session.eval_depth` (the human-facing rank depth). |
| `_post_game` | `session.is_terminal()` | Restricted command set: `u`, `h`, `review`, `drill`, `save`, `q`, `?`. |

`Action(kind, session=None)` carries the dispatch result back to `run`:

- `kind="advance"` — handler did something; loop back to the top.
- `kind="quit"` — user confirmed quit; `run` returns the current session.
- `kind="dice_set"` — `_dice_prompt` got dice; loop back (other handlers don't use this).
- `kind="continue"` — handler wants another iteration in the same state (unused today; reserved).

When `_human_turn` or `_dice_prompt` processes a successful `load`, it returns `Action("advance", session=<new>)` and `run` swaps the working session before the next iteration.

`agent_loader: Callable[[str], object]` is injected, not imported. The loop calls it only when `load` needs to instantiate an agent for a different checkpoint. `main.py::play_against_ai` wires it to `load_agent_from_checkpoint`. Tests pass a lambda that returns a `StubAgent`.

## 15. Testing patterns

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

## 16. Extension points

**Add a new command.** Touch four files:

1. [parser.py](parser.py): add a frozen dataclass for the new command. Add a branch (regex or keyword) in `parse_command` that returns it. Watch ordering: when adding aliases, put the longer one first so it doesn't get shadowed by a prefix-match on the shorter alias (e.g. `(?:eval|e)`, not `(?:e|eval)`).
2. [loop.py](loop.py): add an `isinstance(cmd, parser.NewCommand)` branch to whichever handlers should accept it. The five candidates are `_human_turn`, `_dice_prompt`, `_no_moves`, `_post_game`, and (rarely) `_handle_quit`.
3. [renderer.py](renderer.py): if the command needs visible feedback or a new rendered block, add a formatter here.
4. [tests/play/test_parser.py](../tests/play/test_parser.py) and [tests/play/test_loop.py](../tests/play/test_loop.py): cover parsing and at least one end-to-end loop scenario.

**Add a new persisted field.** Bump `SCHEMA_VERSION`, add the field to `SaveFile`, `_serialize_session`, and `PlaySession.from_save`. Update the save-file-format documentation accordingly.

**Change the AI's playing lookahead.** The AI uses time-budget iterative-deepening expectimax: [loop.py::_ai_turn](loop.py) calls `get_best_move(time_budget_s=…, relative_cutoff=…, max_branch=…, max_depth=…)` with the knobs from `session.config` (`play_time_budget_s`, `search_relative_cutoff`, `search_max_branch`, `search_max_depth`). Tune those keys in `config/config.yml`. This is intentionally separate from `session.eval_depth` (the human-facing rank depth, still 2-ply under the hood — see `Agent.evaluate_moves`).

**Render the board differently.** Everything visible flows through [renderer.py](renderer.py). The board grid is produced by `renderer.format_board(board)` — a play-UI-local renderer that reads the v2 `Board`'s `n[]`/`color[]`/`pinned[]` arrays and reproduces the classic glyph layout (`O`/`X`, separators). This is deliberately independent of `domain.board.Board.__repr__` (the array-style debug dump), so changing the play display means editing `format_board`, not the domain.
