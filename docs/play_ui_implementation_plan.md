# Play-vs-AI UI — Implementation Plan (Draft 1)

Status: **plan for review** — no code yet. Companion to
[play_ui_concept.md](play_ui_concept.md). All 12 design decisions
there are taken as given. This document is purely about *how* and *in
what order* to land the change.

## 0. Reading order

1. The concept doc fixes *what*.
2. This plan fixes *where* and *in what order*.
3. After review, code lands in small PRs that map to the sections of
   §6 below.

## 1. Target end-state at a glance

A new module owns the play loop:

```
main.py
  └─ play_against_ai(config, …)        # thin entry point: parse args,
                                       # construct PlaySession, run it.

play/
  __init__.py
  session.py                           # PlaySession, Snapshot, dice modes
  loop.py                              # interactive REPL — prompts, dispatch
  parser.py                            # input → Command dataclass(es)
  renderer.py                          # header / footer / board+moves block
  persistence.py                       # JSON save/load + autosave naming
```

Why a new package: `main.py` is already 800+ lines of mixed concerns
(training, eval, graphs, logging, play). Carving play out cleanly is
the only way the new loop stays reviewable. Nothing outside `play/`
needs to change in behavior, only call sites.

## 2. Domain touch-ups (small, contained)

Two tiny changes outside `play/`. Both are *additions* — no behavior
changes for training/eval.

### 2.1 [domain/dice.py](../domain/dice.py)

Add a way to set dice values without rolling:

```text
Dice.set(die1_value: int, die2_value: int) -> None
```

Validates `1 <= v <= number_of_sides` and raises `ValueError` on
out-of-range. Used by `PlaySession` in manual mode and by the
snapshot-restore path (so an undo can re-present the same roll).

Currently the manual workaround is `dice.die1.value = …` (see
[ai/agent.py:87](../ai/agent.py:87)) — that's a code smell we're
inheriting. The new method gives us a single validated entry point;
the agent's internal hot-path keeps its raw assignments to stay fast.

### 2.2 [game/game.py](../game/game.py)

No code change required for v1. The session passes
`starting_player=Color.WHITE` to `Game(config, starting_player=…)`
when constructing a fresh game (the API already supports it — see
[game/game.py:8](../game/game.py:8)).

**Behavior note worth surfacing in the PR description:** the *current*
`play_against_ai` constructs `Game(config)` which defaults to
`Color.BLACK` starting. The concept doc fixes White-starts as the
convention. This is a tiny but visible change to anyone who plays
both before and after.

## 3. The `play/` package

### 3.1 `play/session.py`

Two dataclasses and one orchestrator:

```text
@dataclass(frozen=True)
class Snapshot:
    board_state:        SerializableBoard   # see §3.1.1
    next_player:        Color
    pending_dice:       Optional[tuple[int, int]]   # roll for next ply if already entered
    last_move_summary:  str                          # rendered for `history`
    ply_index:          int                          # 0 = initial; n = after n committed plies
    was_pass:           bool                         # forced no-moves ply

class DiceMode(Enum):
    AUTO = "auto"
    MANUAL = "manual"

class HumanColor(Enum):
    WHITE = "w"
    BLACK = "b"
    RANDOM = "r"          # only valid pre-resolution; resolved at session-start

class PlaySession:
    history:              list[Snapshot]
    game:                 Game
    agent:                Agent
    ai_checkpoint_path:   str
    dice_mode:            DiceMode
    human_color:          Color                    # resolved (never RANDOM)
    eval_depth:           int                      # session eval depth (default 4)
    last_save_name:       Optional[str]            # drives auto-save-on-load
    dirty_since_save:     bool

    # Construction
    @classmethod
    def new_game(cls, config, agent, ai_checkpoint_path, dice_mode, human_color, eval_depth) -> "PlaySession": ...
    @classmethod
    def from_save(cls, config, save_path, agent_resolver) -> "PlaySession":
        # agent_resolver: callable(checkpoint_path) -> (Agent, resolved_path).
        # Called only if the saved checkpoint is missing on disk.
        ...

    # Core ply lifecycle
    def current_player(self) -> Color
    def current_dice(self) -> Optional[tuple[int, int]]    # None until obtained for the upcoming ply
    def set_dice(self, d1: int, d2: int) -> None           # manual-mode entry
    def roll_dice(self) -> tuple[int, int]                 # auto-mode entry
    def possible_moves(self) -> list[Move]
    def ranked_moves(self, depth: Optional[int]) -> list[tuple[Move, float]]
    def commit_move(self, move: Move) -> None              # applies + snapshots + advances turn
    def commit_pass(self) -> None                          # records a no-moves ply
    def undo(self, n: int = 1) -> int                      # returns plies actually popped
    def is_terminal(self) -> bool
    def winner(self) -> Optional[Color]
    def history_lines(self) -> list[str]                   # for `history` command
```

