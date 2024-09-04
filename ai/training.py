import torch
import random
import numpy as np
from collections import deque
from typing import List, Tuple
from domain.board import GameBoard
from domain.move import Move
from domain.color import Color
from domain.possible_moves import PossibleMoves
from ai.agent import Agent
from ai.board_encoder import BoardEncoder
from ai.board_evaluator import BoardEvaluator
from game.game import Game


class TDLearner:
    def __init__(self, config, learning_rate=0.001, discount_factor=0.95, batch_size=64):
        self.config = config
        self.board_encoder = BoardEncoder(config)
        self.board_evaluator = BoardEvaluator(config)
        self.optimizer = torch.optim.Adam(self.board_evaluator.parameters(), lr=learning_rate)
        self.discount_factor = discount_factor
        self.batch_size = batch_size
        self.replay_buffer = deque(maxlen=10000)

    def train(self, num_episodes: int):
        for episode in range(num_episodes):
            self.play_episode()
            if len(self.replay_buffer) >= self.batch_size:
                self.update_model()

            if episode % 100 == 0:
                print(f"Episode {episode} completed")

    def play_episode(self):
        game = Game(self.config)
        agent = Agent(self.board_evaluator, self.board_encoder)
        game_history = []

        while True:
            current_state = game.board
            possible_moves_generator = PossibleMoves(current_state, game.current_player.color, game.dice)
            possible_moves = possible_moves_generator.find_moves()

            if not possible_moves:
                game.switch_turn()
                continue

            move = agent.get_best_move(current_state, possible_moves, game.current_player.color)
            game.board.apply(move)

            game_history.append((current_state, move, game.current_player.color))

            # Check for a winner after each move
            if game.check_winner(game.current_player.color):
                break

            game.switch_turn()
            game.dice.roll()

        # Process game history
        winner_color = game.current_player.color
        self.process_game_history(game_history, winner_color)

    def process_game_history(self, game_history: List[Tuple[GameBoard, Move, Color]], winner_color: Color):
        for i, (state, move, color) in enumerate(reversed(game_history)):
            reward = 1.0 if color == winner_color else 0.0
            discounted_reward = reward * (self.discount_factor ** i)

            encoded_state = self.board_encoder.encode_board(state, color == Color.WHITE)
            self.replay_buffer.append((encoded_state, move, discounted_reward))

    def update_model(self):
        batch = random.sample(self.replay_buffer, self.batch_size)
        states, moves, rewards = zip(*batch)

        states_tensor = torch.FloatTensor(np.array(states))
        rewards_tensor = torch.FloatTensor(rewards)

        predicted_values = self.board_evaluator(states_tensor).squeeze()
        loss = torch.mean((rewards_tensor - predicted_values) ** 2)

        self.optimizer.zero_grad()
        loss.backward()
        self.optimizer.step()


