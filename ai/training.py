import torch
import numpy as np
from collections import deque
import random
from typing import List, Tuple
from domain.board import GameBoard
from domain.move import Move
from domain.color import Color
from domain.possible_moves import PossibleMoves
from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from ai.evaluator import AIEvaluator
from game.game import Game
from tqdm import tqdm
import copy
from torch.optim.lr_scheduler import ReduceLROnPlateau

class RandomAgent:
    def get_move(self, possible_moves):
        return random.choice(possible_moves)

class SelfPlayTDLearner:
    def __init__(self, config):
        self.config = config
        self.board_encoder = BoardEncoder(config)
        self.board_evaluator = BoardEvaluator(config)
        self.optimizer = torch.optim.Adam(self.board_evaluator.parameters(), 
                                          lr=config.get_learning_rate(),
                                          weight_decay=1e-5)
        self.discount_factor = config.get_discount_factor()
        self.batch_size = config.get_batch_size()
        self.replay_buffer = deque(maxlen=config.get_replay_buffer_size())
        self.agent = Agent(self.board_evaluator, self.board_encoder)

        self.scheduler = ReduceLROnPlateau(self.optimizer, mode='min', factor=0.1, patience=1000, verbose=True)

        # Epsilon-greedy exploration
        self.epsilon = config.get_epsilon_start()
        self.epsilon_end = config.get_epsilon_end()
        self.epsilon_decay = config.get_epsilon_decay()

        self.evaluator = AIEvaluator(config, self.board_evaluator, self.board_encoder)

    def train(self, num_episodes: int):
        for episode in tqdm(range(num_episodes), desc="Training Progress"):
            self.play_self_play_episode()
            if len(self.replay_buffer) >= self.batch_size:
                loss = self.update_model()
                if episode % self.config.get_evaluation_frequency() == 0:
                    print(f"Episode {episode} completed. Loss: {loss:.4f}")
                    self.save_model(f"model_checkpoint_{episode}.pth")

                    self.evaluator.evaluate_against_random(episode, self.config.get_evaluation_games())

            # Decay epsilon
            self.epsilon = max(self.epsilon_end, self.epsilon * self.epsilon_decay)


    def play_self_play_episode(self):
        game = Game(self.config)
        game_history = []

        while not game.check_winner(game.current_player):
            game.switch_turn()
            game.dice.roll()

            current_state = game.board
            possible_moves = PossibleMoves(current_state, game.current_player, game.dice).find_moves()

            if not possible_moves:
                continue

            # Epsilon-greedy move selection
            if random.random() < self.epsilon:
                chosen_move = random.choice(possible_moves)
                _, score = self.agent.get_best_move(current_state, [chosen_move], game.current_player)
            else:
                chosen_move, score = self.agent.get_best_move(current_state, possible_moves, game.current_player)

            game.board.apply(chosen_move)

            game_history.append((copy.deepcopy(game.board), chosen_move, game.current_player, score))

        winner_color = game.current_player
        self.process_game_history(game_history, winner_color)

    def process_game_history(self, game_history: List[Tuple[GameBoard, Move, Color, float]], winner_color: Color):
        for i, (state, move, color, move_score) in enumerate(reversed(game_history)):
            # is last move of the game
            if i == 0:
                discounted_reward = 0 if winner_color == Color.WHITE else 1
            else:
                reward_from_next_move_score = game_history[-i][3]

                reward_for_winning = 0 if winner_color == Color.WHITE else 1

                discount = self.discount_factor ** i

                discounted_reward = reward_for_winning * discount + reward_from_next_move_score * (1 - discount)

            encoded_state = self.board_encoder.encode_board(state, color == Color.WHITE)
            self.replay_buffer.append((encoded_state, move, discounted_reward))

    def update_model(self):
        batch = random.sample(self.replay_buffer, min(self.batch_size, len(self.replay_buffer)))
        states, moves, rewards = zip(*batch)

        states_tensor = torch.FloatTensor(np.array(states))
        rewards_tensor = torch.FloatTensor(rewards)

        predicted_values = self.board_evaluator(states_tensor).squeeze()
        loss = torch.mean((rewards_tensor - predicted_values) ** 2)

        self.optimizer.zero_grad()
        loss.backward()
        self.optimizer.step()
        self.scheduler.step(loss)
        return loss.item()

    def save_model(self, filename):
        torch.save(self.board_evaluator.state_dict(), filename)

    def load_model(self, filename):
        self.board_evaluator.load_state_dict(torch.load(filename))

    def evaluate_against_random(self, num_games: int) -> int:
        wins = 0
        ai_agent = Agent(self.board_evaluator, self.board_encoder)

        for _ in range(num_games):
            game = Game(self.config)

            while not game.check_winner(game.current_player):
                game.dice.roll()
                possible_moves = PossibleMoves(game.board, game.current_player, game.dice).find_moves()

                if not possible_moves:
                    game.switch_turn()
                    continue

                if game.current_player.is_white():
                    move, _ = ai_agent.get_best_move(game.board, possible_moves, game.current_player)
                else:
                    move = self.random_agent.get_move(possible_moves)

                game.board.apply(move)

                if game.check_winner(game.current_player):
                    if game.current_player.is_white():
                        wins += 1
                    break

                game.switch_turn()

        return wins