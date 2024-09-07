from networkx.algorithms.bipartite import color

from domain.board import GameBoard
from domain.dice import Dice
from domain.color import Color
from config.config_loader import ConfigLoader


class Game:
    def __init__(self, config: ConfigLoader):
        self.board = GameBoard(config)
        self.board.initialize_board()
        self.dice = Dice(config.get_die_sides())
        self.player = Color.BLACK

    @property
    def current_player(self):
        return self.player

    def switch_turn(self):
        self.player = Color.BLACK if self.player == Color.WHITE else Color.WHITE

    def check_winner(self, color: Color):
        return self.board.has_won(color)

