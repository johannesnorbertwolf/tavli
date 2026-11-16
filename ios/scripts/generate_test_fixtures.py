#!/usr/bin/env python3
"""Generate Swift parity fixtures from the Python source of truth.

Emits a JSON file consumed by the TavliEngine Swift test suite to verify that the
Swift port produces byte-for-byte-equivalent board encodings, identical legal-move
sets, and (for the Core ML phase) identical 1-ply move scores / best-move choices.

Run from the worktree root with the project venv:

    PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/generate_test_fixtures.py

Output: ios/TavliEngine/Tests/TavliEngineTests/Fixtures/fixtures.json

Other variants: `--variant plakoto_standard|fevga|portes` (or `all`) writes
`fixtures_<variant>.json` — encodings, legal moves in generator order for all 21
rolls with the position after each move, outcomes (draws / 2-point wins), and,
unless `--no-model`, 1-ply + 2-ply scores from a seeded random-init value net that
is also exported as `<Model>Value.mlpackage` next to the JSON (no trained model
exists for these variants yet). `--out PATH` overrides the output file.
"""
import argparse
import json
import os
import random
import sys

# Run from the worktree root so the project packages import cleanly.
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, ROOT)

from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK, color_name
from domain.board import Board
from domain.dice import Dice
from domain.move_generation import legal_moves
from ai.board_encoder import BoardEncoder, UNARY_V3

SEED = 12345
NUM_GAMES = 12
MAX_PLIES = 80
SAMPLE_EVERY = 3            # sample roughly every Nth ply


def serialize_points(board: Board):
    """Each point as a bottom->top list of 'W'/'B'.

    Reconstructs the v1-style stack from the v2 array model: a pinned slot has the
    trapped opponent checker at the bottom, with the owner stack on top.
    """
    out = []
    for i in range(board.board_size + 2):
        n = board.n[i]
        if n == 0:
            out.append([])
            continue
        owner = color_name(board.color[i])              # 'W' / 'B'
        if board.pinned[i]:
            out.append([color_name(-board.color[i])] + [owner] * n)
        else:
            out.append([owner] * n)
    return out


def load_board_from_points(config, points):
    """Inverse of serialize_points: build a v2 Board from bottom->top stacks."""
    board = Board.from_config(config)
    for i, stack in enumerate(points):
        if not stack:
            continue
        if len(set(stack)) == 1:                        # uniform stack: owners only
            c = WHITE if stack[0] == "W" else BLACK
            board.set_point(i, c, len(stack))
        else:                                           # mixed: bottom = pinned opponent
            owner = WHITE if stack[-1] == "W" else BLACK
            board.set_point(i, owner, len(stack) - 1, pinned=True)
    # Bear-off slots (0 = Black, board_size+1 = White) carry borne-off counts.
    board.borne_off[WHITE] = board.n[board.board_size + 1]
    board.borne_off[BLACK] = board.n[0]
    return board


def all_dice_pairs():
    return [(d1, d2) for d1 in range(1, 7) for d2 in range(d1, 7)]


def move_to_pairs(move):
    return [[h.src, h.dst] for h in move.halves]


