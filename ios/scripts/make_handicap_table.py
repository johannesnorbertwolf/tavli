"""Generate the app's HandicapTable.json from the E1 tier-1 sweep (#148, concept §5).

    python ios/scripts/make_handicap_table.py [docs/handicap-e1-tier1.json] \
        [ios/TavliApp/TavliApp/Resources/HandicapTable.json]

The sweep (`scripts/run_e1_tier1.sh`) reports, per cell label (`weighted_dice:4`,
`rerolls:2`, combos joined with '+'), the *handicapped* side's win rate. Both dice kinds
are bonus kinds (the opponent of the handicapped side is favoured), so the app's
`logOddsShift` is `logit(1 - rate)`, the favoured side's shift against the 50 % baseline.
Only cells made purely of dice levers are kept: position levers (head start, moves first)
are estimated on device from the net. Every app step without a measurement stays `null`
(the builder then says "not measured yet"). The Swift reader is `HandicapTable` in
`ios/TavliEngine/Sources/TavliEngine/HandicapDice.swift`.

Tier 2 (#148 E3): `--tier2 <sweep.json>` merges a tier-2 sweep run with the handicap-aware
model (`main.py --config config/config-handicap.yml handicap-sweep --tier2 --model ...`).
Its cells (`overshoot:1`, `safe_point:6`, `checkers:14`, `smaller_house:4`, `+` combos) are
stored the same way: the rate is always the handicapped (spec `side`) colour's, so
`logOddsShift = logit(1 - rate)` is the favoured side's shift, combined additively in log-odds
like tier 1. (The Swift side does not read tier-2 cells yet: the engine needs the tier-2 rules
and the new model first, P3b.)
"""
import json
import math
import sys

DICE_KINDS = ("weighted_dice", "rerolls")
TIER2_KINDS = ("overshoot", "safe_point", "checkers", "smaller_house")
# The app's steps (HandicapSetup.diceTiltSteps without 0, and 1...maxRerolls).
APP_CELLS = [f"weighted_dice:{b}" for b in (0.3, 0.6, 1.2, 2)] + [f"rerolls:{n}" for n in (1, 2, 3, 4)]


def logit(p: float) -> float:
    p = min(max(p, 1e-6), 1 - 1e-6)
    return math.log(p / (1 - p))


def _merge(cells, sweep, kinds) -> None:
    for c in sweep["cells"]:
        label = c.get("label", "").replace(" + ", "+")
        parts = label.split("+")
        if not label or label == "baseline" or not all(p.split(":")[0] in kinds for p in parts):
            continue
        cells[label] = {"logOddsShift": round(logit(1 - c["rate"]), 4),
                        "favouredWinRate": round(1 - c["rate"], 4),
                        "games": c.get("games")}


def main() -> None:
    argv = sys.argv[1:]
    tier2_src = None
    if "--tier2" in argv:
        i = argv.index("--tier2")
        tier2_src = argv[i + 1]
        del argv[i:i + 2]
    src = argv[0] if len(argv) > 0 else "docs/handicap-e1-tier1.json"
    dst = argv[1] if len(argv) > 1 else "ios/TavliApp/TavliApp/Resources/HandicapTable.json"
    with open(src) as f:
        sweep = json.load(f)
    cells = {label: {"logOddsShift": None} for label in APP_CELLS}
    _merge(cells, sweep, DICE_KINDS)
    out = {"version": 1, "source": src, "cells": cells}
    if tier2_src:
        with open(tier2_src) as f:
            _merge(cells, json.load(f), TIER2_KINDS)
        out["tier2Source"] = tier2_src
    with open(dst, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    print(f"Wrote {dst}: {sum(v['logOddsShift'] is not None for v in cells.values())} measured cells")


if __name__ == "__main__":
    main()
