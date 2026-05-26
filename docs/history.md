# How this project came to life

A narrative history of the Plakoto AI, reconstructed from the git log, the code, and the
artifacts left behind (encoder versions, gold checkpoints, abandoned worktrees). It is meant
to be read top-to-bottom to understand *why* the code looks the way it does. For exact
commit-level truth, `git log` is authoritative.

## 1. A rules engine first

The project began as a faithful **Plakoto** rules engine (Greek backgammon, where you *pin*
a lone opponent checker rather than hit it). The domain layer was built object-oriented and
reference-based: a `Point` holds a stack of checkers (`pieces`, bottom→top); pinning is
just an opponent checker trapped at the bottom of your stack. `HalfMove` references the
board's `Point` objects so applying a move mutates the board in place; `Move` is a sequence
of 1–4 half-moves.

Early commits worked through the genuinely tricky bits of legal-move generation: handling
**pasch** (doubles, up to four half-moves), **merged** moves (one checker using both dice),
counting a move from the same point only once, undoing half-moves in the right order, and
deriving move direction from the die rather than hardcoding it. The bear-off "all checkers
home" rule and the Plakoto win conditions (all home, or pinning the opponent's start point)
were settled here.

## 2. Self-play learning (TD)

Next came the learning system: a value network judged board positions, trained by **TD
learning** from self-play. The value head was switched to a **win probability** (sigmoid),
with TD targets to match. Epsilon-greedy exploration, board snapshots in game history, and
extra hidden layers all arrived in this stretch ("fix: implement actual td learning",
"feat: add more hidden layers", "feat: built printing board with and without scores").
A large "change pretty much everything" commit reorganized the project into the
`domain` / `ai` / `game` / `config` shape it still has.

## 3. The encoder lineage (and why there are gold v1–v9)

How the board is fed to the network evolved through three encoder versions, each pinned to a
checkpoint tag so old models still load (`ai/board_encoder.py`):

- **`legacy_unary_v1`** — 2 color bits + 2 captured + unary count per point. Used by
  `gold_v1`–`gold_v4`.
- **`unary_v2`** — slimmer 1 color bit per point. Used by `gold_v5`.
- **`unary_v3`** (current) — `unary_v2` plus **18 hand-crafted "smart" global features**
  (pip counts, blots, held points, pinned counts, home distributions, max prime length,
  borne-off, and pip/borne differentials). Used by current training and `gold_v9`.

The `models/gold_vN.pth` files are frozen reference opponents for benchmarking: higher N =
stronger. Their growing size tells the architecture story — v1–v4 are ~1.7 MB, v5–v7 shrink
(slimmer encoder/net), and `gold_v9` is ~2 MB after the hidden layers grew to
`[256, 128, 64]`. A big squash commit ("TD training, unary_v3 encoder, parallel self-play,
cleanup") consolidated the modern encoder + parallel self-play.

## 4. Modern training loop

The hand-rolled eligibility-trace + SGD updater was replaced with a **replay buffer + Adam**
optimizer running **forward-view TD(λ)** (commit "Replace eligibility traces + SGD with
replay buffer + Adam"). Gold-eval logging, significance tests, and SVG progress charts grew
up around it. Models were brought into git tracking (previously gitignored), and scripts were
added to seed fresh worktrees with the model + training state.

## 5. Playing against it (and drills)

An interactive **human-vs-AI** play UI was added (in `main.py`), then iterated: undo
semantics, manual dice entry, save/load, color choice, then a **post-game blunder review**
and interactive **drill** commands, then hardening of drill move-matching. This is the
current tip of the `hopeful` line of work and the closest analog to what the iPad app does.

## 6. A first (abandoned) Swift attempt

At some point an iPad app was prototyped in a separate worktree (`.claude/worktrees/ui/`):
a `TavliEngine` Swift package, a `TavliApp` SwiftUI app, and a Core ML conversion pipeline.
It was built against an **earlier, reduced game** (a 10-point / 5-piece / 4-sided prototype
config) with the `legacy_unary_v1` encoder, and it became orphaned — disconnected from the
active branches. Its structure was excellent, but its assumptions were stale.

## 7. The on-device port (this branch)

The current effort builds a **fresh, offline, on-device** iPad app for the *current*
24-point game. Decision: re-implement the engine + `unary_v3` encoder in Swift, convert
`gold_v9` to Core ML, and **prove parity** against the Python source of truth before any UI.
Phase 1 achieved exactly that — byte-equivalent encodings, identical legal moves, and
identical 1-ply move choices (see `docs/ios_port_plan.md`). The old Swift worktree served as
a structural reference; the brain it talks to is the live, current network.
