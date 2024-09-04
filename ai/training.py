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
from game.game import Game
from tqdm import tqdm

class RandomAgent:
    def get_best_move(self, possible_moves):
        return random.choice(possible_moves)

class SelfPlayTDLearner:
    def __init__(self, config, learning_rate=0.001, discount_factor=0.95, batch_size=64):
        self.config = config
        self.board_encoder = BoardEncoder(config)
        self.board_evaluator = BoardEvaluator(config)
        self.optimizer = torch.optim.Adam(self.board_evaluator.parameters(), lr=learning_rate)
        self.discount_factor = discount_factor
        self.batch_size = batch_size
        self.replay_buffer = deque(maxlen=10000)
        self.random_agent = RandomAgent()

    def train(self, num_episodes: int):
        for episode in tqdm(range(num_episodes), desc="Training Progress"):
            self.play_self_play_episode()
            if len(self.replay_buffer) >= self.batch_size:
                loss = self.update_model()
                if episode % 100 == 0:
                    print(f"Episode {episode} completed. Loss: {loss:.4f}")
                    self.save_model(f"model_checkpoint_{episode}.pth")

                    # Evaluate against random agent after each episode
                    wins = self.evaluate_against_random(num_games=10)
                    print(f"Episode {episode}: Won {wins}/10 games against random agent")


    def play_self_play_episode(self):
        game = Game(self.config)
        agent = Agent(self.board_evaluator, self.board_encoder)
        game_history = []

        while not game.check_winner(game.current_player.color):
            current_state = game.board
            possible_moves = PossibleMoves(current_state, game.current_player.color, game.dice).find_moves()

            if not possible_moves:
                game.switch_turn()
                game.dice.roll()
                continue

            move = agent.get_best_move(current_state, possible_moves, game.current_player.color)
            game.board.apply(move)

            game_history.append((current_state, move, game.current_player.color))

            game.switch_turn()
            game.dice.roll()

        winner_color = game.current_player.color
        self.process_game_history(game_history, winner_color)

    def process_game_history(self, game_history: List[Tuple[GameBoard, Move, Color]], winner_color: Color):
        for i, (state, move, color) in enumerate(reversed(game_history)):
            reward = 1.0 if color == winner_color else 0.0
            discounted_reward = reward * (self.discount_factor ** i)

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
            current_player = Color.WHITE  # AI always plays as White for consistency

            while not game.check_winner(game.current_player.color):
                game.dice.roll()
                possible_moves = PossibleMoves(game.board, game.current_player.color, game.dice).find_moves()

                if not possible_moves:
                    game.switch_turn()
                    current_player = Color.BLACK if current_player == Color.WHITE else Color.WHITE
                    continue

                if current_player == Color.WHITE:
                    move = ai_agent.get_best_move(game.board, possible_moves, current_player)
                else:
                    move = self.random_agent.get_best_move(possible_moves)

                game.board.apply(move)

                if game.check_winner(game.current_player.color):
                    if current_player == Color.WHITE:
                        wins += 1
                    break

                game.switch_turn()
                current_player = Color.BLACK if current_player == Color.WHITE else Color.WHITE

        return wins