def main(out_path=None):
    random.seed(SEED)
    config = ConfigLoader(os.path.join(ROOT, "config", "config.yml"))
    encoder = BoardEncoder(config, version=UNARY_V3)

    # Optional: load the trained agent so we can also record 1-ply scores / best move.
    # Disable bear-off DB so scores match pure Core ML output (the Swift agent has no DB).
    agent = None
    try:
        from ai.checkpoint_io import load_agent_from_checkpoint
        gold_model_path = config.get_gold_model_path()
        agent, _meta = load_agent_from_checkpoint(os.path.join(ROOT, gold_model_path), config)
        agent.bearoff = None
    except Exception as exc:  # noqa: BLE001
        print(f"[warn] could not load agent ({exc!r}); scores omitted", file=sys.stderr)

    sampled_points = []  # list of (points, current_color)

    # Hand-crafted edge positions for bear-off / pinning coverage.
    bs = config.get_board_size()
    handcrafted = []
    # All white checkers home, ready to bear off.
    home = Board.from_config(config)
    home.set_point(bs, WHITE, 9)
    home.set_point(bs - 1, WHITE, 6)
    home.set_point(1, BLACK, 15)
    handcrafted.append((serialize_points(home), "W"))
    # A pinned position: white pins a lone black checker on point 5.
    pin = Board.initial(config)
    pin.set_point(5, WHITE, 1, pinned=True)             # black pinned under white
    handcrafted.append((serialize_points(pin), "B"))

    # Random self-play rollouts to gather varied mid-game positions.
    for _ in range(NUM_GAMES):
        board = Board.initial(config)
        color = BLACK
        dice = Dice(config.get_die_sides())
        for ply in range(MAX_PLIES):
            if board.has_won(WHITE) or board.has_won(BLACK):
                break
            dice.set(random.randint(1, 6), random.randint(1, 6))
            moves = legal_moves(board, color, dice)
            if ply % SAMPLE_EVERY == 0:
                sampled_points.append((serialize_points(board), color_name(color)))
            if moves:
                board.apply(random.choice(moves), color)
            color = BLACK if color == WHITE else WHITE

    all_states = handcrafted + sampled_points

    encoding_cases = []
    move_cases = []
    for points, current_color in all_states:
        # Encoding parity: both perspectives.
        for is_white in (True, False):
            board = load_board_from_points(config, points)
            enc = encoder.encode_board(board, is_whites_turn=is_white)
            encoding_cases.append({
                "points": points,
                "is_whites_turn": is_white,
                "encoding": [round(float(x), 7) for x in enc.tolist()],
            })

        # Move generation + scores: for the side to move, across all dice pairs.
        color = WHITE if current_color == "W" else BLACK
        for (d1, d2) in all_dice_pairs():
            board = load_board_from_points(config, points)
            dice = Dice(config.get_die_sides())
            dice.set(d1, d2)
            moves = legal_moves(board, color, dice)
            case = {
                "points": points,
                "color": current_color,
                "dice": [d1, d2],
                "moves": [move_to_pairs(m) for m in moves],
            }
            if agent is not None and moves:
                scores = agent.evaluate_moves(board, moves, color, lookahead_plies=1)
                case["scores"] = [round(float(s), 6) for s in scores]
                case["best_index"] = int(max(range(len(scores)), key=lambda i: scores[i]))
            move_cases.append(case)

    out = {
        "config": {
            "board_size": config.get_board_size(),
            "pieces_per_player": config.get_pieces_per_player(),
            "home_size": config.get_home_size(),
            "die_sides": config.get_die_sides(),
        },
        "encoder_version": UNARY_V3,
        "input_size": int(encoder.input_size),
        "has_scores": agent is not None,
        "encoding_cases": encoding_cases,
        "move_cases": move_cases,
    }

    out_path = out_path or os.path.join(
        ROOT, "ios", "TavliEngine", "Tests", "TavliEngineTests", "Fixtures", "fixtures.json"
    )
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(out, f)
    print(
        f"wrote {out_path}: {len(encoding_cases)} encoding cases, "
        f"{len(move_cases)} move cases, input_size={encoder.input_size}, "
        f"scores={'yes' if agent is not None else 'no'}"
    )


# ── Multi-variant fixtures (#137, #138, #139) ────────────────────────────────
#
# One JSON per variant: `fixtures_<variant>.json`. Positions travel in each
# variant's Python-native form ("points" bottom->top stacks for plakoto_standard /
# fevga, {"p", "off"} for portes); every position also carries a canonical `key`
# string that the Swift tests compute from their own board, so apply/undo results
# are compared as exact positions. Moves are [[src, dst], ...] in generator order
# (the Swift ports reproduce the order exactly). With a model (default), a seeded
# random-init value net scores 1-ply for every move case and 2-ply for a sample;
# the same net is exported to Core ML (`<Model>Value.mlpackage` next to the JSON)
# so the Swift agent can be checked against it.

