#!/usr/bin/env python3
"""Generate Swift parity fixtures from the Python source of truth.

Emits a JSON file consumed by the TavliEngine Swift test suite to verify that the
Swift port produces byte-for-byte-equivalent board encodings, identical legal-move
sets, and (for the Core ML phase) identical 1-ply move scores / best-move choices.

Run from the worktree root with the project venv:

    PYTHONPATH=. /Users/j.wolf/tavli/.venv/bin/python ios/scripts/generate_test_fixtures.py

Output: ios/TavliEngine/Tests/TavliEngineTests/Fixtures/fixtures.json
"""
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
GOLD_PATH = "models/gold_v9.pth"


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


def main():
    random.seed(SEED)
    config = ConfigLoader(os.path.join(ROOT, "config", "config.yml"))
    encoder = BoardEncoder(config, version=UNARY_V3)

    # Optional: load the trained agent so we can also record 1-ply scores / best move.
    agent = None
    try:
        from ai.checkpoint_io import load_agent_from_checkpoint
        agent, _meta = load_agent_from_checkpoint(os.path.join(ROOT, GOLD_PATH), config)
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

    out_path = os.path.join(
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


if __name__ == "__main__":
    main()
