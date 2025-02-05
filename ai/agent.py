import torch
import numpy as np
from typing import List
from domain.board import GameBoard
from domain.move import Move
from domain.color import Color

class Agent:
    def __init__(self, neural_network: torch.nn.Module, board_encoder):
        self.neural_network = neural_network
        self.board_encoder = board_encoder

    def evaluate_moves(self, board: GameBoard, possible_moves: List[Move], color: Color) -> List[float]:
        """
        Returns a list of scores for each possible move by applying and undoing each move.
        Encodes all board states and runs them through the neural network in a single batch.
        """
        encoded_boards = []

        for move in possible_moves:
            # Apply the move temporarily to the board
            board.apply(move)

            # Encode the new board state
            encoded_board = self.board_encoder.encode_board(board, color.is_white())
            encoded_boards.append(encoded_board)

            # Undo the move to restore the original board state
            board.undo(move)

        # Convert the list of encoded boards to a single NumPy array
        combined_encoded_boards = np.array(encoded_boards)

        # Convert the NumPy array to a tensor and pass it through the neural network in a batch
        input_tensor = torch.tensor(combined_encoded_boards, dtype=torch.float32)
        with torch.no_grad():
            scores = self.neural_network(input_tensor).squeeze()

            # Ensure we always return a list
            if scores.dim() == 0:
                return [scores.item()]
            else:
                return scores.tolist()


    def get_best_move(self, board: GameBoard, possible_moves: List[Move], color: Color) -> (Move, float):
        move_scores = self.evaluate_moves(board, possible_moves, color)
        if color == Color.BLACK:
            best_move_index = np.argmax(move_scores)
        else:  # White
            best_move_index = np.argmin(move_scores)
        return (possible_moves[best_move_index], move_scores[best_move_index])
