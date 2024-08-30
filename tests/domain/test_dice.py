# tests/test_dice.py

import unittest
from domain.dice import Dice

class TestDice(unittest.TestCase):
    def setUp(self):
        self.dice = Dice(6)

    def test_roll(self):
        self.dice.roll()
        self.assertIn(self.dice.die1.value, range(1, 7))
        self.assertIn(self.dice.die2.value, range(1, 7))

if __name__ == '__main__':
    unittest.main()