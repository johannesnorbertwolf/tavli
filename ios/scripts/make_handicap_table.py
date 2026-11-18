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
"""
import json
import math
import sys

DICE_KINDS = ("weighted_dice", "rerolls")
# The app's steps (HandicapSetup.diceTiltSteps without 0, and 1...maxRerolls).
APP_CELLS = [f"weighted_dice:{b}" for b in (2, 4, 8, 16)] + [f"rerolls:{n}" for n in (1, 2, 3, 4)]


def logit(p: float) -> float:
    p = min(max(p, 1e-6), 1 - 1e-6)
    return math.log(p / (1 - p))


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else "docs/handicap-e1-tier1.json"
    dst = sys.argv[2] if len(sys.argv) > 2 else "ios/TavliApp/TavliApp/Resources/HandicapTable.json"
    with open(src) as f:
        sweep = json.load(f)
    cells = {label: {"logOddsShift": None} for label in APP_CELLS}
    for c in sweep["cells"]:
        label = c.get("label", "")
        parts = label.split("+")
        if not label or label == "baseline" or not all(p.split(":")[0] in DICE_KINDS for p in parts):
            continue
        cells[label] = {"logOddsShift": round(logit(1 - c["rate"]), 4),
                        "favouredWinRate": round(1 - c["rate"], 4),
                        "games": c.get("games")}
    out = {"version": 1, "source": src, "cells": cells}
    with open(dst, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    print(f"Wrote {dst}: {sum(v['logOddsShift'] is not None for v in cells.values())} measured cells")


if __name__ == "__main__":
    main()
