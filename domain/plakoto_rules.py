"""PlakotoRules: the current (house-rule) Plakoto variant as a RuleSet.

Thin wrapper over domain/board.py (`Board`) and domain/move_generation.py
(`legal_moves`) — no rule logic lives here, so behaviour is bit-identical to
calling those modules directly.
"""

from domain.board import Board
from domain.move_generation import legal_moves as _plakoto_legal_moves
from domain.ruleset import RuleSet, register_ruleset

PLAKOTO = "plakoto"


class PlakotoRules(RuleSet):
    name = PLAKOTO
    default_encoder_version = "unary_v3"  # == ai.checkpoint_io.ENCODER_VERSION_CURRENT
    supports_bearoff_db = True

    # Bound straight to the generator: `rules.legal_moves(board, color, dice)`
    # is the module function itself — no wrapper frame on the hot path.
    legal_moves = staticmethod(_plakoto_legal_moves)

    def initial_board(self, config) -> Board:
        return Board.initial(config)

    def has_won(self, board: Board, color: int) -> bool:
        return board.has_won(color)

    def is_open_for(self, board: Board, i: int, color: int) -> bool:
        return board.is_open_for(i, color)

    def result_points(self, board: Board, winner: int) -> int:
        """Always 1 for now. Note: current training ignores result points — the
        value net learns plain win probability."""
        return 1

    def make_encoder(self, config, version: str = None):
        from ai.board_encoder import BoardEncoder  # lazy: domain must not import ai at load
        return BoardEncoder(config, version=version or self.default_encoder_version)


register_ruleset(PlakotoRules())
