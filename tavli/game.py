from tavli.board import GameBoard
from tavli.player import Player
from tavli.dice import Dice
from tavli.color import Color

class Game:
    def __init__(self):
        self.board = GameBoard()
        self.board.initialize_board()
        self.players = [Player(name="Player1", color=Color.WHITE), Player(name="Player2", color=Color.BLACK)]
        self.current_player_index = 0
        self.dice = Dice()

    @property
    def current_player(self):
        return self.players[self.current_player_index]

    def switch_turn(self):
        self.current_player_index = 1 - self.current_player_index

    def check_winner(self):
        # for player in self.players:
        #     if all(not self.board.points[point] or self.board.points[point][0] != player.color for point in self.board.points):
        #         return player
        return None

