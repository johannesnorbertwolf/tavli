"""Handicaps for house-rule Plakoto (#148, phase 1): a layer on top of the RuleSet.

A `HandicapSpec(kind, intensity, side)` disadvantages `side` (the "stronger player").
Penalty kinds modify `side` itself; bonus kinds (`KINDS[kind].bonus`) modify the
opponent instead — either way the spec's `side` is the one expected to win less.

`make_handicapped_rules(specs)` returns the plain `PlakotoRules` singleton when
`specs` is empty (bit-identical, zero overhead), else a `HandicappedPlakotoRules`
that adds the per-side behaviour the game loop needs:

    rules.initial_board(config)                  # pre-borne / headstart / per-side house
    rules.roll(color, u1, u2, q1, q2) -> Dice    # dice from uniforms (see `face`)
    rules.legal_moves(board, color, dice)        # demoted doubles play as two dice
    rules.first_mover(default) -> color
    rules.skips_turn(color, own_turn_no) -> bool # predetermined pass schedule
    rules.needs_roll_values(color) -> bool       # weighted dice: roll() needs per-roll values
    rules.reroll_tokens(color) -> int            # rerolls per game (the game loop spends them)

Dice are drawn as uniforms u in [0, 1) and mapped through the side's die: a fair die
is 1 + int(6u); a ceiling-k die is 1 + int(k u) (uniform on 1..k); a floor-x die is
x + int((7 - x) u) (uniform on x..6). Mapping the SAME uniform keeps the paired
(duplicate-dice) harness aligned under modified dice. q1/q2 are per-turn uniforms for
the probabilistic kinds (forced low roll, no doubles).

Weighted dice (tier 1, #148): before the favoured side rolls, a `roll_valuer(board, color)`
(injected by the caller; the harness passes the agent's 1-ply `Agent.roll_values`) rates the
21 distinct rolls (`ROLLS` order) by the value of that side's best move. The roll distribution
is tilted to p'(r) ∝ p(r)·exp(β·v(r)) and drawn by inverse CDF from ONE uniform per turn,
u = (int(6 u1) + u2) / 6, over the 36 *ordered* outcomes in lexicographic order (each ordered
pair carries its unordered roll's tilt, so the distribution over the 21 rolls is exactly the
tilted one). For a fair die that inverse CDF is (1 + int(6 u1), 1 + int(6 u2)) — the same dice,
in the same order, as the fair path — so β = 0 reproduces fair dice exactly and the paired
harness stays aligned (a tilt only moves the CDF boundaries; the uniform is the same).
Rerolls are a per-game token count (`reroll_tokens`); deciding *when* to reroll is a player
policy and lives in the game loop (ai/handicap_sweep.py).

Kinds deliberately not implemented (see docs/handicap-phase1.md):
- fewer checkers: mechanically identical to `pre_borne` on the same side (win = all
  remaining checkers off); removing checkers *helps* that side, so as a handicap it is
  `pre_borne` for the weaker side.
- stacked start: house Plakoto already starts all 15 checkers on one point.
- shifted-back start for the stronger side: the start point is already the last point;
  the inverse lever is `pip_headstart` for the weaker side.
"""

import math
import random
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, List, NamedTuple, Optional, Sequence, Tuple

from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.move_generation import legal_moves as _plakoto_legal_moves
from domain.plakoto_rules import PlakotoRules
from domain.ruleset import get_ruleset


class KindInfo(NamedTuple):
    category: str            # "dice" | "tempo" | "position" | "geometry"
    bonus: bool              # True: applied to the opponent of the handicapped side
    intensities: Tuple       # default sweep grid
    on_distribution: bool    # False: positions/encoding the gold net never saw
    describe: str            # player-facing wording; {x} = intensity, {side} = favoured side


KINDS: Dict[str, KindInfo] = {
    "dice_ceiling": KindInfo("dice", False, (5, 4, 3), True,
                             "your dice only go up to {x}"),
    "no_doubles": KindInfo("dice", False, (0.5, 1.0), True,
                           "your doubles count as a normal roll ({x:.0%} of the time)"),
    "forced_low": KindInfo("dice", False, (0.25, 0.5, 1.0), True,
                           "one of your dice is a 1 ({x:.0%} of rolls)"),
    "dice_floor": KindInfo("dice", True, (2, 3), True,
                           "opponent's dice never show less than {x}"),
    "weighted_dice": KindInfo("dice", True, (1, 2, 4, 8, 16), True,
                              "dice favour {side} (strength {x})"),
    "rerolls": KindInfo("dice", True, (1, 2, 3, 4), True,
                        "{x} rerolls per game"),
    "first_mover": KindInfo("tempo", False, (1,), True,
                            "you always move second"),
    "pass_turns": KindInfo("tempo", False, (1, 2, 4, 8), True,
                           "you skip {x} turns per game"),
    "pre_borne": KindInfo("position", True, (1, 2, 3, 5), False,
                          "opponent starts with {x} checkers already borne off"),
    "pip_headstart": KindInfo("position", True, (1, 2, 4), False,
                              "{x} opponent checkers start 6 pips advanced"),
    "smaller_house": KindInfo("geometry", False, (5, 4, 3), False,
                              "you bear off from a {x}-point home board"),
    "larger_house": KindInfo("geometry", True, (7, 9), False,
                             "opponent bears off from a {x}-point home board"),
}

