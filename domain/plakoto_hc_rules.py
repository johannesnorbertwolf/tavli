"""PlakotoHandicapRules: house Plakoto + tier-2 handicaps, registered as "plakoto_hc" (#148 E3).

The variant of the ONE handicap-aware model. A normal game under it is exactly house Plakoto
(plain `Board`, same generator). A handicapped game starts from a `HandicapBoard`
(domain/handicap.py: `tier2_board(sample_tier2_specs(rng), config)`), which carries every rule
change itself, so the RuleSet is stateless like every other variant:

- `legal_moves` = `domain.handicap_moves.legal_moves_tier2` (house generator unless the mover
  has overshoot; smaller homes / safe points / checker counts work through the board);
- win = `board.has_won` (`HandicapBoard.all_borne_off` uses the per-colour count);
- `supports_bearoff_db = True`, gated per position by `HandicapBoard.bearoff_exact`
  (ai/bearoff.py `race_state` returns None where the DB would be wrong);
- encoder `unary_v3_hc1` (ai/handicap_encoder.py); `unary_v3` is still built for gold_v11,
  whose checkpoints (variant "plakoto") load under this variant (`compatible_checkpoint_variants`).
"""

from domain.handicap_moves import legal_moves_tier2
from domain.plakoto_rules import PlakotoRules
from domain.ruleset import register_ruleset

PLAKOTO_HC = "plakoto_hc"


class PlakotoHandicapRules(PlakotoRules):
    name = PLAKOTO_HC
    default_encoder_version = "unary_v3_hc1"  # == ai.handicap_encoder.UNARY_V3_HC1
    supports_bearoff_db = True
    compatible_checkpoint_variants = ("plakoto",)

    legal_moves = staticmethod(legal_moves_tier2)

    def make_encoder(self, config, version: str = None):
        version = version or self.default_encoder_version
        if version == self.default_encoder_version:
            from ai.handicap_encoder import HandicapEncoder  # lazy: domain must not import ai at load
            return HandicapEncoder(config, version=version)
        from ai.board_encoder import BoardEncoder
        return BoardEncoder(config, version=version)


register_ruleset(PlakotoHandicapRules())
