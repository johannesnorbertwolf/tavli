# Encoder Throughput Optimization Ideas

Notes on encoder performance strategies. Strategies #1 and #2 are implemented in
`ai/board_encoder.py` (smart features folded into the encode loop, numpy
vectorization). Strategies #3 and #4 are deferred — kept here for the future when
encode time becomes a real bottleneck again.

Context: training throughput is dominated by Python-side encoding plus PyTorch
forward passes. For the current `[128, 64]` MLP the forward is cheap (~10–20µs
on CPU) and a non-trivial fraction of wall time is spent in `encode_board`. The
encoder runs once per ply for the current state plus N times for candidate
afterstates and (with 2-ply lookahead) up to N×21 times for opponent
afterstates. So encoder µs translate fairly directly into games/sec.

Strategies are listed roughly in order of expected payoff vs. implementation cost.

---

## #3 — GPU-resident fixed feature-extraction layer

**Idea.** Move the smart-features computation out of NumPy / Python and into a
fixed (non-trainable) `nn.Module` that runs on the same device as the network.
The CPU-side encoder produces only the raw per-point one-hot/unary tensor; the
GPU module derives pip count, blot count, points held, prime length, race
indicator, home counts, etc. from that tensor.

**Why this could be a win.**
- Once on GPU, every per-batch op is essentially free compared to the
  forward/backward of the trainable layers.
- For 2-ply lookahead, where we already batch ~21 × N afterstates into one
  forward call, a GPU feature module amortizes across that whole batch.
- Eliminates the per-position Python overhead of computing pip/blot/etc., which
  scales linearly with afterstate count.

**Sketch.**
```python
class FixedFeatures(nn.Module):
    def __init__(self, board_size, pieces_per_player):
        super().__init__()
        # precompute index tensors as buffers so they move with .to(device)
        self.register_buffer("home_white_mask", ...)
        self.register_buffer("home_black_mask", ...)
        ...
    def forward(self, raw_per_point):  # [B, num_points, point_size]
        # decode per-point fields with slicing
        ours = raw_per_point[..., 0] == 0
        theirs = raw_per_point[..., 0] == 1
        pip_us = (counts * distance_to_goal_us).sum(dim=1)
        ...
        return torch.cat([raw_flat, pip_us, blot_count, prime_len, ...], dim=1)
```

The trainable network becomes `Sequential(FixedFeatures, BoardEvaluator)` so
checkpoints continue to store only `BoardEvaluator` weights. The encoder
version (e.g. `unary_v4_gpu`) signals that smart features are computed
downstream rather than at encode time.

**When to do this.** When CPU encode time exceeds ~50% of training wall time
and we cannot squeeze more out of NumPy. Probably also a prerequisite for any
GPU training run.

**Risks.**
- Have to re-derive all smart features as differentiable-but-frozen tensor ops;
  any mismatch with the CPU implementation silently corrupts training.
- More complex to debug — the intermediate tensor is no longer a flat NumPy
  array you can `print()`.
- Need a unit test that runs both CPU encoder + CPU feature compute against the
  GPU module on the same boards and asserts numerically identical output.

---

## #4 — Incremental encoder update via caching on `GameBoard`

**Idea.** Make `GameBoard.apply(move)` and `GameBoard.undo(move)` patch a
running encoded representation in place, rather than re-encoding the full
board from scratch on every call. Most plies touch only 2–4 points; a half-move
just decrements one point and increments another, so almost every component of
the encoded vector is unchanged.

**Why this could be a win.**
- Theoretical speedup is enormous: encode work goes from O(num_points) to
  O(half_moves_per_move) ≈ O(2–4). For a 26-point board that's an order of
  magnitude.
- Smart features can also be maintained incrementally:
  - `pip_count` — adjust by `from_index − to_index` per half-move
  - `home_count` — increment/decrement based on whether to/from is in home
  - `blot_count` / `points_held` — recompute only for the from/to points
  - `pinned_*`, `pinning_*` — recompute only at affected points
  - `max_prime` — needs re-scan of the affected color's row, but that's cheap
- Pairs naturally with 2-ply lookahead: the inner loop applies a half-move,
  encodes, undoes — exactly the pattern incremental caching is built for.

**Sketch.**
```python
class GameBoard:
    def __init__(...):
        ...
        self._encoded_white = None  # vector encoded from white's perspective
        self._encoded_black = None  # mirrored
        self._smart_white = None    # dict of running aggregates
        self._smart_black = None

    def apply_half_move(self, hm):
        # 1. mutate pieces as today
        # 2. patch self._encoded_{white,black} at the two affected slots
        # 3. update running smart-feature counters

    def undo_half_move(self, hm):
        # symmetric
```

The encoder becomes a thin wrapper: `BoardEncoder.encode_board(board, is_whites_turn)`
just returns `board._encoded_white` or `board._encoded_black` (lazily
initialized via a full encode on first call).

**When to do this.** After #3, or as a cheaper alternative if we want to stay
CPU-only. Would also drop 2-ply lookahead cost dramatically since the hot loop
becomes `apply → cheap encode → undo`.

**Risks.**
- Tightly couples `GameBoard` to encoder internals — moving from `unary_v3` to
  `unary_v4` means touching board apply/undo code.
- Every smart feature has to be expressed as a delta. Anything that depends on
  global structure (`max_prime`, captured-runs) needs careful incremental
  bookkeeping or a partial re-scan.
- Easy place for bugs that only show up after many moves: any drift between the
  cached vector and a from-scratch encode silently teaches the network garbage.
  Mandatory invariant test: after a random sequence of apply/undo,
  `board._encoded_white` matches `encoder.encode_board(board, True)` exactly.
- `apply` is also called from `find_moves`-style search loops; speed there
  matters too. The cache patch must be cheap (constant work per half-move).

---

## Order of attack if revisited

1. Profile first. Run `cProfile` on a 200-game training segment to confirm
   encode is still the bottleneck and quantify the gain ceiling.
2. Implement #4 (incremental caching) before #3 if we stay CPU-only. The win
   is bigger and the surface area smaller.
3. Implement #3 only if we move training to GPU, or if features grow well
   beyond the current ~40.

Both strategies should land behind a new `encoder_version` tag so existing
gold checkpoints (`legacy_unary_v1`, `unary_v2`, `unary_v3`) keep loading.
