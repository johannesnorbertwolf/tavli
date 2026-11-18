"""RuleSet: the seam between a game variant's rules and the shared infrastructure.

A RuleSet bundles everything that differs between Tavli variants (Plakoto,
Portes, Fevga, ...): the starting position, move generation, win detection,
the board encoder used by the value net, and whether the exact bear-off
database applies. Training, search, eval and play code receive a RuleSet
instead of importing the Plakoto modules directly.

Each variant owns its own board class. Shared code may rely only on this
duck-typed board contract:

    board.apply(move, color) -> token     # mutate in place, return undo token
    board.undo(token)                      # exact inverse of apply
    board.clone() -> board
    board.has_won(color) -> bool

Game outcome seam (non-abstract; defaults reproduce Plakoto exactly):
`max_points`, `is_over(board)`, `outcome(board) -> (winner, points)`,
`terminal_value(board, perspective)` and `random_starting_player`. Every
place that decides game end / winner / terminal reward (Game, self-play TD
targets, search leaves, eval) goes through these.

plus whatever the variant's own rules / encoder need. `HalfMove` / `Move`
(domain/move.py) are shared by all variants.

Variants register an instance by name (`register_ruleset`) and are looked up
with `get_ruleset(name)`; the config key `variant:` selects one.

Hot-path note: `legal_moves` is called millions of times per training run.
Concrete rule sets should bind it as a `staticmethod` pointing directly at
the variant's move generator so `ruleset.legal_moves(...)` costs one
attribute lookup and no extra Python frame.
"""

import random
from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Tuple

from domain.constants import WHITE, BLACK


class RuleSet(ABC):
    """Abstract rules of one Tavli variant. Instances are stateless singletons."""

    #: Registry key and checkpoint `variant` tag, e.g. "plakoto".
    name: str = ""
    #: Encoder version new checkpoints of this variant are trained/saved with.
    default_encoder_version: str = ""
    #: True iff ai/bearoff.py (exact one-sided race DB) is valid for this variant.
    #: When False, callers must not build/load the DB (agents get bearoff=None).
    supports_bearoff_db: bool = False
    #: Largest result a game can have (1 = win/loss only; 2 = gammons count double).
    #: The value net of a variant learns normalized expected points:
    #: V = 0.5 + E[signed points] / (2 * max_points), so V(opponent) = 1 - V.
    max_points: int = 1
    #: False: today's fixed starters (self-play Black, eval White). True: self-play
    #: and eval pick the starter uniformly at random from the (seeded) global rng.
    random_starting_player: bool = False
    #: Other variants whose checkpoints load (and play) under this one, because their games are
    #: a subset of this variant's (plakoto_hc: a normal game is exactly plakoto).
    compatible_checkpoint_variants: Tuple[str, ...] = ()

    @abstractmethod
    def initial_board(self, config):
        """Fresh board in the variant's starting position (dimensions from config)."""

    @abstractmethod
    def legal_moves(self, board, color: int, dice) -> List:
        """All legal `Move`s for `color` with `dice` (a domain.dice.Dice). Empty = pass."""

    @abstractmethod
    def has_won(self, board, color: int) -> bool:
        """True iff `color` has won on `board`."""

    @abstractmethod
    def is_open_for(self, board, i: int, color: int) -> bool:
        """True iff slot `i` can receive a checker of `color`."""

    @abstractmethod
    def result_points(self, board, winner: int) -> int:
        """Points the finished game is worth to `winner` (1 = single, 2 = double)."""

    @abstractmethod
    def make_encoder(self, config, version: str = None):
        """Board encoder for this variant. `version=None` means
        `default_encoder_version`. The returned object exposes `input_size`,
        `version` and `encode_board(board, is_whites_turn) -> np.ndarray`."""

    # --- game outcome seam (non-abstract defaults) ---

    def is_over(self, board) -> bool:
        """True iff the game on `board` has ended (win for either side, or a draw)."""
        return self.has_won(board, WHITE) or self.has_won(board, BLACK)

    def outcome(self, board) -> Tuple[Optional[int], int]:
        """(winner, points) of a finished game: winner is WHITE, BLACK or None (draw,
        points 0). Call only when `is_over(board)`."""
        if self.has_won(board, WHITE):
            return WHITE, self.result_points(board, WHITE)
        if self.has_won(board, BLACK):
            return BLACK, self.result_points(board, BLACK)
        return None, 0

    def terminal_value(self, board, perspective_color: int) -> float:
        """Value in [0, 1] of the finished game for `perspective_color`:
        0.5 + signed_points / (2 * max_points). With max_points == 1 this is exactly
        1.0 (win) / 0.0 (loss); a draw is 0.5."""
        winner, points = self.outcome(board)
        if winner is None:
            return 0.5
        signed = points if winner == perspective_color else -points
        return 0.5 + signed / (2.0 * self.max_points)

    def starting_player(self, default: int, rng=None) -> int:
        """Who moves first: `default` unless `random_starting_player`, in which case a
        uniform pick from `rng` (default: the global `random` module, which callers
        seed). Never touches the rng for fixed-starter variants (determinism)."""
        if not self.random_starting_player:
            return default
        r = rng if rng is not None else random
        return WHITE if r.random() < 0.5 else BLACK

    def __repr__(self) -> str:
        return f"<RuleSet {self.name}>"


