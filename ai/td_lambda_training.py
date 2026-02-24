import torch
from ai.agent import Agent
from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder
from domain.color import Color
from game.game import Game
from tqdm import tqdm
from domain.possible_moves import PossibleMoves
import numpy as np
import random

class ReplayBuffer:
    def __init__(self, max_size: int):
        self.max_size = max_size
        self.buffer = []
        self.position = 0

    def __len__(self):
        return len(self.buffer)

    def add(self, encoded_state, encoded_next_state, reward, mover_color, terminal):
        item = (encoded_state, encoded_next_state, reward, mover_color, terminal)
        if len(self.buffer) < self.max_size:
            self.buffer.append(item)
        else:
            self.buffer[self.position] = item
            self.position = (self.position + 1) % self.max_size

    def sample(self, batch_size: int):
        if not self.buffer:
            return []
        return random.sample(self.buffer, min(batch_size, len(self.buffer)))

class TdLambdaTraining:
    def __init__(self, board_evaluator: BoardEvaluator, board_encoder: BoardEncoder, config):
        self.board_evaluator = board_evaluator
        self.board_encoder = board_encoder
        self.config = config
        self.agent = Agent(self.board_evaluator, self.board_encoder)

        # TD(Lambda) parameters
        self.alpha = self.config.get_alpha() # Learning rate
        self.lambda_ = self.config.get_lambda_start() # Lambda
        self.gamma = self.config.get_discount_factor() # Discount factor
        self.epsilon_start = self.config.get_epsilon_start()
        self.epsilon = self.epsilon_start
        self.epsilon_end = self.config.get_epsilon_end()
        self.epsilon_decay = self.config.get_epsilon_decay()
        self.epsilon_decay_games = self.config.get_epsilon_decay_games()
        self.exploration_temperature = self.config.get_exploration_temperature()
        self.alpha_decay = self.config.get_alpha_decay()
        self.alpha_decay_every = self.config.get_alpha_decay_every()
        self.alpha_min = self.config.get_alpha_min()

        # Replay buffer settings (optional)
        self.replay_buffer_size = self.config.get_replay_buffer_size()
        self.replay_batch_size = self.config.get_replay_batch_size()
        self.replay_updates_per_game = self.config.get_replay_updates_per_game()
        self.replay_buffer = ReplayBuffer(self.replay_buffer_size) if self.replay_buffer_size > 0 else None

    def _select_move_self_play(self, board, possible_moves, current_player):
        if len(possible_moves) == 1:
            return possible_moves[0], None

        move_scores = self.agent.evaluate_moves(board, possible_moves, current_player)
        best_idx = int(np.argmax(move_scores))

        if np.random.random() >= self.epsilon:
            return possible_moves[best_idx], move_scores[best_idx]

        # Exploration: sample from softmax over model scores (still self-play).
        scores = np.array(move_scores, dtype=np.float64) / self.exploration_temperature
        scores -= np.max(scores)
        exp_scores = np.exp(scores)
        probs = exp_scores / np.sum(exp_scores)
        choice_idx = int(np.random.choice(len(possible_moves), p=probs))
        return possible_moves[choice_idx], move_scores[choice_idx]

    def _update_schedules(self, game_num):
        # Epsilon schedule
        if self.epsilon_decay_games and self.epsilon_decay_games > 0:
            progress = min(game_num + 1, self.epsilon_decay_games) / self.epsilon_decay_games
            self.epsilon = self.epsilon_start + (self.epsilon_end - self.epsilon_start) * progress
        else:
            self.epsilon = max(self.epsilon_end, self.epsilon * self.epsilon_decay)

        # Alpha schedule
        if self.alpha_decay_every and self.alpha_decay_every > 0:
            if (game_num + 1) % self.alpha_decay_every == 0:
                self.alpha = max(self.alpha_min, self.alpha * self.alpha_decay)

    def _td0_update_from_replay(self, batch):
        if not batch:
            return

        # Disable dropout for stable targets and gradients.
        self.board_evaluator.eval()

        for encoded_state, encoded_next_state, reward, mover_color, terminal in batch:
            state_tensor = torch.from_numpy(encoded_state).float().unsqueeze(0)

            value_tensor = self.board_evaluator(state_tensor)
            value = value_tensor.item()

            if terminal:
                next_value = 0.0
            else:
                with torch.no_grad():
                    next_tensor = torch.from_numpy(encoded_next_state).float().unsqueeze(0)
                    next_value = self.board_evaluator(next_tensor).item()

            if terminal:
                reward_from_mover_perspective = reward if mover_color == Color.WHITE else 1 - reward
                next_value_from_mover_perspective = 0.0
            else:
                reward_from_mover_perspective = 0.0
                next_value_from_mover_perspective = 1.0 - next_value

            td_error = reward_from_mover_perspective + self.gamma * next_value_from_mover_perspective - value

            self.board_evaluator.zero_grad()
            value_tensor.backward()

            with torch.no_grad():
                for param in self.board_evaluator.parameters():
                    if param.grad is not None:
                        param.data += self.alpha * td_error * param.grad

        self.board_evaluator.train()

    def train_one_game(self, verbose_log_file=None):
        game = Game(self.config)
        log_fh = None
        if verbose_log_file:
            log_fh = open(verbose_log_file, 'w')

        eligibility_traces = {param: torch.zeros_like(param.data) for param in self.board_evaluator.parameters()}

        # Initial board state value
        encoded_board = self.board_encoder.encode_board(game.board, game.current_player == Color.WHITE)
        self.board_evaluator.eval()
        value_tensor = self.board_evaluator(torch.from_numpy(encoded_board).float().unsqueeze(0))
        self.board_evaluator.train()
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
                move, score = self._select_move_self_play(game.board, possible_moves, current_player)
                
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
                    reward = 0
            else:
                encoded_board_next = self.board_encoder.encode_board(game.board, game.current_player == Color.WHITE)
                self.board_evaluator.eval()
                next_value_tensor = self.board_evaluator(torch.from_numpy(encoded_board_next).float().unsqueeze(0))
                self.board_evaluator.train()
                next_value = next_value_tensor.item()

            # Convert reward to mover's perspective (terminal only).
            if game.is_over():
                reward_from_mover_perspective = reward if current_player == Color.WHITE else 1 - reward
                next_value_from_mover_perspective = 0.0
            else:
                reward_from_mover_perspective = 0.0
                next_value_from_mover_perspective = 1.0 - next_value

            # Calculate TD error from the mover's perspective in probability space
            td_error = reward_from_mover_perspective + self.gamma * next_value_from_mover_perspective - value

            # Store transition for replay (optional)
            if self.replay_buffer is not None:
                if game.is_over():
                    encoded_board_next = encoded_board
                self.replay_buffer.add(
                    encoded_board,
                    encoded_board_next,
                    reward,
                    current_player,
                    game.is_over(),
                )

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
                self.board_evaluator.eval()
                value_tensor = self.board_evaluator(torch.from_numpy(encoded_board_next).float().unsqueeze(0))
                self.board_evaluator.train()
                value = value_tensor.item()
                encoded_board = encoded_board_next

            if log_fh:
                log_fh.write(f"Player: {current_player}\n")
                log_fh.write(f"Dice: {dice}\n")
                log_fh.write(f"Board:\n{game.board}\n")
                log_fh.write(f"Move chosen: {move}\n")
                if score is not None:
                    log_fh.write(f"Board score: {score}\n")
                log_fh.write(f"Lambda value: {self.lambda_}.\n")
                log_fh.write(f"Epsilon value: {self.epsilon}.\n")
                log_fh.write(f"TD Error: {td_error}\n")
                log_fh.write("-" * 20 + "\n")
        
        if log_fh:
            log_fh.write(f"Game over. Winner is {game.get_winner()}.\n")
            log_fh.close()

        # Replay updates after each game (optional)
        if self.replay_buffer is not None and self.replay_updates_per_game > 0:
            for _ in range(self.replay_updates_per_game):
                batch = self.replay_buffer.sample(self.replay_batch_size)
                self._td0_update_from_replay(batch)


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
                # Update epsilon and alpha schedules
                self._update_schedules(game_num)
        
        # Save the model
        model_path = "trained_model.pth"
        torch.save(self.board_evaluator.state_dict(), model_path)
        print(f"Model saved to {model_path}")