VARIANT_CONFIG = {
    "plakoto_standard": "config-plakoto-standard.yml",
    "fevga": "config-fevga.yml",
    "portes": "config-portes.yml",
}
VARIANT_MODEL = {
    "plakoto_standard": "PlakotoStandardValue",
    "fevga": "FevgaValue",
    "portes": "PortesValue",
}
VARIANT_GAMES = 10
VARIANT_MAX_PLIES = 1000
VARIANT_SAMPLE_EVERY = 4
NPLY_CASES = 12             # positions scored at 2-ply for the agent parity test
NPLY_KW = dict(beam_threshold=0.08, relative_cutoff=0.08, max_branch=4)
MODEL_SEED = 2024


def _stack_key(board):
    """Canonical key for array boards with n/color/pinned (plakoto_standard, fevga)."""
    parts = []
    for i in range(board.board_size + 2):
        n = board.n[i]
        if n == 0:
            parts.append("")
            continue
        parts.append(f"{color_name(board.color[i])}{n}{'p' if board.pinned[i] else ''}")
    return ",".join(parts)


def _std_ser(board):
    return {"points": serialize_points(board)}


def _std_de(config):
    from domain.plakoto_standard_board import StandardPlakotoBoard

    def de(s):
        b = StandardPlakotoBoard.from_config(config)
        for i, stack in enumerate(s["points"]):
            if not stack:
                continue
            if len(set(stack)) == 1:
                b.set_point(i, WHITE if stack[0] == "W" else BLACK, len(stack))
            else:
                owner = WHITE if stack[-1] == "W" else BLACK
                b.set_point(i, owner, len(stack) - 1, pinned=True)
        b.borne_off[WHITE] = b.n[b.board_size + 1]
        b.borne_off[BLACK] = b.n[0]
        return b
    return de


def _fevga_de(config):
    from domain.fevga_board import FevgaBoard

    def de(s):
        b = FevgaBoard.from_config(config)
        pts = s["points"]
        for i in range(1, 25):
            if pts[i]:
                b.set_point(i, WHITE if pts[i][0] == "W" else BLACK, len(pts[i]))
        b.set_borne_off(WHITE, len(pts[25]))
        b.set_borne_off(BLACK, len(pts[0]))
        return b
    return de


def _portes_ser(board):
    return {"p": list(board.p), "off": [board.borne_off[WHITE], board.borne_off[BLACK]]}


def _portes_de(_config):
    from domain.portes_board import PortesBoard

    def de(s):
        b = PortesBoard()
        b.p = list(s["p"])
        b.borne_off = {WHITE: s["off"][0], BLACK: s["off"][1]}
        return b
    return de


def _portes_key(board):
    return ",".join(str(v) for v in board.p) + f"|{board.borne_off[WHITE]},{board.borne_off[BLACK]}"