def score_for(outcome: Tuple[Optional[int], int], color: int) -> Tuple[float, int]:
    """(win_credit, signed_points) of a finished game's `outcome` for `color`:
    credit 1 / 0.5 (draw) / 0; points +p for a win, -p for a loss, 0 for a draw.
    Eval code aggregates these (win rate; average points when max_points > 1)."""
    winner, points = outcome
    if winner is None:
        return 0.5, 0
    if winner == color:
        return 1.0, int(points)
    return 0.0, -int(points)


_REGISTRY: Dict[str, RuleSet] = {}
_BUILTINS_LOADED = False


def register_ruleset(ruleset: RuleSet, replace: bool = False) -> RuleSet:
    """Register a RuleSet instance under `ruleset.name`. Returns it (decorator-friendly
    when applied to an instance factory). Re-registering a name raises unless `replace`."""
    if not isinstance(ruleset, RuleSet):
        raise TypeError(f"register_ruleset expects a RuleSet instance, got {type(ruleset).__name__}")
    if not ruleset.name:
        raise ValueError("RuleSet.name must be a non-empty string")
    existing = _REGISTRY.get(ruleset.name)
    if existing is not None and existing is not ruleset and not replace:
        raise ValueError(f"RuleSet '{ruleset.name}' is already registered")
    _REGISTRY[ruleset.name] = ruleset
    return ruleset


def _load_builtins() -> None:
    global _BUILTINS_LOADED
    if not _BUILTINS_LOADED:
        _BUILTINS_LOADED = True
        import domain.plakoto_rules  # noqa: F401  (registers "plakoto")
        import domain.portes_rules  # noqa: F401  (registers "portes")
        import domain.plakoto_standard_rules  # noqa: F401  (registers "plakoto_standard")
        import domain.fevga_rules  # noqa: F401  (registers "fevga")
        import domain.plakoto_hc_rules  # noqa: F401  (registers "plakoto_hc")


def get_ruleset(name: str) -> RuleSet:
    """Look up a registered RuleSet by name (case-insensitive)."""
    _load_builtins()
    key = str(name).strip().lower()
    try:
        return _REGISTRY[key]
    except KeyError:
        known = ", ".join(sorted(_REGISTRY)) or "(none)"
        raise ValueError(f"Unknown game variant '{name}'. Registered variants: {known}") from None


def registered_variants() -> List[str]:
    _load_builtins()
    return sorted(_REGISTRY)