Invariants:

- After `commit_move` / `commit_pass`, `history` has exactly one more
  entry than before, `dirty_since_save = True`, and `pending_dice` is
  cleared.
- `undo` is symmetric: pops snapshots, rebuilds `game.board` and
  `game.player` from the previous snapshot, restores `pending_dice`
  so the same roll is re-presented. (Manual mode: the dice were
  entered *after* undo, so undoing returns to the dice prompt with
  no pending roll — matches concept §3.5.)
- `from_save` replays history from the initial position to
  reconstruct boards; the JSON file does *not* store per-ply board
  state (concept §5.2).

#### 3.1.1 Board snapshot strategy

Two viable approaches; we'll use approach B.

**Approach A — deep-copy.** `Snapshot.board_state = copy.deepcopy(board)`.
Simple, slow per-snapshot but irrelevant at human speeds. Easy to
restore.

**Approach B — apply/undo on a single live board** (recommended).
Store only `(serialized_move_or_None, dice_for_this_ply)`. Undo
calls `board.undo(move)` (already exists, used in training —
[ai/agent.py:53](../ai/agent.py:53)). The full history is rebuildable
either by forward replay (load path) or by `undo` from the live
state (interactive undo path).

Approach B is chosen because:

- Lines up with the JSON file format (history of moves, not history
  of boards).
- The `apply` / `undo` invariant is already exercised by training and
  by the 2-ply evaluator, so it's well-tested.
- Smaller in-memory footprint (no copy.deepcopy per ply).
- No new code path is created — same code that already handles undo
  is what we lean on.

A `Snapshot` therefore stores:

```text
move_played:        Optional[SerializableMove]   # None on the initial snapshot or a pass
dice_for_this_ply:  Optional[tuple[int, int]]    # the dice that produced move_played
was_pass:           bool
next_player:        Color                        # whose turn it becomes AFTER this ply
pending_dice:       Optional[tuple[int, int]]    # if the user already entered dice
                                                 # for the upcoming turn before
                                                 # quitting/saving; usually None
last_move_summary:  str
```

`SerializableMove` is just `list[tuple[int, int]]` — `(from_pos,
to_pos)` per half-move. Color is recoverable from `dice_for_this_ply`'s
matching player turn at replay time.

### 3.2 `play/parser.py`

Pure function, no I/O:

```text
parse_command(line: str) -> Command   # Command is a tagged union dataclass
```

`Command` variants:

- `PlayMove(rank: int)`        — `"1"`..`"N"`
- `Undo(n: int)`               — `"u"`, `"undo"`, `"u 3"`, `"undo 3"`
- `History`                    — `"h"`, `"history"`
- `Eval(depth: Optional[int])` — `"e"`, `"eval"`, `"eval 5"`
- `Save(name: str)`            — `"save foo"`, `"save foo.json"`
- `Load(name: str)`            — `"load foo"`
- `Help`                       — `"?"`, `"help"`
- `Quit`                       — `"q"`, `"quit"`
- `Unparseable(reason: str)`   — anything else, with a human-readable cause

