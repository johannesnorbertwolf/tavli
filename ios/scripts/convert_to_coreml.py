#!/usr/bin/env python3
"""Convert the trained value network to a Core ML model for on-device play.

The exported model takes a 486-float board encoding and outputs the win probability
for the side to move (sigmoid of the logits) — matching `BoardEvaluator.forward`,
which is what `Agent` calls.

Run from the worktree root with the project venv:

    PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/convert_to_coreml.py

Outputs (same model written to both):
  - ios/TavliEngine/Tests/TavliEngineTests/Fixtures/PlakotoValue.mlpackage
        (where the Swift Agent parity test loads it from)
  - ios/TavliApp/TavliApp/Resources/PlakotoValue.mlpackage
        (bundled into the app; Xcode compiles it to PlakotoValue.mlmodelc)
"""
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
OUT_PATH = "ios/TavliEngine/Tests/TavliEngineTests/Fixtures/PlakotoValue.mlpackage"
APP_OUT_PATH = "ios/TavliApp/TavliApp/Resources/PlakotoValue.mlpackage"
FIXTURES = "ios/TavliEngine/Tests/TavliEngineTests/Fixtures/fixtures.json"
INPUT_NAME = "board"
OUTPUT_NAME = "win_prob"


def main():
    import coremltools as ct

    config = ConfigLoader(os.path.join(ROOT, "config", "config.yml"))
    gold_model_path = config.get_gold_model_path()
    agent, meta = load_agent_from_checkpoint(os.path.join(ROOT, gold_model_path), config)
    evaluator = agent.board_evaluator
    evaluator.eval()
    input_size = agent.board_encoder.input_size
    print(f"loaded {gold_model_path}: encoder={meta['encoder_version']} "
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
    out_abs = os.path.join(ROOT, OUT_PATH)
    os.makedirs(os.path.dirname(out_abs), exist_ok=True)
    mlmodel.save(out_abs)
    print(f"saved {OUT_PATH}")

    app_abs = os.path.join(ROOT, APP_OUT_PATH)
    os.makedirs(os.path.dirname(app_abs), exist_ok=True)
    if os.path.exists(app_abs):
        shutil.rmtree(app_abs)
    shutil.copytree(out_abs, app_abs)
    print(f"saved {APP_OUT_PATH}")

    # Parity check: PyTorch sigmoid output vs Core ML over real fixture encodings.
    fx_path = os.path.join(ROOT, FIXTURES)
    if not os.path.exists(fx_path):
        print("[warn] fixtures.json missing; skipping numeric parity check")
        return
    fx = json.load(open(fx_path))
    encs = [c["encoding"] for c in fx["encoding_cases"][:200]]
    x = np.asarray(encs, dtype=np.float32)
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


if __name__ == "__main__":
    main()
