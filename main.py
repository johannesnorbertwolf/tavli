from ai.training import SelfPlayTDLearner
from domain.possible_moves import PossibleMoves
from config.config_loader import ConfigLoader
from game.game import Game
from ai.agent import Agent
from domain.color import Color
import torch


def train_ai(config, num_episodes=1000, model_save_path="trained_model.pth"):
    print("Initializing AI training...")
    tdlearner = SelfPlayTDLearner(config)

    print("Starting training process...")
    tdlearner.train(num_episodes=num_episodes)

    print(f"Training completed. Saving model to {model_save_path}")
    torch.save(tdlearner.board_evaluator.state_dict(), model_save_path)


def play_against_ai(config, model_load_path="trained_model.pth"):
    print("Loading trained model and starting game...")
    game = Game(config)
    board_evaluator = SelfPlayTDLearner(config).board_evaluator
    board_evaluator.load_state_dict(torch.load(model_load_path))
    board_evaluator.eval()  # Set the model to evaluation mode
    ai_agent = Agent(board_evaluator, SelfPlayTDLearner(config).board_encoder)

    while True:
        game.dice.roll()

        possible_moves_generator = PossibleMoves(game.board, game.current_player, game.dice)
        possible_moves = possible_moves_generator.find_moves()

        if not possible_moves:
            print("No valid moves available. Switching turn.")
            game.switch_turn()
            continue

        if game.current_player == Color.WHITE:
            # Human player's turn
            move_scores = ai_agent.evaluate_moves(game.board, possible_moves, game.current_player)
            sorted_moves = sorted(zip(possible_moves, move_scores), key=lambda x: x[1])
            print(game.print_with_scored_possible_moves(possible_moves, move_scores))

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
            # AI's turn
            chosen_move, _ = ai_agent.get_best_move(game.board, possible_moves, game.current_player)
            print(game)

        game.board.apply(chosen_move)

        if game.check_winner(game.current_player):
            print(game)
            print(f"{game.current_player} ({game.current_player}) has won the game!")
            play_again = input("Do you want to play again? (y/n): ").lower()
            if play_again != 'y':
                break
            game = Game(config)

        game.switch_turn()


def main():
    config = ConfigLoader("config/config.yml")


    # train_ai(config, 1000)

    play_against_ai(config)


if __name__ == "__main__":
    main()