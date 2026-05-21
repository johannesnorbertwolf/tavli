import unittest

from play.parser import parse_dice, InvalidDiceInput


class TestParseDice(unittest.TestCase):
    def test_space_separated(self):
        self.assertEqual(parse_dice("5 2"), (5, 2))

    def test_concatenated_two_digits(self):
        self.assertEqual(parse_dice("52"), (5, 2))

    def test_comma_separated(self):
        self.assertEqual(parse_dice("5,2"), (5, 2))

    def test_dash_separated(self):
        self.assertEqual(parse_dice("5-2"), (5, 2))

    def test_multiple_spaces(self):
        self.assertEqual(parse_dice("5  2"), (5, 2))

    def test_leading_trailing_whitespace(self):
        self.assertEqual(parse_dice("  5 2  "), (5, 2))

    def test_doubles(self):
        self.assertEqual(parse_dice("66"), (6, 6))
        self.assertEqual(parse_dice("6 6"), (6, 6))

    def test_out_of_range_upper(self):
        with self.assertRaises(InvalidDiceInput):
            parse_dice("77")
        with self.assertRaises(InvalidDiceInput):
            parse_dice("7 1")

    def test_out_of_range_lower(self):
        with self.assertRaises(InvalidDiceInput):
            parse_dice("0 3")
        with self.assertRaises(InvalidDiceInput):
            parse_dice("5 0")

    def test_single_digit_rejected(self):
        with self.assertRaises(InvalidDiceInput):
            parse_dice("5")

    def test_three_digits_rejected(self):
        with self.assertRaises(InvalidDiceInput):
            parse_dice("123")

    def test_non_numeric_rejected(self):
        with self.assertRaises(InvalidDiceInput):
            parse_dice("abc")

    def test_empty_rejected(self):
        with self.assertRaises(InvalidDiceInput):
            parse_dice("")
        with self.assertRaises(InvalidDiceInput):
            parse_dice("   ")

    def test_custom_die_sides(self):
        self.assertEqual(parse_dice("8 3", die_sides=10), (8, 3))
        with self.assertRaises(InvalidDiceInput):
            parse_dice("7 1", die_sides=6)
        # 8 is in range with die_sides=10
        self.assertEqual(parse_dice("88", die_sides=10), (8, 8))


if __name__ == "__main__":
    unittest.main()
