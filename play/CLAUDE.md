# play/ — interactive human-vs-AI loop

`./run.sh play` lets a human play one game of Plakoto against a trained model, with full undo,
save/load, per-move evaluation, and post-game review/drill. This `CLAUDE.md` is the index; the
detail lives in two on-demand docs:

- **[`USAGE.md`](./USAGE.md)** — user reference: invocation, every command and prompt, dice input,
  special flows, config knobs, save-file format, history logging. Read it for *what the UI does*.
- **[`INTERNALS.md`](./INTERNALS.md)** — developer internals: state machine, undo mechanics,
  persistence schema, loop dispatch, testing patterns, extension points. Read it to *modify the code*.

Historical design docs — `docs/play_ui_concept.md` and `docs/play_ui_implementation_plan.md` — are
*not* authoritative; they predate the code. When design and implementation diverge, the code (and
these docs) win.

## Module map

```
play/
├── __init__.py          # empty
├── parser.py            # text → Command dataclass (no state)
├── session.py           # PlaySession + Snapshot; game state machine
├── loop.py              # REPL; dispatch over Command variants
├── renderer.py          # string formatting only
└── persistence.py       # JSON dump/load + path resolution
```

Dependencies flow one way: `loop` uses everything; `session` uses `domain`/`game`; `renderer` reads
`domain`/`session`; `persistence` reads/writes `session`. `parser` and `renderer` are pure.

## Conventions / gotchas

- **Domain v2 types.** Colors are the ints `WHITE`/`BLACK` (`domain.constants`); `Move`/`HalfMove`
  are immutable `NamedTuple`s; the board is `domain.board.Board`. Undo uses `board.apply`/`board.undo`
  tokens captured per ply.
- **Replay-based saves.** A save stores only the move history (dice + half-moves per ply), never the
  board — load replays from the initial position. Saves are tiny and portable across model upgrades.
  Bumping `SCHEMA_VERSION` is deliberately breaking (no migration); document new fields in `USAGE.md` §8.
- **`run.sh play` takes the model path positionally** (`./run.sh play models/gold_v9.pth`), *not*
  `--network` — passing the flag double-wraps and fails. Use `python main.py play` for `--load`.
- **AI play depth ≠ rank depth.** `_ai_turn` uses time-budget iterative-deepening expectimax (knobs
  `play_time_budget_s`/`search_*` in `config/config.yml`), separate from `session.eval_depth` (the
  human-facing ranked-move depth).
- **`renderer.py` is the only place anything visible is formatted** (`format_board` reads the v2
  `Board` arrays directly — independent of `Board.__repr__`).
