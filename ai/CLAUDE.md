# ai/ — Machine Learning Modules

Module index. **Full per-module detail (APIs, search internals, encoder layouts,
training cycle) is in [`REFERENCE.md`](./REFERENCE.md)** — read it when implementing
or modifying anything here.

| Module | What it is |
|---|---|
| `agent.py` | Inference interface (`Agent`) over evaluator + encoder; 1/2/N-ply expectimax search with branch pruning and time-budget iterative deepening. Never updates weights. Also `RandomAgent`. |
| `board_encoder.py` | `BoardEncoder` → flat float32 vector, always from the current player's perspective (board flip). Three checkpoint-tagged versions; current `unary_v3` (486-dim, +18 smart features). |
| `board_evaluator.py` | `BoardEvaluator` MLP → win prob ∈ [0,1]. `forward` (sigmoid) vs `forward_logits` (raw). |
| `checkpoint_io.py` | Save/load checkpoints (format_version=2, with Adam state). Encoder-version + legacy-layer-name back-compat. |
| `bearoff.py` | Exact race equity: one-sided bear-off database (`BearoffDB`, DP over dice outcomes, disk-cached npz) + exact-race detector (`race_state`) + `exact_value_on_roll`. Replaces net evals and TD targets with ground truth in pure races. |
| `net2net.py` | Function-preserving MLP widening for capacity expansions (`main.py expand-net --to 512,256,128`): duplicate hidden units, rescale downstream columns, small noise to break symmetry. Expanded checkpoints carry no optimizer state. |
| `rollout_lab.py` | Offline disagreement mining + rollout-labeled fine-tuning (#80): mine states where `V_net` and one-roll expectimax disagree, label by race-truncated rollouts, fine-tune with anchor regularization. Gated promotion via `main.py rollout-lab`. |
| `seed_pool.py` | Seeded-start self-play (#83): build a pool of high-residual positions (`main.py seed-pool`); workers start `selfplay_seeded_fraction` of games from sampled pool states instead of the initial board. Coverage lever; values stay on-policy. |
| `td_lambda_training.py` | Training loop (`TdLambdaTraining`), `ReplayBuffer`, `compute_lambda_returns`. Forward-view TD(λ), Adam, parallel self-play workers. |
| `self_play_worker.py` | Worker subprocess: plays self-play games, streams trajectories to the trainer. |
| `evaluator.py` | Older vs-random eval helper (`AIEvaluator`); likely vestigial. |
| `lookahead_eval.py` | Parallel harness: flexible search vs fixed 2-ply (gold self-play) to validate deeper search. |

## Conventions / gotchas

- **Load checkpoints only via `load_agent_from_checkpoint()`** — never construct an `Agent`/evaluator/encoder by hand (it derives `input_size` from the checkpoint's encoder version and `hidden_sizes` from metadata).
- **The training loop owns `.eval()` / `.train()` mode**; `Agent` methods are mode-agnostic.
- **Search width is bounded only by move pruning** (`_prune_branches`: relative cutoff + `max_branch`). The 21 dice chance-nodes are never pruned — the dice distribution stays exact.
- **N-ply search wraps each applied move in `try/finally`** so `_TimeoutError` unwinding never leaks an un-undone move onto the board.
- **Workers set `torch.set_num_threads(1)`** and run in `eval()` mode; they're seeded deterministically from `base_seed`.
- **The bear-off DB is built once and cached** (`models/bearoff_db.npz`, gitignored). The trainer builds it eagerly before spawning workers so workers only load the cache; `load_agent_from_checkpoint()` attaches it automatically when `use_bearoff_db` is true.
