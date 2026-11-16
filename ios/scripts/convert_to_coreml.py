#!/usr/bin/env python3
"""Convert a value network checkpoint to a Core ML model for on-device play.

The exported model takes the variant's board encoding (`input_size` floats — 486 for
Plakoto, 494 / 406 / 414 for standard Plakoto / Fevga / Portes) and outputs the
value for the side to move (sigmoid of the logits) — matching
`BoardEvaluator.forward`, which is what `Agent` calls.

Run from the worktree root with the project venv:

    PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/convert_to_coreml.py

Default (Plakoto, the config's `gold_model_path`) writes the same model to:
  - ios/TavliEngine/Tests/TavliEngineTests/Fixtures/PlakotoValue.mlpackage
        (where the Swift Agent parity test loads it from)
  - ios/TavliApp/TavliApp/Resources/PlakotoValue.mlpackage
        (bundled into the app; Xcode compiles it to PlakotoValue.mlmodelc)

Other variants: `--variant plakoto_standard|fevga|portes --checkpoint PATH` reads
that variant's config (`config/config-<variant>.yml`) and writes
`<Model>Value.mlpackage` (`PlakotoStandardValue` / `FevgaValue` / `PortesValue`) to
the same two places; `--out PATH` (repeatable) overrides the destinations and
`--fixtures PATH` names the JSON whose encodings drive the PyTorch-vs-Core-ML check.
"""
import argparse
import json
import os
import shutil
import sys

import numpy as np
import torch

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from config.config_loader import ConfigLoader
from ai.checkpoint_io import load_agent_from_checkpoint

FIXTURES_DIR = "ios/TavliEngine/Tests/TavliEngineTests/Fixtures"
APP_RESOURCES = "ios/TavliApp/TavliApp/Resources"
INPUT_NAME = "board"
OUTPUT_NAME = "win_prob"

VARIANTS = {
    # variant: (config file, model base name, parity fixtures file)
    "plakoto": ("config.yml", "PlakotoValue", "fixtures.json"),
    "plakoto_standard": ("config-plakoto-standard.yml", "PlakotoStandardValue",
                         "fixtures_plakoto_standard.json"),
    "fevga": ("config-fevga.yml", "FevgaValue", "fixtures_fevga.json"),
    "portes": ("config-portes.yml", "PortesValue", "fixtures_portes.json"),
}


def convert(variant="plakoto", checkpoint=None, outs=None, fixtures=None):
    """Convert `checkpoint` (default: the variant config's `gold_model_path`) and save
    the .mlpackage to every path in `outs` (default: test Fixtures + app Resources).
    The input width comes from the checkpoint's encoder, so any variant works."""
    import coremltools as ct

    config_file, model_name, fixtures_name = VARIANTS[variant]
    config = ConfigLoader(os.path.join(ROOT, "config", config_file))
    checkpoint = checkpoint or os.path.join(ROOT, config.get_gold_model_path())
    agent, meta = load_agent_from_checkpoint(checkpoint, config)
    evaluator = agent.board_evaluator
    evaluator.eval()
    input_size = agent.board_encoder.input_size
    print(f"loaded {checkpoint}: variant={meta['variant']} encoder={meta['encoder_version']} "
          f"hidden={meta['hidden_sizes']} input_size={input_size}")

    example = torch.zeros(1, input_size, dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(evaluator, example)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name=INPUT_NAME, shape=(1, input_size), dtype=np.float32)],
        outputs=[ct.TensorType(name=OUTPUT_NAME)],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
    )
    if not outs:
        outs = [os.path.join(ROOT, FIXTURES_DIR, f"{model_name}.mlpackage"),
                os.path.join(ROOT, APP_RESOURCES, f"{model_name}.mlpackage")]
    for out in outs:
        out_abs = os.path.abspath(out)
        os.makedirs(os.path.dirname(out_abs), exist_ok=True)
        if os.path.exists(out_abs):
            shutil.rmtree(out_abs)
        mlmodel.save(out_abs)
        print(f"saved {out_abs}")

    # Parity check: PyTorch sigmoid output vs Core ML over real fixture encodings.
    fx_path = fixtures or os.path.join(ROOT, FIXTURES_DIR, fixtures_name)
    if not os.path.exists(fx_path):
        print(f"[warn] {fx_path} missing; skipping numeric parity check")
        return
    fx = json.load(open(fx_path))
    encs = [c["encoding"] for c in fx["encoding_cases"][:200]]
    x = np.asarray(encs, dtype=np.float32)
    assert x.shape[1] == input_size, f"fixture width {x.shape[1]} != model input {input_size}"
    with torch.no_grad():
        torch_out = evaluator(torch.from_numpy(x)).squeeze(1).numpy()

    max_diff = 0.0
    for i in range(x.shape[0]):
        pred = mlmodel.predict({INPUT_NAME: x[i:i + 1]})
        cm = float(np.asarray(pred[OUTPUT_NAME]).reshape(-1)[0])
        max_diff = max(max_diff, abs(cm - float(torch_out[i])))
    print(f"PyTorch vs Core ML max abs diff over {x.shape[0]} cases: {max_diff:.2e}")
    assert max_diff < 1e-4, f"Core ML parity check failed: {max_diff}"
    print("Core ML parity OK (<1e-4)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--variant", default="plakoto", choices=sorted(VARIANTS))
    parser.add_argument("--checkpoint", default=None,
                        help="checkpoint to convert (default: the variant config's gold_model_path)")
    parser.add_argument("--out", action="append", default=None,
                        help="output .mlpackage path (repeatable; default: Fixtures + app Resources)")
    parser.add_argument("--fixtures", default=None, help="parity fixtures JSON for the numeric check")
    args = parser.parse_args()
    convert(args.variant, args.checkpoint, args.out, args.fixtures)


if __name__ == "__main__":
    main()
