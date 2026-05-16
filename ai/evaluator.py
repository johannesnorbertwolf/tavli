
from typing import List
import random
from game.game import Game
from ai.agent import Agent, RandomAgent
from domain.possible_moves import PossibleMoves
from domain.color import Color


class AIEvaluator:
    def __init__(self, config, board_evaluator, board_encoder):
        self.config = config
        self.ai_agent = Agent(board_evaluator, board_encoder)
        self.random_agent = RandomAgent()

    def evaluate_against_random(self, episode: int, num_games: int) -> int:
        self.ai_agent.board_evaluator.eval() # Set model to evaluation mode
        wins = 0
        for _ in range(num_games):
            # The AI is always the White player in evaluations
            game = Game(self.config, starting_player=Color.WHITE)
            wins += self._play_single_game(game)
        
        win_percentage = wins * 100 // num_games
        print(f"Episode {episode}: Won {win_percentage}% of {num_games} games against random agent")
        return wins

    def _play_single_game(self, game: Game) -> int:
        """
        Plays a single game between the AI (White) and a RandomAgent (Black).
        Returns 1 if the AI wins, 0 otherwise.
        """
        while True:
            # Check for a winner before the current player's move
            # This is necessary to catch a win by the opponent on their last turn
            if game.board.has_won(Color.WHITE):
                return 1
            if game.board.has_won(Color.BLACK):
                return 0

            game.dice.roll()
            possible_moves = PossibleMoves(game.board, game.current_player, game.dice).find_moves()

            if not possible_moves:
                game.switch_turn()
                continue

            if game.current_player.is_white():
                move, _ = self.ai_agent.get_best_move(game.board, possible_moves, game.current_player)
            else: # Black's turn (Random Agent)
                move = self.random_agent.get_move(possible_moves)

            game.board.apply(move)
            
            # We don't need to check for a winner again here, the loop will do it on the next iteration.
            
            game.switch_turn()
