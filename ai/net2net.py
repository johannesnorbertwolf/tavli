"""Function-preserving MLP widening (Net2Net) for capacity expansions.

When the net converges to the fixed point of its training signal at a given
capacity, widening the hidden layers while preserving the computed function
lets training continue from the same strength instead of from scratch (used
for the [128,64] -> [256,128,64] expansion that preceded gold_v9).

Each widened layer copies rows from the original (identity for the first
`old_n` units, random duplicates for the rest); the next layer's columns are
divided by the duplicate count so every pre-activation is unchanged (exact
under ReLU). Small gaussian noise on the duplicated rows breaks the symmetry
so the copies can diverge during training.

CLI: python main.py expand-net --to 512,256,128 [--checkpoint X] [--out Y]
The expanded checkpoint is saved WITHOUT optimizer state — Adam starts fresh
(the trainer's shape guard would skip the stale state anyway).
"""

import numpy as np
import torch

from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import ENCODER_VERSION_CURRENT, load_state_dict, save_checkpoint


def widen_evaluator(evaluator, new_hidden_sizes, noise_std=1e-3, seed=0):
    """Return a new BoardEvaluator with wider hidden layers computing the same
    function as `evaluator` (exactly for noise_std=0, else up to small noise)."""
    old_sizes = list(evaluator.hidden_sizes)
    new_sizes = [int(s) for s in new_hidden_sizes]
    if len(new_sizes) != len(old_sizes):
        raise ValueError(f"Layer count must match: {old_sizes} -> {new_sizes}")
    if any(n < o for o, n in zip(old_sizes, new_sizes)):
        raise ValueError(f"Layers can only grow: {old_sizes} -> {new_sizes}")

    rng = np.random.default_rng(seed)
    input_size = evaluator.layers[0].in_features
    new_eval = BoardEvaluator(input_size, hidden_sizes=new_sizes)

    # Per hidden layer: which original unit each new unit copies.
    mappings = [np.concatenate([np.arange(o), rng.integers(0, o, size=n - o)])
                for o, n in zip(old_sizes, new_sizes)]

    with torch.no_grad():
        for li, layer in enumerate(evaluator.layers):
            w_old = layer.weight.data
            b_old = layer.bias.data
            row_map = mappings[li] if li < len(mappings) else np.arange(w_old.shape[0])
            if li == 0:
                col_map = np.arange(w_old.shape[1])
                col_counts = np.ones(w_old.shape[1])
            else:
                g_prev = mappings[li - 1]
                counts = np.bincount(g_prev, minlength=old_sizes[li - 1])
                col_map = g_prev
                col_counts = counts[g_prev]
            w_new = w_old[row_map][:, col_map] / torch.as_tensor(col_counts, dtype=w_old.dtype)
            b_new = b_old[row_map]
            if noise_std > 0 and li < len(mappings):
                dup = torch.as_tensor(np.arange(len(row_map)) >= old_sizes[li])
                noise = torch.from_numpy(
                    rng.normal(0.0, noise_std, size=tuple(w_new.shape)).astype(np.float32))
                w_new[dup] += noise[dup]
            new_eval.layers[li].weight.data.copy_(w_new)
            new_eval.layers[li].bias.data.copy_(b_new)

    new_eval.eval()
    return new_eval


def expand_checkpoint(in_path, out_path, new_hidden_sizes, config,
                      noise_std=1e-3, seed=0):
    """Widen the net in a checkpoint and save it (without optimizer state).
    Returns (old_evaluator, new_evaluator) for verification."""
    from ai.board_encoder import BoardEncoder

    state_dict, meta = load_state_dict(in_path)
    if meta["encoder_version"] != ENCODER_VERSION_CURRENT:
        raise ValueError(f"Refusing to expand a {meta['encoder_version']} checkpoint; "
                         f"current encoder is {ENCODER_VERSION_CURRENT}")
    encoder = BoardEncoder(config, version=meta["encoder_version"])
    old_eval = BoardEvaluator(encoder.input_size, hidden_sizes=meta["hidden_sizes"])
    old_eval.load_state_dict(state_dict)
    old_eval.eval()

    new_eval = widen_evaluator(old_eval, new_hidden_sizes, noise_std=noise_std, seed=seed)
    save_checkpoint(out_path, new_eval, config)

    with torch.no_grad():
        x = torch.rand(512, encoder.input_size)
        max_dev = float((old_eval(x) - new_eval(x)).abs().max())
    print(f"Expanded {meta['hidden_sizes']} -> {list(new_eval.hidden_sizes)}; "
          f"max |output deviation| over 512 random inputs: {max_dev:.6f}")
    print(f"Saved to {out_path} (no optimizer state — Adam starts fresh)")
    return old_eval, new_eval
