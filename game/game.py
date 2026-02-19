from domain.board import GameBoard
from domain.dice import Dice
from domain.color import Color
from config.config_loader import ConfigLoader


class Game:
    def __init__(self, config: ConfigLoader, starting_player: Color = Color.BLACK):
        self.board = GameBoard(config)
        self.board.initialize_board()
        self.dice = Dice(config.get_die_sides())
        self.player = starting_player

    def __str__(self):
        result = f"{self.current_player.name}'s turn ({self.current_player})\n"
        result += f"Rolled: {self.dice.die1} and {self.dice.die2}\n"
        result += str(self.board)
        return result

    def print_with_scored_possible_moves(self, possible_moves, move_scores):
        result = f"{self.current_player.name}'s turn ({self.current_player})\n"
        result += f"Rolled: {self.dice.die1} and {self.dice.die2}\n"
        result += "Possible moves (sorted by AI evaluation):\n"

        # Always sort moves from highest score to lowest, as a higher score is always better
        sorted_moves = sorted(zip(possible_moves, move_scores), key=lambda x: x[1], reverse=True)

        for idx, (move, score) in enumerate(sorted_moves):
            result += f"{idx + 1}: {move} - AI evaluation: {score:.2f}\n"

        result += str(self.board)
        return result

    @property
    def current_player(self):
        return self.player

    def switch_turn(self):
        self.player = Color.BLACK if self.player == Color.WHITE else Color.WHITE

    def is_over(self):
        return self.board.has_won(Color.WHITE) or self.board.has_won(Color.BLACK)

    def get_winner(self):
        if self.board.has_won(Color.WHITE):
            return Color.WHITE
        if self.board.has_won(Color.BLACK):
            return Color.BLACK
        return None

    def check_winner(self, color: Color):
        return self.board.has_won(color)
