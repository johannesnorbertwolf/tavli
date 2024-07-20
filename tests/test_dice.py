# tests/test_dice.py

import unittest
from tavli.dice import Dice

class TestDice(unittest.TestCase):
    def setUp(self):
        self.dice = Dice()

    def test_roll(self):
        roll1, roll2 = self.dice.roll()
        self.assertIn(roll1, range(1, 7))
        self.assertIn(roll2, range(1, 7))
        self.assertNotEqual(roll1, 0)
        self.assertNotEqual(roll2, 0)

if __name__ == '__main__':
    unittest.main()