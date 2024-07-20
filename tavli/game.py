from tavli.board import GameBoard
from tavli.player import Player
from tavli.dice import Dice

class Game:
    def __init__(self):
        self.board = GameBoard()
        self.board.initialize_board()
        self.players = [Player(name="Player1", color="W"), Player(name="Player2", color="B")]
        self.current_player_index = 0
        self.dice = Dice()

    @property
    def current_player(self):
        return self.players[self.current_player_index]

    def switch_turn(self):
        self.current_player_index = 1 - self.current_player_index

    def play_turn(self, from_point=None, to_point=None):
        roll1, roll2 = self.dice.roll()
        print(f"{self.current_player.name} rolled {roll1} and {roll2}")

        if from_point is None or to_point is None:
            from_point = int(input(f"{self.current_player.name}, enter the point to move from: "))
            to_point = int(input(f"{self.current_player.name}, enter the point to move to: "))

        if self.current_player.can_move(self.board, from_point, to_point):
            self.current_player.make_move(self.board, from_point, to_point)
            print(f"{self.current_player.name} moved from {from_point} to {to_point}")
        else:
            print(f"Invalid move by {self.current_player.name} from {from_point} to {to_point}")

    def check_winner(self):
        for player in self.players:
            if all(not self.board.points[point] or self.board.points[point][0] != player.color for point in self.board.points):
                return player
        return None

    def start_game(self):
        print("Game started!")
        while True:
            self.play_turn()
            winner = self.check_winner()
            if winner:
                print(f"{winner.name} has won the game!")
                break
            self.switch_turn()