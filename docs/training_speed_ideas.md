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
