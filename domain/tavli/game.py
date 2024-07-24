from domain.tavli.board import GameBoard
from domain.tavli.player import Player
from domain.tavli.dice import Dice
from domain.tavli.color import Color
from config.config_loader import ConfigLoader


class Game:
    def __init__(self, config: ConfigLoader):
        self.board = GameBoard(config)
        self.board.initialize_board()
        self.players = [Player(name="Player1", color=Color.WHITE), Player(name="Player2", color=Color.BLACK)]
        self.current_player_index = 0
        self.dice = Dice(config.get_die_sides())

    @property
    def current_player(self):
        return self.players[self.current_player_index]

    def switch_turn(self):
        self.current_player_index = 1 - self.current_player_index

    def check_winner(self, color: Color):
        return self.board.has_won(color)

