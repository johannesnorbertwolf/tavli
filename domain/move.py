from typing import NamedTuple, Tuple


class HalfMove(NamedTuple):
    src: int
    dst: int

    def __repr__(self) -> str:
        return f"{self.src}->{self.dst}"


class Move(NamedTuple):
    halves: Tuple[HalfMove, ...]

    def __repr__(self) -> str:
        return "(" + ", ".join(repr(h) for h in self.halves) + ")"
