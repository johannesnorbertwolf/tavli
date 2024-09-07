from ai.training import SelfPlayTDLearner
from domain.possible_moves import PossibleMoves
from config.config_loader import ConfigLoader
from game.game import Game
from ai.agent import Agent
from domain.color import Color


def display_board(board):
    print("\nCurrent Board State:")
    print(board)
    print("\n")


def main():
    config = ConfigLoader("config/config.yml")

    print("Initializing AI training...")
    tdlearner = SelfPlayTDLearner(config)

    print("Starting training process...")
    tdlearner.train(num_episodes=100000)

    print("Training completed. Starting game...")

    # After training, you can use the trained model to play games
    game = Game(config)
    ai_agent = Agent(tdlearner.board_evaluator, tdlearner.board_encoder)

    while True:
        display_board(game.board)
        print(f"{game.current_player.name}'s turn ({game.current_player})")

        game.dice.roll()
        print(f"Rolled: {game.dice.die1} and {game.dice.die2}")

        possible_moves_generator = PossibleMoves(game.board, game.current_player, game.dice)
        possible_moves = possible_moves_generator.find_moves()

        if not possible_moves:
            print("No valid moves available. Switching turn.")
            game.switch_turn()
            continue

        if game.current_player == Color.WHITE:
            # Human player's turn
            move_scores = ai_agent.evaluate_moves(game.board, possible_moves, game.current_player)

            # Sort moves based on their scores
            sorted_moves = sorted(zip(possible_moves, move_scores), key=lambda x: x[1], reverse=True)

            print("Possible moves (sorted by AI evaluation):")
            for idx, (move, score) in enumerate(sorted_moves):
                win_chance = score * 100  # Convert score to percentage
                print(f"{idx + 1}: {move} - Estimated win chance: {win_chance:.2f}%")

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
            print(f"AI ({game.current_player}) chose move: {chosen_move}")

        game.board.apply(chosen_move)

        if game.check_winner(game.current_player):
            display_board(game.board)
            print(f"{game.current_player} ({game.current_player}) has won the game!")
            break

        game.switch_turn()


if __name__ == "__main__":
    main()