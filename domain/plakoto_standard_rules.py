"""StandardPlakotoRules: standard (bkgm) Plakoto as a RuleSet (#139).

Spec + diff vs the house-rule engine: docs/variants/plakoto-standard.md.
State: `StandardPlakotoBoard` (Board subclass; mother rules, draw, 1/2-point
scoring). Moves: `domain.plakoto_standard_moves` (max-dice, larger-die,
larger-die bear-off from the highest point). The `plakoto` variant is untouched.
"""

from typing import Optional, Tuple

from domain.plakoto_standard_board import StandardPlakotoBoard
from domain.plakoto_standard_moves import legal_moves as _std_legal_moves
from domain.ruleset import RuleSet, register_ruleset

PLAKOTO_STANDARD = "plakoto_standard"


class StandardPlakotoRules(RuleSet):
    name = PLAKOTO_STANDARD
    default_encoder_version = "plakoto_std_v1"  # == ai.plakoto_std_encoder.PLAKOTO_STD_V1
    # ai/bearoff.py assumes exact-die bear-off; standard bear-off differs.
    supports_bearoff_db = False
    #: Double wins (mother win, or opponent has borne off none) are worth 2.
    max_points = 2
    #: Starter chosen uniformly at random (distributionally = the opening roll).
    random_starting_player = True

    legal_moves = staticmethod(_std_legal_moves)

    def initial_board(self, config) -> StandardPlakotoBoard:
        return StandardPlakotoBoard.initial(config)

    def has_won(self, board: StandardPlakotoBoard, color: int) -> bool:
        return board.has_won(color)

    def is_over(self, board: StandardPlakotoBoard) -> bool:
        """Someone has won, or both mothers are pinned (draw)."""
        return board.is_over()

    def outcome(self, board: StandardPlakotoBoard) -> Tuple[Optional[int], int]:
        """(winner, points); (None, 0) for a draw. Only meaningful when `is_over`."""
        return board.outcome()

    def is_open_for(self, board: StandardPlakotoBoard, i: int, color: int) -> bool:
        return board.is_open_for(i, color)

    def result_points(self, board: StandardPlakotoBoard, winner: int) -> int:
        w, pts = board.outcome()
        return pts if w == winner else 0

    def make_encoder(self, config, version: str = None):
        version = version or self.default_encoder_version
        from ai.plakoto_std_encoder import PLAKOTO_STD_V1, PlakotoStdEncoder  # lazy
        if version == PLAKOTO_STD_V1:
            return PlakotoStdEncoder(config)
        from ai.board_encoder import BoardEncoder
        return BoardEncoder(config, version=version)


register_ruleset(StandardPlakotoRules())