Dice-entry mode is *separate*: the dice prompt uses
`parse_dice(line: str) -> tuple[int, int]` which accepts `"5 2"`,
`"52"`, `"5,2"`, etc. (concept §3.4). Mismatches raise
`InvalidDiceInput`. The dice prompt does **not** accept commands
like `undo` (concept §3.5 says undo at the dice prompt is achieved
by undoing the previously committed move, but practical UX is that
the dice prompt has its own short menu — see §4.3 below).

### 3.3 `play/renderer.py`

Three functions; reuse the existing
[main.py:270 `print_board_with_moves`](../main.py:270) almost verbatim:

```text
render_header(session) -> str          # "Ply 7 — White to move — dice 5 2"
render_footer(session) -> str          # "[1-N] play   u undo   h history   e eval   save <n>   q quit"
render_ply_block(session, ranked_moves) -> str
                                       # composed: header + board+moves columns + footer
render_history(session) -> str         # ply-by-ply listing
render_ai_played(session, move, score) -> str  # AI auto-advance block
```

`print_board_with_moves` becomes a delegate of `render_ply_block`.
The existing function is moved into `play/renderer.py` and the call
site in `main.py` is replaced with an import.

### 3.4 `play/persistence.py`

```text
SAVED_GAMES_DIR = "saved_games"        # repo-root sibling of models/, training_runs/
SCHEMA_VERSION  = 1

def _resolve_path(name: str) -> Path   # appends .json, joins under SAVED_GAMES_DIR
def _autosave_name() -> str            # "autosave_YYYYMMDD_HHMMSS"
def dump(session: PlaySession, name: str) -> Path    # writes JSON, returns path
def load(path: Path) -> SaveFile                     # returns dataclass, no Agent yet
def overwrite_check(name: str) -> bool               # caller uses to prompt
```

JSON shape (concept §5.2):

```json
{
  "schema_version": 1,
  "encoder_version": "unary_v3",
  "ai_checkpoint_path": "trained_model.pth",
  "dice_mode": "manual",
  "human_color": "w",
  "eval_depth": 4,
  "starting_player": "white",
  "history": [
    {"dice": [3, 5], "move": [[1, 4], [1, 6]], "was_pass": false},
    {"dice": [6, 2], "move": null, "was_pass": true},
    ...
  ]
}
```

Notes:

- `encoder_version` is stored but not consulted on load (the agent
  resolver handles checkpoint loading). It's purely informational for
  debugging stale saves.
- `move: null, was_pass: true` is the only legal pass shape.
- Board state is **not** stored. Replay is the only restore path.
- `_autosave_name()` uses `datetime.now().strftime("%Y%m%d_%H%M%S")`
  — collision risk is negligible at human input speed; if two saves
  happen in the same second, append `_2`, `_3`.

`load` returns a `SaveFile` dataclass; turning a `SaveFile` into a
`PlaySession` is `PlaySession.from_save(save_file, agent_resolver)`,
because session construction requires the loaded `Agent` and that
involves I/O the persistence module shouldn't own.

### 3.5 `play/loop.py`

The interactive REPL. Top-level entry:

```text
def run(session: PlaySession, io: IO) -> None
```

`IO` is a small protocol with `input(prompt) -> str` and
`output(msg) -> None`. The real implementation uses `builtins.input`
and `print`. The protocol exists *only* to make the loop unit-testable
without monkey-patching stdin/stdout.

Control flow per iteration (concept §4):

```text
while True:
    if session.is_terminal():
        post_game_prompt(session, io)        # only u/h/save/q allowed
        if user chose quit: return
        if user chose undo: fall through to top of loop with un-ended state
        else: re-print and loop

    if not session.has_dice_for_current_ply():
        if dice_mode is AUTO: session.roll_dice()
        else:                 prompt_for_dice(session, io)

    moves = session.possible_moves()
    if not moves:
        render_no_moves(io, session)
        ack = io.input("[enter] pass   u undo : ")
        if ack starts with "u": session.undo(parse_n(ack)); continue
        session.commit_pass()
        continue

    player = session.current_player()
    if player == session.human_color:
        ranked = session.ranked_moves(depth=None)        # play-time depth
        io.output(render_ply_block(session, ranked))
        cmd = parse_command(io.input("> "))
        dispatch(cmd, session, io, ranked)
    else:
        # AI
        move, score = session.agent.get_best_move(..., lookahead_plies=2)
        io.output(render_ai_played(session, move, score))
        session.commit_move(move)
```

