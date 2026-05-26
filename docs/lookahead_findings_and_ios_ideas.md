# Lookahead: Validation Findings & Native-iOS Continuation Plan

Status as of 2026-05 (this branch). The flexible iterative-deepening search is
**implemented and validated**; everything below the "Validated" section is
**deferred until the iPad app reaches MVP**, at which point this doc is the
pick-up point. We deliberately stopped adding more Python-side machinery — the
remaining wins (cost/value gating, parallelism) only pay off, or only become
measurable, in the native implementation.

---

## 1. What we validated (done, in this branch)

The flexible search is iterative-deepening beam expectimax
(`Agent.get_best_move` with `time_budget_s`), with move-pruning that makes
depth-3 affordable:

- **Relative cutoff** (multiplicative): keep moves with
  `score >= best * (1 - relative_cutoff)`. Config `search_relative_cutoff = 0.08`.
- **Hard cap** on moves expanded per node: `search_max_branch = 5`.
- **Depth cap**: `search_max_depth = 3` (depth 4+ is never reachable in budget).
- **Budget ceiling**: `play_time_budget_s = 20.0` (a safety ceiling; the search
  usually finishes earlier).

The dice distribution stays **exact** — all 21 distinct outcomes (doubles 1/36,
off-doubles 2/36). No dice approximation; the only pruning is on *moves*.

### Headline result

`./run.sh eval-lookahead` — gold_v9 self-play, flexible-3-ply arm vs fixed-2-ply
arm, alternating colors, 2000 games at the 15s+ budget:

```
 win rate  57.2%   1144W–856L
 95% CI [55.0%, 59.4%]
 depth: d1 8%   d2 8%   d3 84%
```

