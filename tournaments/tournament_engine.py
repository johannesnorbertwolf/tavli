"""Core tournament engine for round-robin games."""
import random
import numpy as np
import torch
from datetime import datetime
from typing import List, Dict, Tuple
from domain.constants import WHITE, BLACK
from game.game import Game
from domain.move_generation import legal_moves
from ai.checkpoint_io import load_agent_from_checkpoint


class TournamentEngine:
    """Runs a single round-robin tournament between multiple agents."""

    def __init__(self, config):
        self.config = config
        self.lookahead_plies = 1

    def run_tournament(self, models: List[Dict], games_per_matchup: int = 2, seed: int = None) -> Dict:
        """Run one complete round-robin tournament.

        Args:
            models: List of dicts with keys 'name' and 'path'
            games_per_matchup: Number of games per match (default 2)
            seed: Random seed for reproducibility

        Returns:
            Dict with 'matches' list and metadata
        """
        if seed is not None:
            random.seed(seed)
            np.random.seed(seed)

        results = {
            "tournament_id": f"tournament_{datetime.now().isoformat()}",
            "timestamp": datetime.now().isoformat(),
            "seed": seed,
            "games_per_matchup": games_per_matchup,
            "models": [m["name"] for m in models],
            "matches": []
        }

        # Load all agents once
        device = torch.device("cpu")
        agents = {}
        for model in models:
            agent, _ = load_agent_from_checkpoint(
                model["path"], self.config, device=device
            )
            agents[model["name"]] = agent

        # Round-robin: each pair plays games_per_matchup games
        model_count = len(models)
        for i in range(model_count):
            for j in range(i + 1, model_count):
                model_a, model_b = models[i], models[j]
                match_result = self._play_match(
                    agents[model_a["name"]], model_a["name"],
                    agents[model_b["name"]], model_b["name"],
                    games_per_matchup,
                    seed if seed is None else seed + i * 1000 + j
                )
                results["matches"].append(match_result)

        return results

    def _play_match(self, agent_a, name_a: str, agent_b, name_b: str,
                    num_games: int, seed: int) -> Dict:
        """Play num_games between two agents."""
        if seed is not None:
            random.seed(seed)
            np.random.seed(seed)

        match = {
            "model_a": name_a,
            "model_b": name_b,
            "games": []
        }

        for game_num in range(num_games):
            # Alternate starting colors
            color_a = WHITE if game_num % 2 == 0 else BLACK
            winner = self._play_single_game(
                agent_a, agent_b, color_a,
                seed if seed is None else seed + game_num
            )
            match["games"].append({
                "game_num": game_num + 1,
                "a_color": "WHITE" if color_a == WHITE else "BLACK",
                "winner": name_a if winner == color_a else name_b
            })

        return match

    def _play_single_game(self, agent_a, agent_b, color_a: int, seed: int = None) -> int:
        """Play one game between two agents. Returns winner color (WHITE or BLACK)."""
        if seed is not None:
            random.seed(seed)
            np.random.seed(seed)

        game = Game(self.config, starting_player=WHITE)

        while not game.is_over():
            current_player = game.current_player
            game.dice.roll()
            possible_moves = legal_moves(game.board, current_player, game.dice)

            if not possible_moves:
                game.switch_turn()
                continue

            # Choose agent based on current player
            if current_player == color_a:
                agent = agent_a
            else:
                agent = agent_b

            # Get best move with 1-ply lookahead
            move, _ = agent.get_best_move(
                game.board, possible_moves, current_player,
                lookahead_plies=self.lookahead_plies
            )
            game.board.apply(move, current_player)
            game.switch_turn()

        return game.get_winner()
