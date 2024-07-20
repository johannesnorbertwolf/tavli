# main.py

from tavli.game import Game

def display_board(board):
    print("\nCurrent Board State:")
    for point in range(1, 25):
        print(f"{point}: {board.points[point]}")
    print("\n")

def main():
    game = Game()
    game.board.initialize_board()
    print("Welcome to Tavli!")

    while True:
        display_board(game.board)
        print(f"{game.current_player.name}'s turn ({game.current_player.get_color})")

        try:
            from_point = int(input("Enter the point to move from: "))
            to_point = int(input("Enter the point to move to: "))
        except ValueError:
            print("Invalid input. Please enter valid point numbers.")
            continue

        game.play_turn(from_point, to_point)

        winner = game.check_winner()
        if winner:
            display_board(game.board)
            print(f"{winner.name} ({winner.get_color}) has won the game!")
            break

        game.switch_turn()

if __name__ == "__main__":
    main()