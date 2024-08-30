import unittest
from domain.color import Color
from domain.point import Point

class TestPoint(unittest.TestCase):
    def test_initialization_empty(self):
        point = Point(1)
        self.assertTrue(point.is_empty())
        self.assertIsNone(point.get_color())

    def test_initialization_with_color(self):
        point = Point(1, Color.WHITE, 3)
        self.assertFalse(point.is_empty())
        self.assertEqual(len(point.pieces), 3)
        self.assertEqual(point.get_color(), Color.WHITE)

    def test_push(self):
        point = Point(1)
        point.push(Color.BLACK)
        self.assertFalse(point.is_empty())
        self.assertEqual(len(point.pieces), 1)
        self.assertEqual(point.get_color(), Color.BLACK)

    def test_pop(self):
        point = Point(1, Color.WHITE, 2)
        point.pop()
        self.assertEqual(len(point.pieces), 1)
        self.assertEqual(point.get_color(), Color.WHITE)
        point.pop()
        self.assertTrue(point.is_empty())
        self.assertIsNone(point.get_color())

    def test_is_color(self):
        point = Point(1, Color.WHITE, 1)
        self.assertTrue(point.is_color(Color.WHITE))
        self.assertFalse(point.is_color(Color.BLACK))

    def test_is_catchable(self):
        point = Point(1, Color.WHITE, 1)
        self.assertTrue(point.is_catchable())
        point.push(Color.WHITE)
        self.assertFalse(point.is_catchable())

    def test_is_open(self):
        point = Point(1)
        self.assertTrue(point.is_open(Color.WHITE))
        point.push(Color.WHITE)
        self.assertTrue(point.is_open(Color.WHITE))
        point.push(Color.BLACK)
        self.assertFalse(point.is_open(Color.WHITE))
        point.pop()
        self.assertTrue(point.is_open(Color.WHITE))
        self.assertTrue(point.is_open(Color.BLACK))

    def test_is_double_color(self):
        point = Point(1)
        self.assertFalse(point.is_double_color(Color.WHITE))
        point.push(Color.WHITE)
        self.assertFalse(point.is_double_color(Color.WHITE))
        point.push(Color.BLACK)
        self.assertFalse(point.is_double_color(Color.WHITE))
        self.assertFalse(point.is_double_color(Color.BLACK))
        point.push(Color.BLACK)
        self.assertFalse(point.is_double_color(Color.WHITE))
        self.assertTrue(point.is_double_color(Color.BLACK))
        point.pop()
        self.assertFalse(point.is_double_color(Color.WHITE))
        self.assertFalse(point.is_double_color(Color.BLACK))

    def test_string(self):
        point = Point(12, Color.WHITE, 8)
        actual = str(point)
        expected = "12: OOOOOOOO"
        self.assertEqual(actual, expected)


if __name__ == '__main__':
    unittest.main()