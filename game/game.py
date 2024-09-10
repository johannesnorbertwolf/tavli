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


    def __str__(self):
        result = f"{self.current_player.name}'s turn ({self.current_player})\n"
        result += f"Rolled: {self.dice.die1} and {self.dice.die2}\n"
        result += str(self.board)
        return result

    def print_with_scored_possible_moves(self, possible_moves, move_scores):
        result = f"{self.current_player.name}'s turn ({self.current_player})\n"
        result += f"Rolled: {self.dice.die1} and {self.dice.die2}\n"
        result += "Possible moves (sorted by AI evaluation):\n"

        # Sort moves based on their scores
        sorted_moves = sorted(zip(possible_moves, move_scores), key=lambda x: x[1])

        if self.player == Color.BLACK:
            sorted_moves = sorted_moves[::-1]
        for idx, (move, score) in enumerate(sorted_moves):

            win_chance = (1 - score) * 100 if self.player == Color.WHITE else score * 100
            result += f"{idx + 1}: {move} - Estimated win chance: {win_chance:.2f}%\n"

        result += str(self.board)
        return result

    @property
    def current_player(self):
        return self.player

    def switch_turn(self):
        self.player = Color.BLACK if self.player == Color.WHITE else Color.WHITE

    def check_winner(self, color: Color):
        return self.board.has_won(color)



