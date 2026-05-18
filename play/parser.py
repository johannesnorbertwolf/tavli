import re
from dataclasses import dataclass
from typing import Optional, Tuple, Union


@dataclass(frozen=True)
class PlayMove:
    rank: int


@dataclass(frozen=True)
class Undo:
    n: int


@dataclass(frozen=True)
class History:
    pass


@dataclass(frozen=True)
class Eval:
    depth: Optional[int]


@dataclass(frozen=True)
class Save:
    name: str


@dataclass(frozen=True)
class Load:
    name: str


@dataclass(frozen=True)
class Help:
    pass


@dataclass(frozen=True)
class Quit:
    pass


@dataclass(frozen=True)
class Unparseable:
    reason: str


Command = Union[PlayMove, Undo, History, Eval, Save, Load, Help, Quit, Unparseable]


_UNDO_RE = re.compile(r"^(?:undo|u)\s*(\d+)?$")
_EVAL_RE = re.compile(r"^(?:eval|e)(?:\s*(\S+))?$")


def parse_command(line: str) -> Command:
    s = (line or "").strip()
    if not s:
        return Unparseable("empty input")

    try:
        rank = int(s)
        if rank >= 1:
            return PlayMove(rank)
        return Unparseable(f"move rank must be >= 1, got {rank}")
    except ValueError:
        pass

    lower = s.lower()

    m = _UNDO_RE.match(lower)
    if m:
        if m.group(1) is None:
            return Undo(1)
        n = int(m.group(1))
        if n < 1:
            return Unparseable(f"undo N must be >= 1, got {n}")
        return Undo(n)

    if lower in ("h", "history"):
        return History()

    m = _EVAL_RE.match(lower)
    if m:
        depth_str = m.group(1)
        if depth_str is None:
            return Eval(None)
        try:
            depth = int(depth_str)
        except ValueError:
            return Unparseable(f"eval depth must be an integer, got {depth_str!r}")
        if depth < 1:
            return Unparseable(f"eval depth must be >= 1, got {depth}")
        return Eval(depth)

    if lower in ("?", "help"):
        return Help()

    if lower in ("q", "quit"):
        return Quit()

    parts = s.split(None, 1)
    verb = parts[0].lower()
    rest = parts[1].strip() if len(parts) >= 2 else ""
    if verb == "save":
        if not rest:
            return Unparseable("save needs a name, e.g. 'save mygame'")
        return Save(rest)
    if verb == "load":
        if not rest:
            return Unparseable("load needs a name, e.g. 'load mygame'")
        return Load(rest)

    return Unparseable(f"unrecognised command: {s!r}")


class InvalidDiceInput(ValueError):
    pass


_DICE_RE = re.compile(r"^(\d)\D*(\d)$")


def parse_dice(line: str, die_sides: int = 6) -> Tuple[int, int]:
    s = (line or "").strip()
    if not s:
        raise InvalidDiceInput("empty input")
    m = _DICE_RE.match(s)
    if not m:
        raise InvalidDiceInput(f"could not parse two die values from {line!r}")
    d1, d2 = int(m.group(1)), int(m.group(2))
    if not (1 <= d1 <= die_sides) or not (1 <= d2 <= die_sides):
        raise InvalidDiceInput(f"die values must be in 1..{die_sides}, got ({d1}, {d2})")
    return d1, d2
