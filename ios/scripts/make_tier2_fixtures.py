#!/usr/bin/env python3
"""Generate the Swift parity fixture for the tier-2 handicap rules (#148 P3b).

    PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/make_tier2_fixtures.py

Writes `ios/TavliEngine/Tests/TavliEngineTests/Tier2Fixtures/tier2_moves.json` (committed: it
is small and needs no model). Each case is a `HandicapBoard` position (per-colour rules:
overshoot, safe point, checker count, home size), a mover and a roll, with the Python legal
moves (`domain.handicap_moves.legal_moves_tier2`) as the set of distinct **resulting
positions**, plus both sides' `has_won` there. The Swift test (`Tier2ParityTests`) rebuilds
the board with the same rules, runs its generator and compares the position sets exactly.

Positions come from two sources: random-play games from random tier-2 starts (13…17
checkers, head starts, every rule on either side), and synthetic bear-off races (checkers
spread over the last six points, some borne off, own checkers pinned in and outside the home)
so overshoot bear-offs, smaller homes and doubles are well covered.
"""
import json
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from domain.constants import WHITE, BLACK  # noqa: E402
from domain.dice import Dice  # noqa: E402
from domain.handicap import HandicapBoard, SAFE_POINT_CANDIDATES  # noqa: E402
from domain.handicap_moves import legal_moves_tier2  # noqa: E402

SEED = 148
BS = 24
OUT = os.path.join(ROOT, "ios", "TavliEngine", "Tests", "TavliEngineTests", "Tier2Fixtures",
                   "tier2_moves.json")


def stacks(b):
    out = []
    for i in range(BS + 2):
        n = b.n[i]
        if n == 0:
            out.append("")
            continue
        owner = "W" if b.color[i] == WHITE else "B"
        pin = ("B" if owner == "W" else "W") if b.pinned[i] else ""
        out.append(pin + owner * n)
    return out


def random_rules(rng):
    def side():
        return {
            "overshoot": rng.random() < 0.5,
            "safePoint": rng.choice((0,) + SAFE_POINT_CANDIDATES) if rng.random() < 0.6 else 0,
            "checkers": rng.choice((13, 14, 15, 15, 16, 17)),
            "homeSize": rng.choice((3, 4, 5, 6, 6)),
        }
    return {"white": side(), "black": side()}


def make_board(rules):
    w, b = rules["white"], rules["black"]
    return HandicapBoard(BS, 6, 15, home_white=w["homeSize"], home_black=b["homeSize"],
                         checkers={WHITE: w["checkers"], BLACK: b["checkers"]},
                         overshoot={WHITE: w["overshoot"], BLACK: b["overshoot"]},
                         safe_point={WHITE: w["safePoint"], BLACK: b["safePoint"]})


def case(b, rules, color, d1, d2):
    dice = Dice(6)
    dice.set(d1, d2)
    before = stacks(b)
    results = set()
    for m in legal_moves_tier2(b, color, dice):
        c = b.clone()
        for h in m.halves:
            c.apply_half(h.src, h.dst, color)
        after = stacks(c)
        results.add(";".join(f"{i}:{after[i]}" for i in range(BS + 2) if after[i] != before[i]))
    return {
        "rules": rules,
        "stacks": before,
        "mover": "W" if color == WHITE else "B",
        "dice": [d1, d2],
        "results": sorted(results),
        "won": {"white": b.has_won(WHITE), "black": b.has_won(BLACK)},
    }


def game_cases(rng, n_games):
    out = []
    for _ in range(n_games):
        rules = random_rules(rng)
        b = make_board(rules)
        hs = {WHITE: rng.choice((0, 0, 1, 2, 4)), BLACK: rng.choice((0, 0, 1, 2, 4))}
        cw, cb = rules["white"]["checkers"], rules["black"]["checkers"]
        b.set_point(1, WHITE, cw - hs[WHITE])
        if hs[WHITE]:
            b.set_point(7, WHITE, hs[WHITE])
        b.set_point(BS, BLACK, cb - hs[BLACK])
        if hs[BLACK]:
            b.set_point(BS - 6, BLACK, hs[BLACK])
        color = rng.choice((WHITE, BLACK))
        dice = Dice(6)
        for ply in range(400):
            if b.has_won(WHITE) or b.has_won(BLACK):
                break
            d1, d2 = rng.randint(1, 6), rng.randint(1, 6)
            if ply % 8 == 0 or (b.count_outside_home(color) == 0 and ply % 2 == 0):
                out.append(case(b, rules, color, d1, d2))
            dice.set(d1, d2)
            moves = legal_moves_tier2(b, color, dice)
            if moves:
                for h in rng.choice(moves).halves:
                    b.apply_half(h.src, h.dst, color)
            color = -color
    return out


def race_cases(rng, n):
    out = []
    for _ in range(n):
        rules = random_rules(rng)
        b = make_board(rules)
        for color, side in ((WHITE, "white"), (BLACK, "black")):
            total = rules[side]["checkers"]
            borne = rng.randint(0, total - 1)
            left = total - borne
            # Own path indices 19…24 (the last six points), occasionally one further out.
            paths = list(range(19, 25))
            counts = {}
            for _ in range(left):
                p = rng.choice(paths) if rng.random() < 0.93 else rng.randint(13, 18)
                counts[p] = counts.get(p, 0) + 1
            for p, k in counts.items():
                i = p if color == WHITE else BS + 1 - p
                b.set_point(i, color, k)
            if borne:
                off = BS + 1 if color == WHITE else 0
                b.set_point(off, color, borne)
                b.borne_off[color] = borne
        # Sometimes an opponent blot stands on, or a stack pins, a checker in a home.
        for _ in range(rng.choice((0, 0, 1, 2))):
            i = rng.randint(1, BS)
            if b.n[i] == 1 and not b.pinned[i]:
                victim = b.color[i]
                b.set_point(i, -victim, rng.randint(1, 2), pinned=True)
                # keep the opponent's total: take the pinner from its farthest stack
                src = next((j for j in (range(1, BS + 1) if -victim == WHITE else range(BS, 0, -1))
                            if j != i and b.n[j] > 0 and b.color[j] == -victim and not b.pinned[j]), None)
                if src is not None:
                    b.set_point(src, -victim, b.n[src] - 1)
        for color in (WHITE, BLACK):
            for d1, d2 in rng.sample([(a, c) for a in range(1, 7) for c in range(a, 7)], 4):
                out.append(case(b, rules, color, d1, d2))
    return out


def main():
    rng = random.Random(SEED)
    cases = game_cases(rng, 14) + race_cases(rng, 110)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump({"seed": SEED, "cases": cases}, f, separators=(",", ":"))
        f.write("\n")
    print(f"Wrote {OUT}: {len(cases)} cases, {sum(len(c['results']) for c in cases)} results")


if __name__ == "__main__":
    main()
