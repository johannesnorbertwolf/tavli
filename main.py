from game.game import Game
from domain.possible_moves import PossibleMoves
from config.config_loader import ConfigLoader

def display_board(board):
    print("\nCurrent Board State:")
    print(board)
    print("\n")


def main():
    config = ConfigLoader("config/config.yml")
    game = Game(config)
    game.board.initialize_board()
    print("Welcome to Tavli!")

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

        # Do the move
        game.board.apply(chosen_move)

        print("Move applied. Thank you!")

        winner = game.check_winner(game.current_player.color)
        if winner:
            display_board(game.board)
            print(f"{game.current_player.name} ({game.current_player.color}) has won the game!")
            break

        game.switch_turn()


if __name__ == "__main__":
    main()