def _handcrafted(variant, config):
    """Spec worked examples (docs/variants/<variant>.md) + terminal positions."""
    out = []
    if variant == "plakoto_standard":
        from domain.plakoto_standard_board import StandardPlakotoBoard as B

        def mk(white, black, pins=(), w_off=0, b_off=0):
            b = B.from_config(config)
            for i, k in white.items():
                b.set_point(i, WHITE, k)
            for i, k in black.items():
                b.set_point(i, BLACK, k)
            for i, owner in pins:
                b.set_point(i, owner, 1, pinned=True)
            b.n[25] = b.borne_off[WHITE] = w_off
            b.color[25] = WHITE if w_off else 0
            b.n[0] = b.borne_off[BLACK] = b_off
            b.color[0] = BLACK if b_off else 0
            return b
        out += [
            (mk({23: 10, 24: 5}, {3: 15}), WHITE),                                    # E1
            (mk({24: 13, 5: 1, 10: 1}, {9: 2, 20: 2, 3: 11}), WHITE),                 # E2
            (mk({24: 14, 10: 1}, {19: 2, 3: 13}), WHITE),                             # E3
            (mk({1: 3, 20: 11}, {5: 14}, pins=[(24, WHITE)]), BLACK),                 # E4 (mother pinned)
            (mk({1: 1, 20: 13}, {2: 1, 5: 13}, pins=[(24, WHITE)]), BLACK),          # E5 before
            (mk({20: 13}, {5: 13}, pins=[(24, WHITE), (1, BLACK)]), WHITE),          # draw
            (mk({20: 14}, {4: 14}, pins=[(24, WHITE)]), BLACK),                       # E7 mother win
            (mk({10: 1, 24: 14}, {11: 2, 13: 1, 3: 12}), WHITE),                      # E8
            (mk({23: 14}, {2: 14}, pins=[(20, BLACK)]), WHITE),                       # E9
            (mk({20: 1, 23: 14}, {3: 15}), WHITE),                                    # E10
            (mk({}, {3: 15}, w_off=15), BLACK),                                       # gammon
            (mk({}, {3: 14}, w_off=15, b_off=1), BLACK),                              # single
            (mk({19: 1, 20: 1, 22: 2}, {2: 3, 4: 1}, w_off=11, b_off=11), WHITE),     # race bear-off
        ]
    elif variant == "fevga":
        from domain.fevga_board import FevgaBoard as B

        def mk(white, black, w_off=0, b_off=0):
            b = B.from_config(config)
            for i, k in white.items():
                b.set_point(i, WHITE, k)
            for i, k in black.items():
                b.set_point(i, BLACK, k)
            b.set_borne_off(WHITE, w_off)
            b.set_borne_off(BLACK, b_off)
            return b
        out += [
            (B.initial(config), WHITE),                                               # F1-F3
            (B.initial(config), BLACK),
            (mk({1: 14, 10: 1}, {13: 15}), WHITE),                                    # F4
            (mk({1: 15}, {13: 14, 22: 1}), BLACK),                                    # F5
            (mk({22: 15}, {10: 15}), BLACK),                                          # F6
            (mk({1: 14, 7: 1}, {13: 13, 9: 2}), WHITE),                               # F7
            (mk({1: 9, 2: 1, 3: 1, 4: 1, 5: 1, 10: 1, 14: 1}, {13: 15}), WHITE),      # F8
            (mk({1: 9, 11: 1, 16: 1, 17: 1, 18: 1, 19: 1, 20: 1}, {13: 14, 14: 1}), WHITE),  # F9a
            (mk({1: 9, 11: 1, 16: 1, 17: 1, 18: 1, 19: 1, 20: 1}, {13: 14, 22: 1}), WHITE),  # F9b
            (mk({10: 1, 24: 14}, {19: 1, 13: 14}), WHITE),                            # F10
            (mk({}, {10: 15}, w_off=15), BLACK),                                      # mars
            (mk({}, {10: 13}, w_off=15, b_off=2), BLACK),                             # single
            (mk({20: 1, 23: 2}, {7: 1, 12: 3}, w_off=12, b_off=11), WHITE),           # race bear-off
        ]
    elif variant == "portes":
        from domain.portes_board import PortesBoard as B
        out += [
            (B.initial(), WHITE),
            (B.initial(), BLACK),
            (B.from_counts({0: 1, 24: 14}, {3: 2, 5: 2, 6: 11}), WHITE),   # P1/P2 dance / entry
            (B.from_counts({0: 2, 24: 13}, {3: 2, 5: 2, 6: 11}), WHITE),   # P3 two on bar
            (B.from_counts({10: 1, 24: 14}, {14: 1, 3: 14}), WHITE),       # P4 intermediate hit
            (B.from_counts({24: 14, 15: 1}, {25: 1, 3: 14}), BLACK),       # P5 Black entry
            (B.from_counts({23: 10, 24: 5}, {3: 15}), WHITE),              # P6
            (B.from_counts({20: 1, 23: 14}, {3: 15}), WHITE),              # P7
            (B.from_counts({10: 1, 24: 14}, {19: 2, 3: 13}), WHITE),       # P8
            (B.from_counts({0: 1, 22: 14}, {4: 2, 1: 13}), WHITE),         # P9
            (B.from_counts({}, {3: 15}, white_off=15), BLACK),             # gammon
            (B.from_counts({}, {25: 2, 3: 12}, white_off=15, black_off=1), BLACK),  # single
            (B.from_counts({0: 1, 19: 2, 21: 1}, {25: 1, 2: 3, 5: 2}, white_off=11, black_off=9), WHITE),
        ]
    return out


