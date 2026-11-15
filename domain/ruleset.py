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

plus whatever the variant's own rules / encoder need. `HalfMove` / `Move`
(domain/move.py) are shared by all variants.

Variants register an instance by name (`register_ruleset`) and are looked up
with `get_ruleset(name)`; the config key `variant:` selects one.

Hot-path note: `legal_moves` is called millions of times per training run.
Concrete rule sets should bind it as a `staticmethod` pointing directly at
the variant's move generator so `ruleset.legal_moves(...)` costs one
attribute lookup and no extra Python frame.
"""

from abc import ABC, abstractmethod
from typing import Dict, List


class RuleSet(ABC):
    """Abstract rules of one Tavli variant. Instances are stateless singletons."""

    #: Registry key and checkpoint `variant` tag, e.g. "plakoto".
    name: str = ""
    #: Encoder version new checkpoints of this variant are trained/saved with.
    default_encoder_version: str = ""
    #: True iff ai/bearoff.py (exact one-sided race DB) is valid for this variant.
    #: When False, callers must not build/load the DB (agents get bearoff=None).
    supports_bearoff_db: bool = False

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

    def __repr__(self) -> str:
        return f"<RuleSet {self.name}>"


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
        import domain.plakoto_standard_rules  # noqa: F401  (registers "plakoto_standard")


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