`dispatch` is a `match` on the `Command` variant. It either mutates
the session (`commit_move`, `undo`) or performs a side-effect that
leaves the loop body to re-iterate without advancing (`eval`,
`history`, `help`, `save`, `load`, unparseable input).

Special cases worth calling out:

- **Quit-with-dirty:** `Quit` first checks `session.dirty_since_save`.
  If dirty, prompt `"Unsaved progress. q to discard, save <name>, c to cancel"`
  and dispatch the sub-input.
- **Load-with-dirty:** auto-save first (concept §5.2 auto-save sub-section).
  Loop prints exactly the auto-save path.
- **Save overwrite:** if the target file exists, prompt
  `"<name> exists. Overwrite? [y/N]"`. Cancel returns to the move prompt.
- **Unparseable input:** print the footer help line and re-prompt
  *without* advancing the loop (concept §5, "a typo never costs a ply").
- **AI checkpoint missing on load:** if `from_save` raises
  `MissingCheckpoint`, the loop catches it, prompts the user for a
  replacement path (or `c` to cancel the load), and retries.

### 3.6 Main entry point — [main.py](../main.py)

Replace the body of `play_against_ai` (currently lines 546–605). The
new body is roughly:

```text
def play_against_ai(config, model_load_path="trained_model.pth", load_name=None):
    device = torch.device("cpu")

    if load_name is not None:
        save_file = persistence.load(persistence._resolve_path(load_name))
        agent = resolve_agent(save_file.ai_checkpoint_path, config, device)
        session = PlaySession.from_save(config, save_file, agent)
    else:
        agent = _try_load_candidate_agent(config, model_load_path, device)
        if agent is None:
            print("Please train the AI first.")
            return
        human_color = prompt_human_color()
        dice_mode   = prompt_dice_mode()
        eval_depth  = config.get_play_eval_lookahead_plies()    # default 4
        session = PlaySession.new_game(
            config, agent, model_load_path, dice_mode, human_color, eval_depth,
        )

    loop.run(session, io=StdIO())

    # Post-game logging — keep _log_human_game / _print_human_record.
    if session.is_terminal():
        winner = session.winner()
        human_won = (winner == session.human_color)
        _log_human_game(model_load_path, "win" if human_won else "loss")
        _print_human_record()
```

CLI parsing in `main()` gains one option:

```text
./run.sh play [--network PATH] [--load NAME]
```

The existing positional fallback (`./run.sh play <path>`) is kept
for backwards compatibility.

### 3.7 [config/config_loader.py](../config/config_loader.py)

Add one accessor:

```text
def get_play_eval_lookahead_plies(self):
    return int(self.config.get("play", {}).get("eval_lookahead_plies", 4))
```

This is the only new config key in v1. Default = 4 (concept §5.1).

## 4. UX details — pinned-down specifics

These are micro-decisions that follow from the concept but aren't
spelled out at the keystroke level. They are documented here so the
review can lock them in before code lands.

### 4.1 Session-start prompts

If `--load` is not given, prompt sequence on stdin:

```
Pick your color [w/b/r] (default w): _
Dice mode [auto/manual] (default auto): _
```

Both accept the unambiguous prefix and default on empty input. The AI
checkpoint comes from `--network` / positional / `trained_model.pth`
(unchanged).

### 4.2 Footer command line

Exact string per concept §6:

```
[1-N] play   u undo   h history   e eval   save <n>   q quit
```

`load <n>` and `help` (`?`) are valid but omitted from the footer to
keep the line short. `help` reveals them.

### 4.3 Dice-entry prompt commands

At the dice prompt in manual mode, the only commands accepted are:

- a parseable dice spec (`"5 2"`, `"52"`, etc.) — sets dice for the
  upcoming ply
- `u` / `undo [N]` — undoes prior committed plies (returns to the
  most recent dice prompt or move prompt as appropriate)
