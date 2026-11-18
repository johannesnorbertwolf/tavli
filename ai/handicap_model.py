"""Warm start of the handicap-aware net from gold_v11 (#148 E3).

`widen_input(evaluator, new_input_size)` returns a copy of `evaluator` whose first layer takes
`new_input_size` inputs: the old weight columns in place (the unary_v3 prefix of
`unary_v3_hc1` is byte-identical, see ai/handicap_encoder.py), the new columns zero. On a normal
game every new feature is 0 too, so the widened net computes exactly gold_v11's value.

`init_handicap_model(source, out, config)` = load source (a `plakoto`/unary_v3 checkpoint),
widen, save as `plakoto_hc` / `unary_v3_hc1` without optimizer state (Adam starts fresh).
CLI: `python main.py --config config/config-handicap.yml handicap-init [--from P] [--out P]`;
the plateau driver calls it on its first start (`plateau.warm_start_from`).
"""

import torch

from ai.board_evaluator import BoardEvaluator
from ai.checkpoint_io import load_state_dict, save_checkpoint


def widen_input(evaluator: BoardEvaluator, new_input_size: int) -> BoardEvaluator:
    old_in = evaluator.layers[0].in_features
    if new_input_size < old_in:
        raise ValueError(f"input can only grow: {old_in} -> {new_input_size}")
    new = BoardEvaluator(new_input_size, hidden_sizes=list(evaluator.hidden_sizes),
                         aux_heads=getattr(evaluator, "aux_heads", 0))
    with torch.no_grad():
        new.load_state_dict({k: v for k, v in evaluator.state_dict().items()
                             if k != "layers.0.weight"}, strict=False)
        w = torch.zeros(evaluator.layers[0].out_features, new_input_size,
                        dtype=evaluator.layers[0].weight.dtype)
        w[:, :old_in] = evaluator.layers[0].weight
        new.layers[0].weight.copy_(w)
    new.eval()
    return new


def init_handicap_model(source_path: str, out_path: str, config):
    """Widen a unary_v3 checkpoint into the config's handicap encoder and save it.
    Returns (old_evaluator, new_evaluator, encoder)."""
    ruleset = config.get_ruleset()
    if not ruleset.name == "plakoto_hc":
        raise ValueError(f"handicap-init needs a plakoto_hc config, got variant '{ruleset.name}'")
    state_dict, meta = load_state_dict(source_path)
    if meta["variant"] not in (ruleset.name,) + tuple(ruleset.compatible_checkpoint_variants):
        raise ValueError(f"{source_path} is a '{meta['variant']}' checkpoint")
    if meta["encoder_version"] != "unary_v3":
        raise ValueError(f"warm start needs a unary_v3 checkpoint, got {meta['encoder_version']}")
    old_encoder = ruleset.make_encoder(config, version="unary_v3")
    encoder = ruleset.make_encoder(config)
    old = BoardEvaluator(old_encoder.input_size, hidden_sizes=meta["hidden_sizes"],
                         aux_heads=meta.get("aux_heads", 0))
    old.load_state_dict(state_dict)
    old.eval()
    new = widen_input(old, encoder.input_size)
    if list(config.get_hidden_sizes()) != list(new.hidden_sizes):
        raise ValueError(f"config hidden_sizes {config.get_hidden_sizes()} != checkpoint "
                         f"{new.hidden_sizes}; fix the config before training")
    save_checkpoint(out_path, new, config)
    print(f"Warm start: {source_path} ({old_encoder.input_size} inputs) -> {out_path} "
          f"({encoder.version}, {encoder.input_size} inputs, new columns zero)")
    return old, new, encoder
