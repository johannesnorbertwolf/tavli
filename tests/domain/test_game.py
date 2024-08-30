import unittest
from game.game import Game
from domain.color import Color
from config.config_loader import ConfigLoader

class TestGame(unittest.TestCase):
    def setUp(self):
        config = ConfigLoader("../config-test.yml")
        self.game = Game(config)

    def test_initialization(self):
        self.assertEqual(self.game.current_player.name, "Player1")
        self.assertTrue(self.game.current_player.color.is_white())

    def test_switch_turn(self):
        self.game.switch_turn()
        self.assertEqual(self.game.current_player.name, "Player2")
        self.assertFalse(self.game.current_player.color.is_white())
        self.game.switch_turn()
        self.assertEqual(self.game.current_player.name, "Player1")
        self.assertTrue(self.game.current_player.color.is_white())


    def test_check_winner(self):
        # No winner initially
        self.assertFalse(self.game.check_winner(Color.WHITE))


if __name__ == '__main__':
    unittest.main()