- `q` / `quit` (with dirty-check), `save <n>`, `load <n>`,
  `h` / `history`, `?` / `help`

`eval` is **not** accepted before dice are entered (nothing to
evaluate yet).

### 4.4 Post-terminal prompt

```
Game over. White wins.
[u/undo, h/history, save <n>, q] > _
```

Only those four commands accepted (concept §4). `undo` resurrects the
game; everything else is read-only or exits. `load` is *not* offered
post-terminal (rationale: a terminal session is a finished record;
loading mid-stream confuses the win-log). The user can `q` and re-run
with `--load`.

### 4.5 `history` output

One line per committed ply:

```
1.  W  d=3 5  1->4, 1->6
2.  B  d=6 2  24->22, 24->18
3.  W  d=6 6  (pass)
...
```

Pip-style move notation is out of scope; we use the existing
`HalfMove.__str__` (e.g. `1->4`) — concept §6 says "minimal display
changes" and the move format already lives in the codebase.

## 5. Test plan

All tests `unittest`-based, sit under `tests/play/`. Use
`config-test.yml`.

### 5.1 `tests/play/test_parser.py`

- Each command variant parses correctly (every alias).
- `"u 3"`, `"undo 3"`, `"u3"` all produce `Undo(3)`.
- `"eval"` → `Eval(None)`; `"eval 5"` → `Eval(5)`; `"eval x"` →
  `Unparseable`.
- `"save foo"` → `Save("foo")`; `"save"` (no arg) → `Unparseable`.
- Whitespace/case insensitivity for command verbs; rank inputs
  (`"1"`, `"01"`, `" 2 "`) parse correctly.
- Garbage (`""`, `"asdf"`, `"7x"`) → `Unparseable` with a non-empty
  reason.

### 5.2 `tests/play/test_dice_parser.py`

- `"5 2"`, `"5,2"`, `"5-2"`, `"52"`, `"5  2"` all → `(5, 2)`.
- `"66"` → `(6, 6)` (doubles).
- `"77"` (out of range), `"5"` (single digit), `"abc"`, `""` →
  `InvalidDiceInput`.
- `"0 3"` → `InvalidDiceInput` (lower bound).

### 5.3 `tests/play/test_session_undo.py`

- New session has `len(history) == 1` (initial snapshot).
- `commit_move` then `undo` restores the board state byte-for-byte.
- `undo` at ply 0 is a no-op and returns 0.
- `undo 3` after 2 plies pops 2 (returns the number actually popped).
- `commit_pass` followed by `undo` is symmetric.
- `undo` from a terminal state un-ends the game (`is_terminal()`
  flips false).
- Manual-mode: `commit_move`, then `undo` clears the dice — next
  iteration will re-prompt for dice.

### 5.4 `tests/play/test_session_dice_modes.py`

- AUTO mode: `roll_dice()` populates dice, `commit_move` clears them,
  next ply rolls again.
- MANUAL mode: `set_dice(5,2)` populates dice; `set_dice(7,2)` raises
  `ValueError`.
- Mixed sequences (commit + undo + re-enter different dice) preserve
  the snapshot/dice invariant.

### 5.5 `tests/play/test_persistence.py`

- Dump → load round-trip preserves: dice_mode, human_color,
  eval_depth, ai_checkpoint_path, full move history (board states
  reconstructed by replay match the original).
- `.json` extension is appended when omitted.
- Loading a missing checkpoint raises `MissingCheckpoint` with the
  saved path in the message.
- Loading an unknown schema_version raises `IncompatibleSave`.
- Autosave name uses the timestamp pattern and lands under
  `saved_games/`.

### 5.6 `tests/play/test_loop.py`

Drive `loop.run` against a fake `IO` that yields scripted inputs and
captures outputs. Each test asserts on:
- which sub-prompts the user saw, and
- the final session state.

Scripted scenarios:

- Play one move and quit.
- Type a malformed command, then a valid one — confirm the typo
  didn't advance the ply.
- `undo` after a move puts the user back at the same prompt with the
  same dice.
