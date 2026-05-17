"""Drive one game against shared dice rolls in both domains and assert that
the per-ply legal-move sets are identical (by resulting-board canonical key).

On any mismatch, raise `EquivalenceMismatch` carrying everything needed to
reproduce: seed, ply number, dice, both rendered boards, and both legal-move
lists sorted by canonical key.
"""

import random
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

from domain.board import GameBoard as OldBoard
from domain.color import Color as OldColor
from domain.dice import Dice as OldDice
from domain.possible_moves import PossibleMoves as OldPossibleMoves
from domain.move import Move as OldMove

from domain_v2.board import Board as NewBoard
from domain_v2.dice import Dice as NewDice
from domain_v2.move_generation import legal_moves as new_legal_moves
from domain_v2.constants import WHITE, BLACK

from config.config_loader import ConfigLoader

from tests.equivalence._canonical import (
    BoardKey,
    old_canonical,
    new_canonical,
    old_key_after_move,
    new_key_after_move,
)


CONFIG_PATH = Path(__file__).resolve().parents[2] / "config-test.yml"


@dataclass
class EquivalenceMismatch(Exception):
    kind: str
    seed: int
    ply: int
    color: int
    dice: Tuple[int, int]
    old_board: str
    new_board: str
    detail: str

    def __str__(self) -> str:
        return (
            f"\n=== Equivalence mismatch: {self.kind} ===\n"
            f"seed={self.seed} ply={self.ply} color={'W' if self.color == 1 else 'B'} "
            f"dice={self.dice}\n"
            f"--- old board ---\n{self.old_board}\n"
            f"--- new board ---\n{self.new_board}\n"
            f"{self.detail}\n"
        )


def _color_old(c_int: int) -> "OldColor":
    return OldColor.WHITE if c_int == WHITE else OldColor.BLACK


def _index_moves_by_key_old(board: OldBoard, moves: List[OldMove]) -> Dict[BoardKey, OldMove]:
    out: Dict[BoardKey, OldMove] = {}
    for m in moves:
        k = old_key_after_move(board, m)
        # If two distinct moves produce the same resulting board, keep one — the
        # equivalence test only needs one representative per key.
        out.setdefault(k, m)
    return out


def _index_moves_by_key_new(board: NewBoard, color: int, moves) -> Dict[BoardKey, "NewMove"]:
    out: Dict[BoardKey, "NewMove"] = {}
    for m in moves:
        k = new_key_after_move(board, m, color)
        out.setdefault(k, m)
    return out


def play_one_equivalence_game(seed: int, max_plies: int = 2000) -> int:
    """Run one game, return total plies. Raise EquivalenceMismatch on divergence."""
    rng = random.Random(seed)
    config = ConfigLoader(str(CONFIG_PATH))
    sides = config.get_die_sides()

    old_board = OldBoard(config)
    old_board.initialize_board()
    old_dice = OldDice(sides)

    new_board = NewBoard.initial(config)
    new_dice = NewDice(sides)

    # Black moves first — matches game/game.py default.
    color = BLACK

    for ply in range(max_plies):
        if old_board.has_won(OldColor.WHITE) or old_board.has_won(OldColor.BLACK):
            break
        if new_board.has_won(WHITE) or new_board.has_won(BLACK):
            break

        v1 = rng.randint(1, sides)
        v2 = rng.randint(1, sides)
        old_dice.die1.value = v1
        old_dice.die2.value = v2
        new_dice.set(v1, v2)

        old_moves = OldPossibleMoves(old_board, _color_old(color), old_dice).find_moves()
        new_moves = new_legal_moves(new_board, color, new_dice)

        old_index = _index_moves_by_key_old(old_board, old_moves)
        new_index = _index_moves_by_key_new(new_board, color, new_moves)

        if set(old_index.keys()) != set(new_index.keys()):
            old_only = sorted(set(old_index.keys()) - set(new_index.keys()))
            new_only = sorted(set(new_index.keys()) - set(old_index.keys()))
            detail = (
                f"old moves: {len(old_moves)}\n"
                f"new moves: {len(new_moves)}\n"
                f"old-only keys ({len(old_only)}): {old_only[:3]}{'...' if len(old_only) > 3 else ''}\n"
                f"new-only keys ({len(new_only)}): {new_only[:3]}{'...' if len(new_only) > 3 else ''}\n"
                f"old moves dump: {old_moves}\n"
                f"new moves dump: {new_moves}\n"
            )
            raise EquivalenceMismatch(
                kind="legal-move-set mismatch",
                seed=seed, ply=ply, color=color, dice=(v1, v2),
                old_board=str(old_board), new_board=str(new_board),
                detail=detail,
            )

        if not old_index:
            # No legal moves for current player — pass turn.
            color = -color
            continue

        # Deterministic pick: sort keys, pick by RNG index.
        keys_sorted = sorted(old_index.keys())
        idx = rng.randrange(len(keys_sorted))
        chosen = keys_sorted[idx]

        old_m = old_index[chosen]
        new_m = new_index[chosen]
        old_board.apply(old_m)
        new_board.apply(new_m, color)

        # Confirm boards match after apply (sanity — should always hold if
        # canonical key is right).
        if old_canonical(old_board) != new_canonical(new_board):
            raise EquivalenceMismatch(
                kind="post-apply board mismatch",
                seed=seed, ply=ply, color=color, dice=(v1, v2),
                old_board=str(old_board), new_board=str(new_board),
                detail=f"chosen move: old={old_m} new={new_m}",
            )

        color = -color
    else:
        raise EquivalenceMismatch(
            kind="game exceeded max plies",
            seed=seed, ply=max_plies, color=color, dice=(0, 0),
            old_board=str(old_board), new_board=str(new_board),
            detail=f"max_plies={max_plies}",
        )

    # Final winner check.
    old_white_won = old_board.has_won(OldColor.WHITE)
    new_white_won = new_board.has_won(WHITE)
    if old_white_won != new_white_won:
        raise EquivalenceMismatch(
            kind="winner mismatch",
            seed=seed, ply=ply, color=color, dice=(0, 0),
            old_board=str(old_board), new_board=str(new_board),
            detail=f"old white_won={old_white_won} new white_won={new_white_won}",
        )

    return ply
