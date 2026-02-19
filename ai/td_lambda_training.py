import torch
import torch.optim as optim
from ai.agent import Agent, RandomAgent
from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder
from domain.color import Color
from game.game import Game
import random
from tqdm import tqdm
import logging
from domain.possible_moves import PossibleMoves
import numpy as np

class TdLambdaTraining:
    def __init__(self, board_evaluator: BoardEvaluator, board_encoder: BoardEncoder, config):
        self.board_evaluator = board_evaluator
        self.board_encoder = board_encoder
        self.config = config
        self.agent = Agent(self.board_evaluator, self.board_encoder)
        self.random_agent = RandomAgent()

        # TD(Lambda) parameters
        self.alpha = self.config.get_alpha() # Learning rate
        self.lambda_ = self.config.get_lambda_start() # Lambda
        self.gamma = self.config.get_discount_factor() # Discount factor

    def train_one_game(self, verbose_log_file=None):
        game = Game(self.config)
        board_history = []
        log_fh = None
        if verbose_log_file:
            log_fh = open(verbose_log_file, 'w')

        eligibility_traces = {param: torch.zeros_like(param.data) for param in self.board_evaluator.parameters()}

        # Initial board state value
        encoded_board = self.board_encoder.encode_board(game.board, game.current_player == Color.WHITE)
        value_tensor = self.board_evaluator(torch.FloatTensor([encoded_board]))
        value = value_tensor.item()

        while not game.is_over():
            current_player = game.current_player
            dice = game.dice.roll()
            possible_moves_generator = PossibleMoves(game.board, current_player, game.dice)
            possible_moves = possible_moves_generator.find_moves()

            move, score = None, None
            if not possible_moves:
                # If there are no moves, the player must pass their turn.
                # The board state does not change, but the turn switches.
                game.switch_turn()
                move = "pass" # For logging purposes
            else:
                move, score = self.agent.get_best_move(game.board, possible_moves, current_player)
                
                # Apply move
                game.board.apply(move)
                game.switch_turn()
            
            # Get next state and its value
            reward = 0
            next_value = 0
            if game.is_over():
                winner = game.get_winner()
                if winner == Color.WHITE:
                    reward = 1
                elif winner == Color.BLACK:
                    reward = -1
            else:
                encoded_board_next = self.board_encoder.encode_board(game.board, game.current_player == Color.WHITE)
                next_value_tensor = self.board_evaluator(torch.FloatTensor([encoded_board_next]))
                next_value = next_value_tensor.item()

            # The `next_value` is from the opponent's perspective.
            # To get the value from the perspective of the player who just moved, we must negate it.
            next_value_from_mover_perspective = -next_value

            # The `reward` is also absolute (from WHITE's perspective).
            # We need to convert it to be from the perspective of the player who made the move.
            reward_from_mover_perspective = reward if current_player == Color.WHITE else -reward

            # Calculate TD error from the mover's perspective
            td_error = reward_from_mover_perspective + self.gamma * next_value_from_mover_perspective - value

            # Zero gradients for manual update
            self.board_evaluator.zero_grad()
            # Calculate gradient of the value function
            value_tensor.backward()
            
            # Update weights
            with torch.no_grad():
                for param in self.board_evaluator.parameters():
                    if param.grad is not None:
                        # Update eligibility traces
                        eligibility_traces[param] = self.gamma * self.lambda_ * eligibility_traces[param] + param.grad
                        # Update weights
                        param.data += self.alpha * td_error * eligibility_traces[param]

            # Update value for next iteration
            if not game.is_over():
                value_tensor = self.board_evaluator(torch.FloatTensor([encoded_board_next]))
                value = value_tensor.item()

            if log_fh:
                log_fh.write(f"Player: {current_player}\n")
                log_fh.write(f"Dice: {dice}\n")
                log_fh.write(f"Board:\n{game.board}\n")
                log_fh.write(f"Move chosen: {move}\n")
                if score is not None:
                    log_fh.write(f"Board score: {score}\n")
                log_fh.write(f"Lambda value: {self.lambda_}.\n")
                log_fh.write(f"TD Error: {td_error}\n")
                log_fh.write("-" * 20 + "\n")
        
        if log_fh:
            log_fh.write(f"Game over. Winner is {game.get_winner()}.\n")
            log_fh.close()


    def run_training_loop(self):
        self.board_evaluator.train()
        num_epochs = self.config.get_num_epochs()
        games_per_epoch = self.config.get_games_per_epoch()

        lambda_start = self.config.get_lambda_start()
        lambda_end = self.config.get_lambda_end()
        
        total_games = num_epochs * games_per_epoch

        for epoch in range(num_epochs):
            print(f"Epoch {epoch + 1}/{num_epochs}")
            for i in tqdm(range(games_per_epoch), desc=f"Training epoch {epoch+1}"):
                game_num = epoch * games_per_epoch + i
                is_last_game = (epoch == num_epochs - 1) and (i == games_per_epoch - 1)
                log_file = "last_game_log.txt" if is_last_game else None
                
                self.train_one_game(verbose_log_file=log_file)
                
                # Decay lambda
                self.lambda_ = lambda_end + (lambda_start - lambda_end) * np.exp(-1. * game_num / total_games * 10)
        
        # Save the model
        model_path = "trained_model.pth"
        torch.save(self.board_evaluator.state_dict(), model_path)
        print(f"Model saved to {model_path}")
