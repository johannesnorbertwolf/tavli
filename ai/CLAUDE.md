# ai/ — Machine Learning Modules

Module index. **Full per-module detail (APIs, search internals, encoder layouts,
training cycle) is in [`REFERENCE.md`](./REFERENCE.md)** — read it when implementing
or modifying anything here.

| Module | What it is |
|---|---|
| `agent.py` | Inference interface (`Agent`) over evaluator + encoder; 1/2/N-ply expectimax search with branch pruning and time-budget iterative deepening; `roll_values` (per-roll 1-ply best-move values). Never updates weights. Also `RandomAgent`. |
| `board_encoder.py` | `BoardEncoder` → flat float32 vector, always from the current player's perspective (board flip). Three checkpoint-tagged versions; current `unary_v3` (486-dim, +18 smart features). |
| `portes_encoder.py` | `PortesEncoder` (`portes_v1`, 414 floats) for the Portes variant: mover-perspective points (owner bit + 15 unary), bars, borne-off, 18 smart features. |
| `plakoto_std_encoder.py` | `PlakotoStdEncoder` (`plakoto_std_v1`, 494-dim) for `plakoto_standard`: the unchanged `unary_v3` vector + 8 mother/start/borne-off features. |
| `fevga_encoder.py` | `FevgaEncoder` (`fevga_v1`, 406-dim) for Fevga, in the mover's path coordinates (colour swap = rotation by 12; a position and its colour-swapped twin encode identically). |
| `board_evaluator.py` | `BoardEvaluator` MLP → win prob ∈ [0,1]. `forward` (sigmoid) vs `forward_logits` (raw). |
| `checkpoint_io.py` | Save/load checkpoints (format_version=2, with Adam state, `variant` tag). Encoder-version + legacy-layer-name back-compat; `check_checkpoint_variant` / `VariantMismatchError`. |
| `bearoff.py` | Exact race equity: one-sided bear-off database (`BearoffDB`, DP over dice outcomes, disk-cached npz) + exact-race detector (`race_state`) + `exact_value_on_roll`. Replaces net evals and TD targets with ground truth in pure races. |
| `net2net.py` | Function-preserving MLP widening for capacity expansions (`main.py expand-net --to 512,256,128`): duplicate hidden units, rescale downstream columns, small noise to break symmetry. Expanded checkpoints carry no optimizer state. |
| `rollout_lab.py` | Offline disagreement mining + rollout-labeled fine-tuning (#80): mine states where `V_net` and one-roll expectimax disagree, label by race-truncated rollouts, fine-tune with anchor regularization. Gated promotion via `main.py rollout-lab`. |
| `seed_pool.py` | Seeded-start self-play (#83): build a pool of high-residual positions (`main.py seed-pool`); workers start `selfplay_seeded_fraction` of games from sampled pool states instead of the initial board. Coverage lever; values stay on-policy. |
| `td_lambda_training.py` | Training loop (`TdLambdaTraining`), `ReplayBuffer`, `compute_lambda_returns`. Forward-view TD(λ), Adam, parallel self-play workers. |
| `self_play_worker.py` | Worker subprocess: plays self-play games, streams trajectories to the trainer. |
| `evaluator.py` | Older vs-random eval helper (`AIEvaluator`); likely vestigial. |
| `lookahead_eval.py` | Parallel harness: flexible search vs fixed 2-ply (gold self-play) to validate deeper search. |
| `paired_eval.py` | Variance-reduced head-to-head (`main.py eval-paired A B [pairs]`): plays each trial twice on the SAME seeded dice (A-White-vs-B and B-White-vs-A), cancelling dice luck + first-mover edge. Paired one-sided z-test on `d_k∈{-1,0,+1}`; far more power per game for near-identical models. Self-comparison ⇒ all `d_k=0`. |
| `handicap_sweep.py` | Handicap exploration harness (#148, `main.py handicap-sweep`): gold-vs-gold 1-ply pairs on duplicate uniform dice under `domain/handicap.py` rules (handicapped side White then Black), per-pair CI, JSON + markdown table. Bear-off DB off only for geometry cells. Tier 1: `weighted_dice` (agent-valued roll tilt on the same uniforms), `rerolls` (policy `wants_reroll`, per-colour reroll stream), `start_estimate` net column for position cells; E1 runner `scripts/run_e1_tier1.sh`. Results: `docs/handicap-phase1.md`. |
| `plateau_driver.py` | Unattended train-until-plateau driver (`main.py plateau` / `plateau-status`): rounds of train subprocess + paired eval vs a self-built ladder `models/<variant>_gold_vK.pth` (bootstraps v1 vs random), promotes on z≥2 & ≥52% (normalized **points** for `max_points > 1` variants, wins otherwise), stops when the pooled non-promotion streak's edge UCB < +1.5pp; staged config overrides; resumable JSON state. |

## Conventions / gotchas

- **Never hard-import `domain.move_generation.legal_moves` / `Board.initial` / `BoardEncoder(...)` in shared code** — go through the variant `RuleSet` (`config.get_ruleset()`, `game.ruleset`, `agent.ruleset`; see `domain/CLAUDE.md`). Gate bear-off DB use on `ruleset.supports_bearoff_db`. Checkpoints carry `variant` (missing ⇒ plakoto); loading one under a config of another variant raises `VariantMismatchError`.
- **Game end goes through the RuleSet outcome seam** (`ruleset.is_over / outcome / terminal_value`, `domain/CLAUDE.md`): TD terminal targets and winning search leaves use `terminal_value` (normalized points), trajectories carry `terminal_value_white` + `result_points`, eval reports win rate (draw = ½) plus avg points/game when `max_points > 1`. Starters come from `ruleset.starting_player(default)` (never touches the rng for Plakoto). Aux heads / `win_by_pin` stay Plakoto-only.
- **Load checkpoints only via `load_agent_from_checkpoint()`** — never construct an `Agent`/evaluator/encoder by hand (it derives `input_size` from the checkpoint's encoder version and `hidden_sizes` from metadata).
- **The training loop owns `.eval()` / `.train()` mode**; `Agent` methods are mode-agnostic.
- **Search width is bounded only by move pruning** (`_prune_branches`: relative cutoff + `max_branch`). The 21 dice chance-nodes are never pruned — the dice distribution stays exact.
- **N-ply search wraps each applied move in `try/finally`** so `_TimeoutError` unwinding never leaks an un-undone move onto the board.
- **Workers set `torch.set_num_threads(1)`** and run in `eval()` mode; they're seeded deterministically from `base_seed`.
- **The bear-off DB is built once and cached in a machine-global location** shared across all git worktrees (default `~/.cache/tavli/bearoff_db_h6_c15_v1.npz`; overridable via `$TAVLI_BEAROFF_DB` or an explicit `bearoff_db_path` in config). Its contents depend only on the game rules, not the branch/code/model — so a new worktree reuses the cache instead of rebuilding the ~54k-state DP. The trainer builds it eagerly before spawning workers so workers only load the cache; `load_agent_from_checkpoint()` attaches it automatically when `use_bearoff_db` is true. Path resolution lives in `ConfigLoader.get_bearoff_db_path()`.
