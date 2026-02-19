
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
from ai.agent import Agent
from domain.color import Color

def train_ai(config):
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
                display_score = (score + 1) / 2
                print(f"{i+1}: {move} - Estimated win chance: {display_score*100:.2f}%")

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


def main():
    config = ConfigLoader("config/config.yml")
    
    if len(sys.argv) < 2:
        print("Usage: python main.py [train|play]")
        return

    mode = sys.argv[1]
    if mode == 'train':
        train_ai(config)
    elif mode == 'play':
        play_against_ai(config)
    else:
        print(f"Unknown mode: {mode}. Use 'train' or 'play'.")

if __name__ == "__main__":
    main()