def _make_agent(ruleset, config, encoder):
    import torch
    from ai.agent import Agent
    from ai.board_evaluator import BoardEvaluator
    torch.manual_seed(MODEL_SEED)
    evaluator = BoardEvaluator(encoder.input_size, hidden_sizes=config.get_hidden_sizes())
    evaluator.eval()
    return Agent(evaluator, encoder, bearoff=None, ruleset=ruleset)


def main_variant(variant, out_path=None, with_model=True):
    from domain.ruleset import get_ruleset

    config = ConfigLoader(os.path.join(ROOT, "config", VARIANT_CONFIG[variant]))
    ruleset = get_ruleset(variant)
    encoder = ruleset.make_encoder(config)
    if variant == "portes":
        ser, de, key = _portes_ser, _portes_de(config), _portes_key
    elif variant == "fevga":
        ser, de, key = _std_ser, _fevga_de(config), _stack_key
    else:
        ser, de, key = _std_ser, _std_de(config), _stack_key

    random.seed(SEED)
    states = [(ser(b), c) for b, c in _handcrafted(variant, config)]
    dice = Dice(6)
    for _ in range(VARIANT_GAMES):
        board = ruleset.initial_board(config)
        color = WHITE if random.random() < 0.5 else BLACK
        for ply in range(VARIANT_MAX_PLIES):
            if ruleset.is_over(board):
                states.append((ser(board), color))      # terminal position
                break
            dice.set(random.randint(1, 6), random.randint(1, 6))
            moves = ruleset.legal_moves(board, color, dice)
            if ply % VARIANT_SAMPLE_EVERY == 0:
                states.append((ser(board), color))
            if moves:
                board.apply(random.choice(moves), color)
            color = -color

    agent = None
    ckpt_path = None
    if with_model:
        agent = _make_agent(ruleset, config, encoder)

    encoding_cases, move_cases, outcome_cases, nply_cases = [], [], [], []
    for idx, (pos, color) in enumerate(states):
        board = de(pos)
        pos_key = key(board)
        over = ruleset.is_over(board)
        oc = {"position": pos, "key": pos_key, "is_over": over}
        if over:
            w, pts = ruleset.outcome(board)
            oc.update(winner=color_name(w) if w is not None else None, points=pts,
                      value_white=ruleset.terminal_value(board, WHITE),
                      value_black=ruleset.terminal_value(board, BLACK))
        outcome_cases.append(oc)
        for is_white in (True, False):
            enc = encoder.encode_board(de(pos), is_whites_turn=is_white)
            encoding_cases.append({"position": pos, "is_whites_turn": is_white,
                                   "encoding": [round(float(x), 7) for x in enc.tolist()]})
        if over:
            continue
        for (d1, d2) in all_dice_pairs():
            board = de(pos)
            dice.set(d1, d2)
            moves = ruleset.legal_moves(board, color, dice)
            afters = []
            for m in moves:
                token = board.apply(m, color)
                afters.append(key(board))
                board.undo(token)
            assert key(board) == pos_key
            case = {"position": pos, "key": pos_key, "color": color_name(color),
                    "dice": [d1, d2], "moves": [move_to_pairs(m) for m in moves],
                    "afters": afters}
            if agent is not None and moves:
                scores = agent.evaluate_moves(board, moves, color, lookahead_plies=1)
                case["scores"] = [float(s) for s in scores]
            move_cases.append(case)

    if agent is not None:
        # 2-ply sample: positions spread over the list (handcrafted first), one roll each,
        # preferring rolls with several legal moves so pruning is exercised.
        rng = random.Random(SEED + 1)
        candidates = [c for c in move_cases if len(c["moves"]) >= 2]
        picks = candidates[:6] + rng.sample(candidates[6:], min(NPLY_CASES - 6, len(candidates) - 6))
        for c in picks:
            board = de(c["position"])
            color = WHITE if c["color"] == "W" else BLACK
            dice.set(*c["dice"])
            moves = ruleset.legal_moves(board, color, dice)
            scores = agent._evaluate_moves_nply(board, moves, color, 2, NPLY_KW["beam_threshold"],
                                               None, NPLY_KW["relative_cutoff"], NPLY_KW["max_branch"])
            nply_cases.append({"position": c["position"], "color": c["color"], "dice": c["dice"],
                               "moves": [move_to_pairs(m) for m in moves],
                               "scores": [float(s) for s in scores]})

    fixtures_dir = os.path.join(ROOT, "ios", "TavliEngine", "Tests", "TavliEngineTests", "Fixtures")
    out = {
        "variant": variant,
        "config": {"board_size": config.get_board_size(),
                   "pieces_per_player": config.get_pieces_per_player(),
                   "home_size": config.get_home_size(), "die_sides": config.get_die_sides()},
        "encoder_version": encoder.version,
        "input_size": int(encoder.input_size),
        "max_points": ruleset.max_points,
        "random_starting_player": ruleset.random_starting_player,
        "has_scores": agent is not None,
        "nply": NPLY_KW,
        "encoding_cases": encoding_cases,
        "move_cases": move_cases,
        "outcome_cases": outcome_cases,
        "nply_cases": nply_cases,
    }
    out_path = out_path or os.path.join(fixtures_dir, f"fixtures_{variant}.json")
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(out, f, separators=(",", ":"))
    print(f"wrote {out_path}: {len(encoding_cases)} encoding, {len(move_cases)} move, "
          f"{len(outcome_cases)} outcome, {len(nply_cases)} 2-ply cases, "
          f"input_size={encoder.input_size}, scores={'yes' if agent else 'no'}")

    if agent is not None:
        # Export the same random-init net as a checkpoint + Core ML model for the
        # Swift agent parity test (next to the JSON; both generated, gitignored).
        import tempfile
        from ai.checkpoint_io import save_checkpoint
        ckpt_path = os.path.join(tempfile.mkdtemp(prefix="tavli_parity_"), f"{variant}_random.pth")
        save_checkpoint(ckpt_path, agent.board_evaluator, config)
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from convert_to_coreml import convert
        convert(variant=variant, checkpoint=ckpt_path,
                outs=[os.path.join(os.path.dirname(out_path), f"{VARIANT_MODEL[variant]}.mlpackage")],
                fixtures=out_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--variant", default="plakoto",
                        choices=["plakoto", "plakoto_standard", "fevga", "portes", "all"])
    parser.add_argument("--out", default=None, help="output JSON path (single variant only)")
    parser.add_argument("--no-model", action="store_true",
                        help="new variants: skip the random-init net (no scores, no .mlpackage)")
    args = parser.parse_args()
    if args.variant == "plakoto":
        main(args.out)
    elif args.variant == "all":
        main()
        for v in ("plakoto_standard", "fevga", "portes"):
            main_variant(v, with_model=not args.no_model)
    else:
        main_variant(args.variant, args.out, with_model=not args.no_model)
