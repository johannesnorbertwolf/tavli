# Faster Learning Ideas (Try One by One)

1. Increase update volume per game  
Raise `replay_updates_per_game` (for example `4 -> 8` or `12`) and, if performance allows, increase `replay_batch_size` (for example `64 -> 128`).

2. Raise learning rate slightly, with decay  
Try `alpha` from `0.0002` to `0.0004` or `0.0006`, then decay slowly to keep late-stage stability.

3. Keep exploration higher for longer  
Use a higher `epsilon` floor (for example `0.1`) or slower decay so opening play keeps exploring.

4. Use an opponent pool  
Train/evaluate against multiple frozen checkpoints (current gold + older gold + recent snapshots) to reduce local plateaus.

5. Densify early-game learning signal  
Use n-step bootstrapped returns (still terminal-grounded) so earlier positions receive stronger training targets sooner.

6. Fix endgame calibration via supervised rollout targets  
TD undersamples late states (each bear-off shape visited ~once per game). Periodically sample late positions from recent trajectories, run ~50–100 Monte Carlo rollouts each (random rollouts in clear races, network rollouts otherwise) to get near-truth win-rate targets, and apply MSE updates alongside TD. Standard fix for the same problem in TD-Gammon.

7. Late-position seeding (cheaper sibling of #6)  
Start a fraction of self-play games (e.g. 20%) from random late-game states sampled from the trajectory buffer instead of always from the opening. Increases TD update density on late states without supervised targets — smaller impact than #6 but trivial to implement.

---

## Post-plateau analysis (2026-05-15)

After ~200 epochs the gold_v8 eval has been oscillating around 50% (47–55%). Empirical null results during exploration:

- Lambda 0.0, 0.1, 0.7 all give the same result → **credit assignment is not the bottleneck**. The value function is already roughly self-consistent along the policy trajectory.
- ε = 0 gives the same result → **exploration is not the bottleneck**. Dice rolls inject all the diversity TD needs.
- Larger network gives the same result → **capacity is not the bottleneck**.

What's left, mapped to observed play-time symptoms:

- **Target quality**: TD bootstraps from the network's *own current* V(s'). Errors reinforce themselves. Matches "model thinks it's winning, then realizes 5 moves later it was wrong" — the 2-ply truth contradicts the 1-ply value, but nothing in training enforces consistency.
- **Data distribution**: most plies are mid-game contact positions. Endgame/race positions are rare per game and the net is undertrained on them. Matches "often it's in the endgame that it makes weird stuff".
- **Search at decision time**: value head is locally smooth; tactical positions need a few plies of expectimax to read correctly.

8. TD-leaf: bootstrap from search, not from the raw net **[IMPLEMENTED 2026-05-15, gated by `td_leaf_enabled`]**  
   In `_apply_trajectory` (and `train_one_game`) replace the bootstrap `next_value = V(s')` with the **2-ply expectimax value** of `s'` — i.e. exactly what `Agent._evaluate_moves_2ply_batch` already computes. The network is then trained to agree with its own short-horizon search. This is the direct fix for the "realizes it was wrong 5 moves later" symptom: it bakes search consistency into the weights. Cost is ~21× more forward passes per ply, but it's batched and need not run every ply (e.g. mix every 4th ply, or only when |TD error| is large). Highest-leverage single change for a TD-Gammon-style net that has plateaued (Baxter et al.'s KnightCap; spiritual ancestor of AlphaZero's policy-from-search).

9. Closed-form race solver as ground truth (sharper version of #6)  
   In pure race positions (no contact, no pinning, no possible re-engagement) win probability is **fully solvable** via a one-sided pip-race DP — independent of any neural net, ~ms per position once cached. Two uses:  
   - At play time: detect race, bypass the net entirely. Plays perfect endgame.  
   - At train time: generate random race positions, train the net on the *exact* solved value (MSE). Forces the encoder + net to internalize race quality.  
   Stronger than the Monte Carlo rollout variant in #6 because the target is exact, not noisy. Also serves as a diagnostic: if a race solver alone closes most of the gap to a stronger opponent, you know how much of the residual loss is "endgame-fixable".

10. Prioritized replay buffer with |TD error| priority (refines #1)  
    Pure online TD sees each position once per game and discards it. Maintain ~20k positions in a buffer with priority = |TD error|, and after each fresh game do ~50 mini-batch SGD steps over sampled positions, using the same TD target (or, even better, the TD-leaf target from #8). Compounds with #6/#7 and is the easiest place to oversample late-game / few-pieces-left / contact-after-pin positions explicitly.

11. Two-headed output: win prob + pip margin (auxiliary regression head)  
    A single sigmoid win/loss target gives small gradients in lopsided positions (saturates near 0/1). Add a regression head for *signed expected pip-difference at terminal* (or `our_borne − their_borne` at terminal). The bear-off head is auxiliary — at play time you still pick on win prob — but it gives the shared trunk a dense, non-saturating signal everywhere on the board. Many TD-Gammon successors do this.

12. Selective 3-ply at decision-critical moments  
    Refinement of the user's lookahead idea. In `_evaluate_moves_2ply_batch`, expand to 3-ply only for the top-K candidate moves (K≈3) whose 2-ply scores are within ε of each other, or when the position is uncertain (value near 0.5). Cost stays near-quadratic on average, expensive only when it matters. Lower priority than #8 — if TD-leaf is implemented, 2-ply scores already reflect deeper "training-time foresight" and play-time deepening matters less.

### Suggested order

#8 first (single highest-leverage change, ~50–100 epochs to see signal). Then #9 (endgame quality; also a diagnostic). Then #10 if #8 helped (compounding effect). #11 and #12 if still climbing.

