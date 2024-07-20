import unittest
from tavli.game import Game

class TestGame(unittest.TestCase):
    def setUp(self):
        self.game = Game()

    def test_initialization(self):
        self.assertEqual(self.game.current_player.name, "Player1")
        self.assertEqual(self.game.current_player.get_color, "W")

    def test_switch_turn(self):
        self.game.switch_turn()
        self.assertEqual(self.game.current_player.name, "Player2")
        self.assertEqual(self.game.current_player.get_color, "B")
        self.game.switch_turn()
        self.assertEqual(self.game.current_player.name, "Player1")
        self.assertEqual(self.game.current_player.get_color, "W")

    def test_play_turn(self):
        # Mocking dice roll and move checks
        self.game.dice.value = lambda: (1, 2)  # Mocking dice roll
        self.game.players[0].can_move = lambda board, from_point, to_point: True  # Mocking can_move
        self.game.players[0].make_move = lambda board, from_point, to_point: None  # Mocking make_move

        self.game.play_turn(24, 23)
        # Assuming valid move, we should see no exceptions or prompts

    def test_check_winner(self):
        # No winner initially
        self.assertIsNone(self.game.check_winner())

        # Simulate a winning condition for Player1
        self.game.board.points = {i: [] for i in range(1, 25)}
        self.assertEqual(self.game.check_winner().name, "Player1")

if __name__ == '__main__':
    unittest.main()