#: The 21 distinct rolls (d1 <= d2, fair probability) in the order every per-roll value list
#: uses — identical to ai.agent._DICE_OUTCOMES.
ROLLS: Tuple[Tuple[int, int, float], ...] = tuple(
    (i, j, (1.0 if i == j else 2.0) / 36.0) for i in range(1, 7) for j in range(i, 7))
_ROLL_INDEX = {(i, j): k for k, (i, j, _) in enumerate(ROLLS)}

#: (board, color) -> 21 values in ROLLS order (win prob of `color`'s best move per roll).
RollValuer = Callable[[Board, int], Sequence[float]]

#: Kinds that change the favoured side's die faces; weighted dice replaces the face mapping,
#: so it cannot share a side with them.
_FACE_KINDS = ("dice_ceiling", "dice_floor", "forced_low", "no_doubles")

#: Own turns over which `pass_turns` spreads its skips (~ a typical game's own-turn count).
PASS_SCHEDULE_TURNS = 40


@dataclass(frozen=True)
class HandicapSpec:
    kind: str
    intensity: float
    side: int = WHITE   # the disadvantaged colour

    def __post_init__(self):
        if self.kind not in KINDS:
            raise ValueError(f"unknown handicap kind '{self.kind}'; known: {', '.join(KINDS)}")
        if self.side not in (WHITE, BLACK):
            raise ValueError("side must be WHITE or BLACK")
        _validate(self.kind, self.intensity)

    @property
    def target(self) -> int:
        """Colour whose rules are modified (the opponent of `side` for bonus kinds)."""
        return -self.side if KINDS[self.kind].bonus else self.side

    def with_side(self, side: int) -> "HandicapSpec":
        return HandicapSpec(self.kind, self.intensity, side)

    def label(self) -> str:
        x = self.intensity
        return f"{self.kind}:{int(x) if float(x).is_integer() else x}"


def _validate(kind: str, x) -> None:
    ok = {
        "dice_ceiling": lambda: 1 <= x <= 6 and float(x).is_integer(),
        "dice_floor": lambda: 1 <= x <= 6 and float(x).is_integer(),
        "no_doubles": lambda: 0.0 <= x <= 1.0,
        "forced_low": lambda: 0.0 <= x <= 1.0,
        "weighted_dice": lambda: 0 <= x <= 100,
        "rerolls": lambda: 0 <= x <= 20 and float(x).is_integer(),
        "first_mover": lambda: x in (0, 1),
        "pass_turns": lambda: 0 <= x <= PASS_SCHEDULE_TURNS and float(x).is_integer(),
        "pre_borne": lambda: 0 <= x <= 14 and float(x).is_integer(),
        "pip_headstart": lambda: 0 <= x <= 15 and float(x).is_integer(),
        "smaller_house": lambda: 1 <= x <= 6 and float(x).is_integer(),
        "larger_house": lambda: 6 <= x <= 12 and float(x).is_integer(),
    }[kind]()
    if not ok:
        raise ValueError(f"invalid intensity {x!r} for handicap '{kind}'")


def parse_spec(text: str, side: int = WHITE) -> HandicapSpec:
    """'dice_ceiling:5' -> HandicapSpec('dice_ceiling', 5, side)."""
    kind, _, val = text.strip().partition(":")
    if not val:
        val = str(KINDS[kind].intensities[0]) if kind in KINDS else "1"
    x = float(val)
    if x.is_integer():
        x = int(x)
    return HandicapSpec(kind, x, side)


def pass_schedule(n: int, turns: int = PASS_SCHEDULE_TURNS) -> frozenset:
    """Own-turn numbers (1-based) skipped by `pass_turns:n`, evenly spaced over `turns`."""
    return frozenset(round(k * turns / (n + 1)) for k in range(1, int(n) + 1))


def face(u: float, lo: int = 1, hi: int = 6) -> int:
    """Uniform u in [0,1) -> die face uniform on lo..hi (monotone in u)."""
    return lo + int(u * (hi - lo + 1))


def roll_index(d1: int, d2: int) -> int:
    """Index into ROLLS of the unordered roll {d1, d2}."""
    return _ROLL_INDEX[(d1, d2) if d1 <= d2 else (d2, d1)]


