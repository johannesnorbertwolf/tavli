"""PortesRules: Western backgammon without cube or triple win (issue #137).

Spec: docs/variants/portes.md. Board: domain/portes_board.py; moves:
domain/portes_move_generation.py; encoder: ai/portes_encoder.py.
"""

from domain.portes_board import PortesBoard
from domain.portes_move_generation import legal_moves as _portes_legal_moves
from domain.ruleset import RuleSet, register_ruleset

PORTES = "portes"


class PortesRules(RuleSet):
    name = PORTES
    default_encoder_version = "portes_v1"
    supports_bearoff_db = False          # ai/bearoff.py models Plakoto boards only
    max_points = 2                       # gammon ("diplo") = 2; no triple
    random_starting_player = True        # spec rule 2: random starter, then rolls both dice

    legal_moves = staticmethod(_portes_legal_moves)

    def initial_board(self, config) -> PortesBoard:
        if config is not None:
            dims = (config.get_board_size(), config.get_home_size(), config.get_pieces_per_player())
            if dims != (24, 6, 15):
                raise ValueError(f"Portes needs board_size 24, home_size 6, 15 checkers; got {dims}")
        return PortesBoard.initial()

    def has_won(self, board: PortesBoard, color: int) -> bool:
        return board.has_won(color)

    def is_open_for(self, board: PortesBoard, i: int, color: int) -> bool:
        return board.is_open_for(i, color)

    def result_points(self, board: PortesBoard, winner: int) -> int:
        return board.result_points(winner)

    def make_encoder(self, config, version: str = None):
        from ai.portes_encoder import PortesEncoder  # lazy: domain must not import ai at load
        return PortesEncoder(config, version=version or self.default_encoder_version)


register_ruleset(PortesRules())
