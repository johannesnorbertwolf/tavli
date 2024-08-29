import torch
from typing import List, Optional
from domain.tavli.move import Move
from board_encoder import BoardEncoder
from board_evaluator import BoardEvaluator


class Agent:
    def __init__(self, model: BoardEvaluator, encoder: BoardEncoder, color: Color):
        self.model = model
        self.encoder = encoder
        self.color = color

    def evaluate_moves(self, possible_moves: List[Move], board: GameBoard) -> Optional[Move]:
        best_move = None
        best_score = -float('inf')

        for move in possible_moves:
            # Apply the move to get the new board state
            board.apply(move)

            # Encode the new board state
            encoded_board = self.encoder.encode_board(board)
            encoded_board_tensor = torch.tensor(encoded_board, dtype=torch.float32).unsqueeze(0)  # Add batch dimension

            # Get the score from the neural network
            score = self.model(encoded_board_tensor).item()

            # Revert the move to get back to the original board state
            board.undo(move)

            # Select the move with the highest score
            if score > best_score:
                best_score = score
                best_move = move

        return best_move