
import os
import sys
import torch

from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from config.config_loader import ConfigLoader
from ai.td_lambda_training import TdLambdaTraining
from domain.board import GameBoard
from domain.possible_moves import PossibleMoves
from game.game import Game
from ai.agent import Agent, RandomAgent
from domain.color import Color

def train_ai(config, num_epochs_override=None):
    print("Initializing AI training...")
    board_encoder = BoardEncoder(config)
    board_evaluator = BoardEvaluator(config)

    model_save_path = "trained_model.pth"
    if os.path.exists(model_save_path):
        print(f"Loading existing model from {model_save_path}...")
        try:
            board_evaluator.load_state_dict(torch.load(model_save_path))
            print("Model loaded successfully.")
        except Exception as e:
            print(f"Could not load model: {e}. Starting from scratch.")

    training = TdLambdaTraining(board_evaluator, board_encoder, config)
    if num_epochs_override is not None:
        training.config.config["num_epochs"] = num_epochs_override
    training.run_training_loop()

def play_against_ai(config, model_load_path="trained_model.pth"):
    print("Loading trained model and starting game...")
    game = Game(config)
    board = game.board
    
    board_encoder = BoardEncoder(config)
    board_evaluator = BoardEvaluator(config)

    if not os.path.exists(model_load_path):
        print(f"Model file not found at {model_load_path}. Please train the AI first.")
        return
        
    board_evaluator.load_state_dict(torch.load(model_load_path))
    board_evaluator.eval()

    ai_agent = Agent(board_evaluator, board_encoder)

    while True:
        print(game.board)
        print(f"\n{game.current_player}'s turn")

        game.dice.roll()
        print(f"Rolled: {game.dice.die1.value, game.dice.die2.value}")

        possible_moves_generator = PossibleMoves(game.board, game.current_player, game.dice)
        possible_moves = possible_moves_generator.find_moves()

        if not possible_moves:
            print("No valid moves available. Switching turn.")
            game.switch_turn()
            continue

        if game.current_player == Color.WHITE:
            move_scores = ai_agent.evaluate_moves(game.board, possible_moves, Color.WHITE)
            sorted_moves = sorted(zip(possible_moves, move_scores), key=lambda x: x[1], reverse=True)

            print("Possible moves (sorted by AI evaluation):")
            for i, (move, score) in enumerate(sorted_moves):
                print(f"{i+1}: {move} - Estimated win chance: {score*100:.2f}%")

            while True:
                try:
                    move_choice = int(input(f"Choose a move (1-{len(sorted_moves)}): "))
                    if 1 <= move_choice <= len(sorted_moves):
                        chosen_move = sorted_moves[move_choice - 1][0]
                        break
                    else:
                        print(f"Invalid choice. Please enter a number between 1 and {len(sorted_moves)}.")
                except ValueError:
                    print("Invalid input. Please enter a valid number.")
        else:
            chosen_move, _ = ai_agent.get_best_move(game.board, possible_moves, Color.BLACK)
            print(f"AI chose move: {chosen_move}")

        game.board.apply(chosen_move)

        if game.is_over():
            print(game.board)
            print(f"\n{game.get_winner()} has won the game!")
            play_again = input("Do you want to play again? (y/n): ").lower()
            if play_again != 'y':
                break
            game = Game(config)
            board = game.board
        else:
            game.switch_turn()

def evaluate_against_random(config, model_load_path="trained_model.pth", games_per_color=100):
    print("Loading trained model for evaluation against random...")
    board_encoder = BoardEncoder(config)
    board_evaluator = BoardEvaluator(config)

    if not os.path.exists(model_load_path):
        print(f"Model file not found at {model_load_path}. Please train the AI first.")
        return

    board_evaluator.load_state_dict(torch.load(model_load_path))
    board_evaluator.eval()

    ai_agent = Agent(board_evaluator, board_encoder)
    random_agent = RandomAgent()

    def play_game(ai_color: Color):
        game = Game(config, starting_player=ai_color)
        while not game.is_over():
            current_player = game.current_player
            game.dice.roll()
            possible_moves = PossibleMoves(game.board, current_player, game.dice).find_moves()
            if not possible_moves:
                game.switch_turn()
                continue
            if current_player == ai_color:
                move, _ = ai_agent.get_best_move(game.board, possible_moves, current_player)
            else:
                move = random_agent.get_move(possible_moves)
            game.board.apply(move)
            game.switch_turn()
        return game.get_winner()

    for ai_color in (Color.WHITE, Color.BLACK):
        wins = 0
        losses = 0
        for _ in range(games_per_color):
            winner = play_game(ai_color)
            if winner == ai_color:
                wins += 1
            else:
                losses += 1
        print(f"AI as {ai_color}: {wins}-{losses} over {games_per_color} games")


def main():
    config = ConfigLoader("config/config.yml")
    
    if len(sys.argv) < 2:
        print("Usage: python main.py [train [num_epochs]|play|eval-random [games_per_color]]")
        return

    mode = sys.argv[1]
    if mode == 'train':
        num_epochs = None
        if len(sys.argv) >= 3:
            try:
                num_epochs = int(sys.argv[2])
                if num_epochs <= 0:
                    raise ValueError("num_epochs must be positive")
            except ValueError:
                print("Invalid num_epochs. Please provide a positive integer.")
                return
        train_ai(config, num_epochs_override=num_epochs)
    elif mode == 'play':
        play_against_ai(config)
    elif mode in ('eval-random', 'evaluate-random'):
        games_per_color = 100
        if len(sys.argv) >= 3:
            try:
                games_per_color = int(sys.argv[2])
                if games_per_color <= 0:
                    raise ValueError("games_per_color must be positive")
            except ValueError:
                print("Invalid games_per_color. Please provide a positive integer.")
                return
        evaluate_against_random(config, games_per_color=games_per_color)
    else:
        print(f"Unknown mode: {mode}. Use 'train', 'play', or 'eval-random'.")

if __name__ == "__main__":
    main()