**Flexible 3-ply beats fixed 2-ply ~57% of the time** (decisive: CI floor 55%).
At a real budget it reaches depth 3 on ~84% of moves. The ~8% depth-1 is mostly
genuinely-forced positions; an earlier 0.15s-budget run showed inflated d1
purely as a *timeout artifact* (depth-2 didn't finish), which disappears at a
real budget.

### Cost structure (measured by profiling)

- Depth-3 cost is essentially `root_candidates × 21 × opp_candidates × 21` leaf
  evals. With caps at 5, worst case ≈ 5×21×5×21.
- In the **Python** implementation the bottleneck is **board encoding + move
  generation**, *not* the NN forward (encoding ~4.3s of a 9s capped depth-3
  eval across ~354k calls; NN forward only ~0.4s; the MLP is tiny).
- CPU threads gave only ~24% speedup, plateauing at 4 threads on an 8-core Mac —
  i.e. the Python search does not thread well (GIL + memory-bound encode).

---

## 2. The problem we stopped on

20s worst-case per move is too slow for interactive play on an iPad. We want to
**avoid attempting depth-3 when it isn't worth it**, and to **parallelize** so
that when we do attempt it, it's fast. Both are deferred to the native port.

---

## 3. Idea A — Cost/value gating (decide whether to attempt depth-3)

**Reframe that makes this simple:** iterative deepening already finishes depth-2
cheaply on the way to depth-3. So the decision is never "2-ply OR 3-ply" — it's
"depth-2 is done; do I *also* attempt depth-3?" All the signals we need are
already computed by depth-2, for free. Split into two independent gates:

### Gate 1 — Cost: "will depth-3 even finish?"

- Depth-3 cost is near-deterministic in the **root candidate count**, which we
  know *before committing* (after pruning). Few candidates (2–3) → cheap →
  attempt. Many candidates near the cap → it'll blow the budget → don't start.
- **Free win available today even without learning:** on the hard positions the
  search currently grinds depth-3 to the deadline, *throws the partial result
  away, and falls back to the depth-2 move anyway*. Predicting "won't finish"
  and skipping straight to depth-2 costs **zero win-rate** and cuts the entire
  20s tail. This is the cheapest improvement on the table.

### Gate 2 — Value: "will depth-3 change my move?"

- **Strongest signal — top-2 margin:** the gap between the best and second-best
  candidate's depth-2 value. Large gap (e.g. 0.71 vs 0.52) → deeper search almost
  never flips it → skip. Near-tie (0.58 / 0.57 / 0.55) → worth the depth.
- Margin captures *decision*-contestedness directly. The user's "win prob
  between 30–70%" idea captures *position*-contestedness, which is a noisier
  proxy for the same thing (you can be at 50% with one obvious move, or 80% with
  two tied moves). Lead with margin; add win-prob only if data shows it helps.
- **Game phase** (early/mid/end) is best treated as *derived*, not primary — it
  mostly acts through candidate count (races have fewer real choices) and margin.

**Ranking of candidate signals:** candidate count (cost) and top-2 margin (value)
do most of the work; win-probability and game phase are secondary and may fall
out for free.

### How to derive the rule — measure first, learn only if needed

Don't reach for ML yet; reach for data. Reuse the eval harness to log, per
flexible move: `candidate_count`, `top2_margin`, `win_prob`, phase features (pip
count, borne-off, contact/race), whether depth-3 **changed** the move vs depth-2,
and the depth-3 wall time / timeout flag. That yields a labeled table:
features → (did 3-ply change the pick?, how long did it take?). Then:

1. **Eyeball it.** A 2-rule threshold —
   `attempt depth-3 iff candidate_count ≤ C AND top2_margin ≤ M` — likely captures
   most of the benefit. Interpretable, robust, nothing to maintain.
2. **Only if thresholds leave value on the table**, fit a tiny logistic
   regression / small decision tree on the same features. Still trivial and
   inspectable.
3. **Validate** the gated agent the same way we validated flexible: run
   gated-vs-2-ply *and* gated-vs-always-3-ply. Target: keep most of the +7pp edge
   at a fraction of the average move time.

**Honest caveat:** "changed the move" is a convenient cheap offline label for
collecting data and setting thresholds; what we ultimately care about is
"improved win rate," which only the head-to-head validation in step 3 confirms.

---

## 4. Idea B — Parallelism (native iOS / Apple Silicon)

Parallelism and gating **compound**: a move that costs 20s serially might cost
~5s across 4 cores, which relaxes the cost gate and lets us attempt depth-3 far
more often.

Two independent axes — do both:

### Axis 1 — Tree expansion across performance cores

- The **root candidate subtrees are independent** — each is an expectimax subtree
  over its own board copy, no shared mutable state, no locks. Farm them across
  cores (e.g. `DispatchQueue.concurrentPerform` over the root candidates).
- After pruning there are ≤ `max_branch` = 5 root candidates, so this maps almost
  perfectly to **4 cores** (one handles two).

**M1+ iPad core layout** (design around the *performance* cluster — efficiency
cores run ~⅓ throughput and are OS-scheduled by QoS, so unreliable for a
latency-sensitive burst):

| Chip | Cores | Performance | Efficiency |
|---|---|---|---|
| M1 / M2 iPad (Pro, Air) | 8 | 4 | 4 |
| M4 iPad Pro | 9–10 | 3–4 | 6 |

- **Plan for 4 parallel subtrees** — the easy, reliable number; expect ~4× on the
  tree-walk portion. Spilling onto efficiency cores adds maybe 1.3–1.5× with
  unpredictable latency — not worth it for a first cut. Root branching caps us at
  5 candidates anyway, so don't architect for more.

### Axis 2 — Batch NN leaf evals onto the ANE/GPU (probably the bigger win)

On iPad this is **not Python**: the model runs through **Core ML on the Apple
Neural Engine (or GPU)**, and the game logic (encode, move-gen, tree walk) is
native Swift/C++. That flips the Python cost profile:

- **Encoding** — the Python 4.3s/9s bottleneck — becomes near-free natively
  (just array writes, ~100× faster). The encoder optimization ideas in
  `docs/encoder_optimization_ideas.md` (GPU fixed-features layer, incremental
  caching) are relevant here.
- **NN forward** is a tiny MLP. Calling it once per leaf — hundreds of tiny ANE
  dispatches — would be dominated by per-call dispatch overhead. **Batch all the
  leaf evaluations in a chance-node into one Core ML call.** The ANE is built for
  batched inference; 200 leaves in one call ≫ 200 calls.

Combined picture: 4 performance cores each walking a root subtree, each
accumulating its chance-node leaves into batched ANE calls.

### Why we can't usefully prototype Axis 1 in Python

The **GIL** serializes Python threads, so parallel tree-walk would need
multiprocessing — and spawning processes *per move* is too heavy to be
representative. Python can still validate the *win-rate* effect of "more depth-3
attempts," but the latency win only shows up in the native build, where it's
genuinely easy (concurrent dispatch over root candidates). This is a core reason
we stopped here rather than building more Python.

---

## 5. Pick-up checklist (when the iPad MVP exists)

1. Port board, move-gen, encoder, and the n-ply search to native Swift/C++; run
   the MLP via Core ML (ANE).
2. Implement **Axis 2** (batched leaf inference) first — likely the larger
   wall-clock win and needed before parallelism pays off.
3. Implement **Axis 1** (concurrent root subtrees, target 4 cores).
4. Re-measure real per-move latency on an M1 iPad at depth-3.
5. Add the **gating instrumentation** (Idea A data-collection), collect a few
   hundred games, eyeball thresholds on `candidate_count` × `top2_margin`.
6. Ship the simplest gate that holds the win-rate; validate gated vs always-2 and
   always-3.

### Open question carried over

Whether to make per-worker thread count configurable in the Python harness (e.g.
`--workers 4` with 2 threads each to mirror live-play conditions) vs the current
6×1-thread. Left unresolved; low priority and likely moot once the search is
native.

### Related tracking

- GitHub issue #16 — A/B test pruning settings (10%/cap5 vs 8%/cap6 vs current
  8%/cap5) via the harness.
- `config/config.yml` — `search_relative_cutoff`, `search_max_branch`,
  `search_max_depth`, `play_time_budget_s`.
- `ai/lookahead_eval.py` — the validation harness reused for data collection.
