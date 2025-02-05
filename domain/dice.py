import random


class Dice:
    def __init__(self, number_of_sides: int):
        self.die1 = Die(number_of_sides)
        self.die2 = Die(number_of_sides)
        random.seed(42)

    def __str__(self):
        return str(self.die1) + "," + str(self.die2)

    def __repr__(self):
        return self.__str__()

    def roll(self):
        self.die1.roll()
        self.die2.roll()
        return (self.die1, self.die2)

    def is_pasch(self):
        return self.die1 == self.die2



class Die:
    def __init__(self, number_of_sides: int, value: int = 0):
        self.value = value
        self.number_of_sides = number_of_sides


    def __str__(self):
        return str(self.value)

    def __repr__(self):
        return self.__str__()

    def __eq__(self, other):
        return self.value == other.value

    def roll(self):
        self.value = random.randint(1, self.number_of_sides)
        return self.value
