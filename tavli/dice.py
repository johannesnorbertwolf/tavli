import random
from tavli.color import Color


class Dice:
    def __init__(self):
        self.die1 = Die()
        self.die2 = Die()

    def roll(self):
        return self.die1.value(), self.die2.value()

    def range1(self, color: Color):
        return self.die1.get_range(color)

    def range2(self, color: Color):
        return self.die2.get_range(color)


class Die:
    def __init__(self, value: int = 0):
        self.value = value

    def roll(self):
        self.value = random.randint(1, 6)
        return self.value

    def get_range(self, color: Color):
        return range(1, 25 - self.value) if color == Color.WHITE else range(1 + self.value, 25)
