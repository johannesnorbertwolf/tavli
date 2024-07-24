import random
from domain.tavli.color import Color


class Dice:
    def __init__(self):
        self.die1 = Die()
        self.die2 = Die()
    def __str__(self):
        return str(self.die1) + "," + str(self.die2)

    def __repr__(self):
        return self.__str__()

    def roll(self):
        self.die1.roll()
        self.die2.roll()


class Die:
    def __init__(self, value: int = 0):
        self.value = value

    def __str__(self):
        return str(self.value)

    def __repr__(self):
        return self.__str__()

    def roll(self):
        self.value = random.randint(1, 6)
        return self.value

    def get_range(self, color: Color):
        return range(1, 25 - self.value) if color == Color.WHITE else range(1 + self.value, 25)