- `eval 5` reprints the ranked list and updates `session.eval_depth`;
  bare `eval` afterward uses 5.
- `save foo` then `load foo` round-trips inside one session.
- `load other` while dirty triggers auto-save and prints the
  destination path.
- Post-terminal: typing `1` is rejected; `u` works and the loop
  resumes.
- No-moves: the loop emits the single-key prompt, accepts `<enter>`
  (records pass), and `undo` after pass is symmetric.

### 5.7 Existing tests

No existing tests need to change. The new `Dice.set` method is
additive. The `Game(starting_player=Color.WHITE)` switch is local to
the new `PlaySession` factory and doesn't touch `tests/domain/test_game.py`
defaults.

## 6. Landing order (PR-by-PR)

Each step is independently shippable and reviewable.

1. **Plumbing-only PR.**
   - Add `Dice.set(...)`.
   - Add `play/` package skeleton with empty modules and `__init__.py`.
   - Add `get_play_eval_lookahead_plies` to config loader.
   - Move `print_board_with_moves` from `main.py` into `play/renderer.py`,
     re-export so the existing call site keeps working.
   - Tests: `test_dice.py` gains a `set` test.

2. **Parser + dice-parser PR.**
   - Implement `play/parser.py` and dice parser.
   - Tests 5.1 + 5.2.

3. **Session (no I/O) PR.**
   - Implement `PlaySession` and `Snapshot`, with auto+manual dice and
     undo, no save/load yet.
   - Tests 5.3 + 5.4.

4. **Persistence PR.**
   - Implement `play/persistence.py` and `PlaySession.from_save` /
     `dump`.
   - Tests 5.5.

5. **Loop + main wiring PR.**
   - Implement `play/loop.py` and rewrite `play_against_ai`.
   - Add `--load` CLI option.
   - Tests 5.6.
   - Manual smoke test: `./run.sh play`, play 2 plies, undo, quit;
     `./run.sh play --load smoke` after a `save smoke`.

6. **Polish PR (optional).**
   - History line formatter improvements if needed.
   - Any small UX tweaks that surface during 5's manual smoke test.

## 7. Risks and edge cases worth flagging

- **Apply/undo round-trip correctness.** Approach B in §3.1.1 leans
  on `GameBoard.undo` being a perfect inverse of `apply`. The
  training loop and the 2-ply evaluator already do this thousands of
  times per game, so it's well-exercised. Still, snapshot tests
  (5.3) re-check it explicitly for the play path.

- **Pin / capture semantics in undo.** `GameBoard.apply_half_move`
  handles pinning implicitly via `Point.push`; `undo_half_move`
  reverses by `pop`+`push`. The training code's `2-ply` evaluator
  ([ai/agent.py:97–100](../ai/agent.py:97)) already round-trips
  capture-prone positions. No new logic needed, but the undo tests
  in 5.3 should include at least one pin and one re-release.

- **`encoder_version` drift in old saves.** A save file written
  pre-`unary_v3` would load fine *for replay*, but its
  `ai_checkpoint_path` may have been re-trained with a different
  encoder. We rely on `load_agent_from_checkpoint` to read the
  checkpoint's own encoder metadata — concept doc accepts this
  (§5.2 "AI checkpoint mismatch on load"). No special handling
  beyond surfacing the error.

- **White-starts behavior change.** Existing players will notice that
  the AI no longer always plays first when they're White. Call this
  out in the PR description / CHANGELOG.

- **Autosave file accumulation.** `saved_games/autosave_*.json` will
  pile up if the user frequently loads while dirty. No cleanup in v1
  — the user can `rm` them. Document this in the v1 release note.

## 8. Out of scope (deferred — for the record)

These showed up while drafting and are intentionally *not* in v1:

- Periodic auto-save (`play.autosave_every_n_plies`).
- Pip-style or Backgammon-Match-style move notation.
- Multi-game match score.
- Redo.
- `swap` mid-game color change.
- A `list-saves` / `delete-save` CLI command. (User does `ls`/`rm`.)

---

**Next step on your word:** start landing PR 1 from §6. No code will
be written until you sign off on this plan.
