import torch
import random
from typing import List, Tuple
from domain.board import GameBoard
from domain.color import Color
from domain.move import Move
from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder


class Agent:
    def __init__(self, board_evaluator: BoardEvaluator, board_encoder: BoardEncoder):
        self.board_evaluator = board_evaluator
        self.board_encoder = board_encoder

    def get_best_move(self, board: GameBoard, possible_moves: List[Move], color: Color) -> Tuple[Move, float]:
        if not possible_moves:
            return None, 0.0

        best_move = None
        min_opponent_eval = float('inf')
        
        self.board_evaluator.eval() # Set to evaluation mode

        # In the "after-state", it will be the opponent's turn.
        is_whites_turn_next = not color.is_white()

        for move in possible_moves:
            board.apply(move)
            
            encoded_board = self.board_encoder.encode_board(board, is_whites_turn=is_whites_turn_next)
            board_tensor = torch.from_numpy(encoded_board).float().unsqueeze(0)
            
            with torch.no_grad():
                # This value is the opponent's expected outcome.
                opponent_value = self.board_evaluator(board_tensor).item()

            if opponent_value < min_opponent_eval:
                min_opponent_eval = opponent_value
                best_move = move
            
            board.undo(move)

        self.board_evaluator.train() # Set back to training mode
        
        # The score to return should be from our perspective as win probability.
        our_best_score = 1.0 - min_opponent_eval if best_move is not None else float('-inf')
        
        return best_move, our_best_score

    def evaluate_moves(self, board: GameBoard, possible_moves: List[Move], color: Color) -> List[float]:
        scores = []
        self.board_evaluator.eval()  # Set to evaluation mode
        
        # In the "after-state", it will be the opponent's turn.
        is_whites_turn_next = not color.is_white()

        for move in possible_moves:
            board.apply(move)
            
            encoded_board = self.board_encoder.encode_board(board, is_whites_turn=is_whites_turn_next)
            board_tensor = torch.from_numpy(encoded_board).float().unsqueeze(0)

            with torch.no_grad():
                # This value is the opponent's expected outcome.
                opponent_value = self.board_evaluator(board_tensor).item()
            
            # The score from our perspective is our win probability.
            our_value = 1.0 - opponent_value
            scores.append(our_value)
            
            board.undo(move)
            
        self.board_evaluator.train() # Set back to training mode
        return scores

class RandomAgent:
    """An agent that chooses a move randomly from the possible moves."""
    def get_move(self, possible_moves: List[Move]) -> Move:
        return random.choice(possible_moves)
