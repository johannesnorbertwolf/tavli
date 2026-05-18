import random
from typing import Optional


class Die:
    __slots__ = ("sides", "value")

    def __init__(self, sides: int = 6, value: int = 0) -> None:
        self.sides = sides
        self.value = value

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Die) and self.value == other.value

    def __hash__(self) -> int:
        return hash(self.value)

    def __repr__(self) -> str:
        return str(self.value)

    def roll(self, rng: Optional[random.Random] = None) -> int:
        r = rng if rng is not None else random
        self.value = r.randint(1, self.sides)
        return self.value


class Dice:
    __slots__ = ("die1", "die2", "sides", "rng")

    def __init__(self, sides: int = 6, rng: Optional[random.Random] = None) -> None:
        self.sides = sides
        self.die1 = Die(sides)
        self.die2 = Die(sides)
        self.rng = rng

    def __repr__(self) -> str:
        return f"{self.die1},{self.die2}"

    def roll(self, rng: Optional[random.Random] = None) -> tuple:
        r = rng if rng is not None else self.rng
        self.die1.roll(r)
        self.die2.roll(r)
        return (self.die1, self.die2)

    def set(self, v1: int, v2: int) -> None:
        """Test/equivalence helper: force dice values without rolling."""
        self.die1.value = v1
        self.die2.value = v2

    def is_pasch(self) -> bool:
        return self.die1.value == self.die2.value
