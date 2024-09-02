from networkx.algorithms.bipartite import color

from game.game import Game
from domain.possible_moves import PossibleMoves
from config.config_loader import ConfigLoader
from ai.agent import Agent  # Import the Agent class
from ai.board_evaluator import BoardEvaluator  # Assuming you have the neural network class
from ai.board_encoder import BoardEncoder  # Assuming you have the board encoder class
import torch

def display_board(board):
    print("\nCurrent Board State:")
    print(board)
    print("\n")


def main():
    config = ConfigLoader("config/config.yml")
    game = Game(config)
    game.board.initialize_board()
    print("Welcome to Tavli!")

    # Initialize the AI components
    neural_network = BoardEvaluator(config)
    board_encoder = BoardEncoder(config)
    ai_agent = Agent(neural_network, board_encoder)

    while True:
        display_board(game.board)
        print(f"{game.current_player.name}'s turn ({game.current_player.color})")

        game.dice.roll()
        print(f"Rolled: {game.dice.die1} and {game.dice.die2}")

        # Calculate all possible moves
        possible_moves_generator = PossibleMoves(game.board, game.current_player.color, game.dice)
        possible_moves = possible_moves_generator.find_moves()

        # List all possible moves
        if not possible_moves:
            print("No valid moves available. Switching turn.")
            game.switch_turn()
            continue

        if game.current_player.color.is_white():  # Assuming you have a way to check if the player is human
            print("Possible moves:")
            for idx, move in enumerate(possible_moves):
                print(f"{idx + 1}: {move}")

            # Ask the player which move to do
            while True:
                try:
                    move_choice = int(input(f"Choose a move (1-{len(possible_moves)}): "))
                    if 1 <= move_choice <= len(possible_moves):
                        chosen_move = possible_moves[move_choice - 1]
                        break
                    else:
                        print(f"Invalid choice. Please enter a number between 1 and {len(possible_moves)}.")
                except ValueError:
                    print("Invalid input. Please enter a valid number.")
        else:
            # AI's turn
            best_move_index = ai_agent.get_best_move_index(game.board, possible_moves, game.current_player.color)
            chosen_move = possible_moves[best_move_index]
            print(f"AI ({game.current_player.color}) chose move: {chosen_move}")

        # Apply the move
        game.board.apply(chosen_move)

        print("Move applied.")

        # Check if the current player has won
        winner = game.check_winner(game.current_player.color)
        if winner:
            display_board(game.board)
            print(f"{game.current_player.name} ({game.current_player.color}) has won the game!")
            break

        # Switch turn to the other player
        game.switch_turn()


if __name__ == "__main__":
    main()