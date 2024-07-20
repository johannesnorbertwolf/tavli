import random
from tavli.color import Color


class Dice:
    def __init__(self):
        self.die1 = Die()
        self.die2 = Die()

    def roll(self):
        return self.die1.roll(), self.die2.roll()

    def range1(self, color: Color):
        return self.die1.get_range(color)

    def range2(self, color: Color):
        return self.die2.get_range(color)


class Die:
    def __init__(self):
        self.roll = 0

    def roll(self):
        self.roll = random.randint(1, 6)
        return self.roll

    def get_range(self, color: Color):
        return range(1, 25 - self.roll) if color == Color.WHITE else range(1 + self.roll, 25)