def tilted_roll_probs(values: Sequence[float], beta: float) -> List[float]:
    """p'(r) ∝ p(r)·exp(β·v(r)) over the 21 ROLLS, normalised (β = 0: the fair probabilities)."""
    if not beta:
        return [w for _, _, w in ROLLS]
    vmax = max(values)  # shift for numerical safety; cancels in the normalisation
    raw = [w * math.exp(beta * (v - vmax)) for (_, _, w), v in zip(ROLLS, values)]
    z = sum(raw)
    return [r / z for r in raw]


def roll_uniform(u1: float, u2: float) -> float:
    """The single per-turn uniform of the weighted-dice scheme: (int(6 u1) + u2) / 6."""
    return (int(u1 * 6) + u2) / 6.0


def weighted_faces(u1: float, u2: float, values: Sequence[float], beta: float) -> Tuple[int, int]:
    """Ordered faces (d1, d2) by inverse CDF of u = roll_uniform(u1, u2) over the 36 ordered
    outcomes (lexicographic), each weighted by its unordered roll's tilt exp(β·v).
    β = 0 takes the exact fair path (face(u1), face(u2)), which is that inverse CDF."""
    if not beta:
        return face(u1), face(u2)
    vmax = max(values)
    tilt = [math.exp(beta * (v - vmax)) for v in values]
    cum = []
    total = 0.0
    for a in range(1, 7):
        for b in range(1, 7):
            total += tilt[roll_index(a, b)]
            cum.append(total)
    target = roll_uniform(u1, u2) * total
    for k, c in enumerate(cum):
        if target < c:
            break
    return 1 + k // 6, 1 + k % 6


class _DemotedDoubleDice(Dice):
    """A double that plays as an ordinary two-dice roll (two halves, not four)."""
    __slots__ = ()

    def is_pasch(self) -> bool:
        return False


class HandicapBoard(Board):
    """Plakoto `Board` with a per-colour home-board size (bear-off geometry).
    Everything else — state, apply/undo, win conditions — is inherited unchanged;
    the move generator reaches home size only through `is_home`."""

    __slots__ = ("home_white", "home_black")

    def __init__(self, board_size: int = 24, home_size: int = 6, pieces_per_player: int = 15,
                 home_white: Optional[int] = None, home_black: Optional[int] = None) -> None:
        super().__init__(board_size, home_size, pieces_per_player)
        self.home_white = home_size if home_white is None else home_white
        self.home_black = home_size if home_black is None else home_black

    def is_home(self, c: int, i: int) -> bool:
        if c == WHITE:
            return self.board_size - self.home_white + 1 <= i <= self.board_size
        return 1 <= i <= self.home_black

    def clone(self) -> "HandicapBoard":
        b = HandicapBoard(self.board_size, self.home_size, self.pieces_per_player,
                          self.home_white, self.home_black)
        b.n = self.n[:]
        b.color = self.color[:]
        b.pinned = self.pinned[:]
        b.borne_off = dict(self.borne_off)
        return b


def _dedupe(moves: List) -> List:
    seen = set()
    out = []
    for m in moves:
        key = tuple(sorted(m.halves))
        if key not in seen:
            seen.add(key)
            out.append(m)
    return out


def _legal_moves_with_demotion(board, color, dice):
    moves = _plakoto_legal_moves(board, color, dice)
    if dice.die1.value == dice.die2.value and not dice.is_pasch():
        # A demoted double runs through the non-pasch generator with d1 == d2,
        # which emits each unordered pair (and rule-2 single) twice.
        moves = _dedupe(moves)
    return moves


