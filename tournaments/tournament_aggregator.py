"""Aggregate tournament results and compute statistics."""
from typing import List, Dict
import math


class TournamentAggregator:
    """Compute aggregated statistics across multiple tournament runs."""

    def __init__(self, all_results: List[Dict]):
        """
        Args:
            all_results: List of tournament result dicts
        """
        self.results = all_results

    def compute_aggregates(self) -> Dict[str, Dict]:
        """Compute statistics for each model across all tournament runs.

        Returns dict mapping model name to stats dict with keys:
            - total_games, wins, losses, win_rate
            - white_wins, black_wins, white_wr, black_wr
            - elo
            - ci_low, ci_high (95% confidence interval)
        """
        models = set()
        for tourney in self.results:
            for match in tourney["matches"]:
                models.add(match["model_a"])
                models.add(match["model_b"])

        aggregates = {}
        for model in sorted(models):
            aggregates[model] = self._stats_for_model(model)

        return aggregates

    def _stats_for_model(self, model_name: str) -> Dict:
        """Aggregate statistics for one model across all tournaments."""
        wins = 0
        losses = 0
        white_wins = 0
        black_wins = 0

        for tourney in self.results:
            for match in tourney["matches"]:
                if model_name not in (match["model_a"], match["model_b"]):
                    continue

                for game in match["games"]:
                    is_winner = game["winner"] == model_name
                    is_model_a = model_name == match["model_a"]

                    if is_winner:
                        wins += 1
                        # Track white/black wins
                        if game["a_color"] == "WHITE" and is_model_a:
                            white_wins += 1
                        elif game["a_color"] == "BLACK" and not is_model_a:
                            white_wins += 1
                        else:
                            black_wins += 1
                    else:
                        losses += 1

        total_games = wins + losses
        win_rate = wins / total_games if total_games > 0 else 0.0
        white_wr = white_wins / (white_wins + black_wins) if (white_wins + black_wins) > 0 else 0.0

        ci_low, ci_high = self._binomial_ci(wins, total_games, 0.95)
        elo = self._estimate_elo(wins, losses)

        return {
            "total_games": total_games,
            "wins": wins,
            "losses": losses,
            "win_rate": win_rate,
            "white_wins": white_wins,
            "black_wins": black_wins,
            "white_wr": white_wr,
            "elo": elo,
            "ci_low": ci_low,
            "ci_high": ci_high
        }

    def _binomial_ci(self, successes: int, trials: int, confidence: float = 0.95) -> tuple:
        """Compute binomial confidence interval using normal approximation."""
        if trials == 0:
            return 0.0, 0.0

        p = successes / trials
        z = 1.96 if confidence == 0.95 else 2.576  # z-score for 95% and 99%
        margin = z * math.sqrt(p * (1 - p) / trials)

        return max(0, p - margin), min(1, p + margin)

    def _estimate_elo(self, wins: int, losses: int) -> int:
        """Estimate ELO rating from wins/losses.

        Simple approximation: assumes 1200 baseline for 50% win rate.
        """
        if wins + losses == 0:
            return 1200

        win_rate = wins / (wins + losses)
        # ELO formula: rating = 1200 + (win_rate - 0.5) * 800
        elo = 1200 + (win_rate - 0.5) * 800
        return int(elo)

    def compute_head_to_head(self) -> Dict[str, Dict[str, Dict]]:
        """Compute head-to-head records between all pairs.

        Returns dict: model_a -> model_b -> {'wins': int, 'losses': int, 'wr': float}
        """
        h2h = {}

        for tourney in self.results:
            for match in tourney["matches"]:
                a, b = match["model_a"], match["model_b"]

                if a not in h2h:
                    h2h[a] = {}
                if b not in h2h:
                    h2h[b] = {}
                if b not in h2h[a]:
                    h2h[a][b] = {"wins": 0, "losses": 0}
                if a not in h2h[b]:
                    h2h[b][a] = {"wins": 0, "losses": 0}

                for game in match["games"]:
                    if game["winner"] == a:
                        h2h[a][b]["wins"] += 1
                        h2h[b][a]["losses"] += 1
                    else:
                        h2h[a][b]["losses"] += 1
                        h2h[b][a]["wins"] += 1

        # Add win rates
        for a in h2h:
            for b in h2h[a]:
                total = h2h[a][b]["wins"] + h2h[a][b]["losses"]
                h2h[a][b]["wr"] = h2h[a][b]["wins"] / total if total > 0 else 0.5

        return h2h

    def compute_placement_frequency(self) -> Dict[str, Dict[int, int]]:
        """Compute how often each model finishes in each placement.

        Returns dict: model_name -> {1: count, 2: count, ..., 9: count}
        """
        # Get all model names
        models = set()
        for tourney in self.results:
            for match in tourney["matches"]:
                models.add(match["model_a"])
                models.add(match["model_b"])
        models = sorted(list(models))

        # Track placements per tournament
        placement_freq = {model: {i: 0 for i in range(1, len(models) + 1)} for model in models}

        for tourney in self.results:
            # Compute standings for this tournament
            wins_by_model = {model: 0 for model in models}

            for match in tourney["matches"]:
                a, b = match["model_a"], match["model_b"]
                for game in match["games"]:
                    if game["winner"] == a:
                        wins_by_model[a] += 1
                    else:
                        wins_by_model[b] += 1

            # Rank models by wins (handle ties)
            sorted_models = sorted(
                wins_by_model.items(),
                key=lambda x: x[1],
                reverse=True
            )

            # Assign placements (handle ties)
            current_placement = 1
            last_wins = None
            tied_models = []

            for model, wins in sorted_models:
                if last_wins is not None and wins < last_wins:
                    # Assign tied models same placement
                    for tied_model in tied_models:
                        placement_freq[tied_model][current_placement] += 1
                    current_placement += len(tied_models)
                    tied_models = []

                tied_models.append(model)
                last_wins = wins

            # Handle last group of tied models
            if tied_models:
                for tied_model in tied_models:
                    placement_freq[tied_model][current_placement] += 1

        return placement_freq
