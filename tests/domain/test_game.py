import unittest
from pathlib import Path
from game.game import Game
from domain.color import Color
from domain.point import Point
from config.config_loader import ConfigLoader

class TestGame(unittest.TestCase):
    def setUp(self):
        config_path = Path(__file__).resolve().parents[2] / "config-test.yml"
        config = ConfigLoader(str(config_path))
        self.game = Game(config)

    def test_initialization(self):
        self.assertEqual(self.game.current_player, Color.BLACK)

    def test_switch_turn(self):
        self.game.switch_turn()
        self.assertEqual(self.game.current_player, Color.WHITE)
        self.game.switch_turn()
        self.assertEqual(self.game.current_player, Color.BLACK)


    def test_check_winner(self):
        # No winner initially
        self.assertFalse(self.game.check_winner(Color.WHITE))

    def test_get_winner_white(self):
        board_size = self.game.board.board_size
        pieces = self.game.board.number_of_pieces
        for i in range(0, board_size + 2):
            self.game.board.points[i] = Point(i)
        self.game.board.points[board_size + 1] = Point(board_size + 1, Color.WHITE, pieces)
        self.assertEqual(self.game.get_winner(), Color.WHITE)

    def test_get_winner_black(self):
        board_size = self.game.board.board_size
        pieces = self.game.board.number_of_pieces
        for i in range(0, board_size + 2):
            self.game.board.points[i] = Point(i)
        self.game.board.points[0] = Point(0, Color.BLACK, pieces)
        self.assertEqual(self.game.get_winner(), Color.BLACK)


if __name__ == '__main__':
    unittest.main()