class HandicappedPlakotoRules(PlakotoRules):
    """House-rule Plakoto plus one or more `HandicapSpec`s. Not registered: it is a
    parametrised instance (name stays "plakoto"; checkpoints/encoder are unchanged)."""

    def __init__(self, specs: Sequence[HandicapSpec],
                 roll_valuer: Optional[RollValuer] = None) -> None:
        self.specs: Tuple[HandicapSpec, ...] = tuple(specs)
        #: Per-roll value oracle for weighted dice (see module doc); set by the caller.
        self.roll_valuer = roll_valuer
        kinds = [s.kind for s in self.specs]
        if len(set((s.kind, s.target) for s in self.specs)) != len(self.specs):
            raise ValueError(f"duplicate handicap kind on one side: {kinds}")
        self._by_target: Dict[int, Dict[str, float]] = {WHITE: {}, BLACK: {}}
        for s in self.specs:
            self._by_target[s.target][s.kind] = s.intensity
        self._dice_lo = {c: int(self._by_target[c].get("dice_floor", 1)) for c in (WHITE, BLACK)}
        self._dice_hi = {c: int(self._by_target[c].get("dice_ceiling", 6)) for c in (WHITE, BLACK)}
        for c in (WHITE, BLACK):
            if self._dice_lo[c] > self._dice_hi[c]:
                raise ValueError("dice floor above dice ceiling")
        self._beta = {c: float(self._by_target[c].get("weighted_dice", 0.0)) for c in (WHITE, BLACK)}
        self._rerolls = {c: int(self._by_target[c].get("rerolls", 0)) for c in (WHITE, BLACK)}
        for c in (WHITE, BLACK):
            if self._beta[c] and any(k in self._by_target[c] for k in _FACE_KINDS):
                raise ValueError("weighted_dice cannot share a side with "
                                 + "/".join(_FACE_KINDS))
        self._skip = {c: pass_schedule(self._by_target[c]["pass_turns"])
                      if "pass_turns" in self._by_target[c] else frozenset()
                      for c in (WHITE, BLACK)}
        self._second = [s.side for s in self.specs if s.kind == "first_mover" and s.intensity]
        if len(set(self._second)) > 1:
            raise ValueError("first_mover on both sides")
        # Instance attribute (plain function, no binding): the plain generator unless
        # a no-doubles handicap can hand it a demoted double.
        any_demote = any("no_doubles" in self._by_target[c] for c in (WHITE, BLACK))
        self.legal_moves = _legal_moves_with_demotion if any_demote else _plakoto_legal_moves

    # --- position ---

    def initial_board(self, config) -> Board:
        hw = int(self._house(WHITE))
        hb = int(self._house(BLACK))
        bs = config.get_board_size()
        if hw == hb == config.get_home_size():
            b = Board.from_config(config)
        else:
            b = HandicapBoard(bs, config.get_home_size(), config.get_pieces_per_player(),
                              home_white=hw, home_black=hb)
        ppp = b.pieces_per_player
        for c in (WHITE, BLACK):
            mods = self._by_target[c]
            start = 1 if c == WHITE else bs
            off = bs + 1 if c == WHITE else 0
            borne = int(mods.get("pre_borne", 0))
            ahead = int(mods.get("pip_headstart", 0))
            on_start = ppp - borne - ahead
            if on_start < 1:
                raise ValueError("handicap leaves no checker on the start point")
            b.set_point(start, c, on_start)
            if ahead:
                b.set_point(start + 6 * c, c, ahead)
            if borne:
                b.set_point(off, c, borne)
                b.borne_off[c] = borne
        return b

    def _house(self, c: int) -> int:
        mods = self._by_target[c]
        return mods.get("smaller_house", mods.get("larger_house", 6))

    # --- dice ---

    def needs_roll_values(self, color: int) -> bool:
        """True when `roll` for `color` needs the 21 per-roll values (weighted dice)."""
        return bool(self._beta[color])

    def roll_beta(self, color: int) -> float:
        return self._beta[color]

    def reroll_tokens(self, color: int) -> int:
        """Rerolls `color` may spend per game."""
        return self._rerolls[color]

    def roll(self, color: int, u1: float, u2: float, q1: float, q2: float,
             board: Optional[Board] = None, values: Optional[Sequence[float]] = None) -> Dice:
        """Dice for `color` from the turn's uniforms. Weighted dice need `values` (21, ROLLS
        order) or a `board` for `self.roll_valuer`; other kinds ignore both."""
        mods = self._by_target[color]
        beta = self._beta[color]
        if beta:
            if values is None:
                if self.roll_valuer is None or board is None:
                    raise ValueError("weighted_dice needs roll values (roll_valuer + board)")
                values = self.roll_valuer(board, color)
            dice = Dice()
            dice.set(*weighted_faces(u1, u2, values, beta))
            return dice
        lo, hi = self._dice_lo[color], self._dice_hi[color]
        d1, d2 = face(u1, lo, hi), face(u2, lo, hi)
        p_low = mods.get("forced_low")
        if p_low is not None and q1 < p_low:
            d2 = 1
        p_nd = mods.get("no_doubles")
        dice = _DemotedDoubleDice() if (p_nd is not None and d1 == d2 and q2 < p_nd) else Dice()
        dice.set(d1, d2)
        return dice

    # --- tempo ---

    def first_mover(self, default: int) -> int:
        return -self._second[0] if self._second else default

    def skips_turn(self, color: int, own_turn_no: int) -> bool:
        return own_turn_no in self._skip[color]


def make_handicapped_rules(specs: Iterable[HandicapSpec] = (),
                           roll_valuer: Optional[RollValuer] = None):
    """Plain `plakoto` RuleSet when there is no handicap, else a HandicappedPlakotoRules."""
    specs = tuple(specs)
    if not specs:
        return get_ruleset("plakoto")
    return HandicappedPlakotoRules(specs, roll_valuer)


# --- plain-rules counterparts so a game loop can treat both uniformly ---

def plain_roll(u1: float, u2: float) -> Dice:
    d = Dice()
    d.set(face(u1), face(u2))
    return d
