
from typing import List
from game.game import Game
from ai.agent import Agent
from domain.possible_moves import PossibleMoves


class AIEvaluator:
    def __init__(self, config, board_evaluator, board_encoder):
        self.config = config
        self.ai_agent = Agent(board_evaluator, board_encoder)
        self.random_agent = RandomAgent()

    def evaluate_against_random(self, episode: int, num_games: int) -> int:
        wins = 0
        for _ in range(num_games):
            game = Game(self.config)
            wins += self._play_single_game(game)
        print(f"Episode {episode}: Won {wins * 100 // num_games}% games against random agent")
        return wins

    def _play_single_game(self, game: Game) -> int:
        while not game.check_winner(game.current_player):
            game.dice.roll()
            possible_moves = PossibleMoves(game.board, game.current_player, game.dice).find_moves()

            if not possible_moves:
                game.switch_turn()
                continue

            if game.current_player.is_white():
                move, _ = self.ai_agent.get_best_move(game.board, possible_moves, game.current_player)
            else:
                move = self.random_agent.get_move(possible_moves)

            game.board.apply(move)

            if game.check_winner(game.current_player):
                return 1 if game.current_player.is_white() else 0

            game.switch_turn()

        return 0  # This line should never be reached, but it's here for completeness


class RandomAgent:
    def get_move(self, possible_moves: List):
        return random.choice(possible_moves)


# You'll need to add these imports at the top of the file:
import random