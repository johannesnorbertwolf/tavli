from domain.dice import Dice
from domain.constants import WHITE, BLACK
from config.config_loader import ConfigLoader


class Game:
    def __init__(self, config: ConfigLoader, starting_player: int = BLACK, ruleset=None):
        # The variant's RuleSet; derived from config (`variant:`) unless given.
        self.ruleset = ruleset if ruleset is not None else config.get_ruleset()
        self.board = self.ruleset.initial_board(config)
        self.dice = Dice(config.get_die_sides())
        self.player = starting_player

    def legal_moves(self):
        """Legal moves for the player on roll with the current dice."""
        return self.ruleset.legal_moves(self.board, self.player, self.dice)

    def __str__(self):
        color_name = "White" if self.player == WHITE else "Black"
        result = f"{color_name}'s turn\n"
        result += f"Rolled: {self.dice.die1} and {self.dice.die2}\n"
        result += str(self.board)
        return result

    def print_with_scored_possible_moves(self, possible_moves, move_scores):
        color_name = "White" if self.player == WHITE else "Black"
        result = f"{color_name}'s turn\n"
        result += f"Rolled: {self.dice.die1} and {self.dice.die2}\n"
        result += "Possible moves (sorted by AI evaluation):\n"

        sorted_moves = sorted(zip(possible_moves, move_scores), key=lambda x: x[1], reverse=True)

        for idx, (move, score) in enumerate(sorted_moves):
            result += f"{idx + 1}: {move} - AI evaluation: {score:.2f}\n"

        result += str(self.board)
        return result

    @property
    def current_player(self):
        return self.player

    def switch_turn(self):
        self.player = -self.player

    def is_over(self):
        return self.board.has_won(WHITE) or self.board.has_won(BLACK)

    def get_winner(self):
        if self.board.has_won(WHITE):
            return WHITE
        if self.board.has_won(BLACK):
            return BLACK
        return None

    def check_winner(self, color: int):
        return self.board.has_won(color)
