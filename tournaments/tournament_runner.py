"""Orchestrates multiple tournament runs with multiprocessing."""
import os
import re
import json
from pathlib import Path
from multiprocessing import Pool
from typing import List, Dict
from tournaments.tournament_engine import TournamentEngine


def discover_gold_models(models_dir: str = "models") -> List[Dict]:
    """Find all gold_v*.pth files, sorted by version number.

    Returns list of dicts with keys 'name', 'path', 'version'
    """
    pattern = re.compile(r"gold_v(\d+)\.pth")
    models = []

    for f in sorted(os.listdir(models_dir)):
        match = pattern.match(f)
        if match:
            version = int(match.group(1))
            models.append({
                "name": f"gold_v{version}",
                "path": os.path.join(models_dir, f),
                "version": version
            })

    return sorted(models, key=lambda m: m["version"])


def run_single_tournament(args: tuple) -> Dict:
    """Run one tournament (called by multiprocessing pool).

    Args:
        args: (run_id, models, games_per_matchup, base_seed, config)

    Returns:
        Tournament result dict
    """
    run_id, models, games_per_matchup, base_seed, config = args
    seed = base_seed + run_id if base_seed is not None else None

    engine = TournamentEngine(config)
    result = engine.run_tournament(models, games_per_matchup=games_per_matchup, seed=seed)
    result["run_id"] = run_id

    # Determine tournament winner
    model_names = [m["name"] for m in models]
    wins_by_model = {model: 0 for model in model_names}

    for match in result["matches"]:
        a, b = match["model_a"], match["model_b"]
        for game in match["games"]:
            if game["winner"] == a:
                wins_by_model[a] += 1
            else:
                wins_by_model[b] += 1

    winner = max(wins_by_model.items(), key=lambda x: x[1])
    winner_name = winner[0]
    winner_wins = winner[1]
    total_games = sum(wins_by_model.values())

    # Print progress with winner
    print(f"  ✓ Tournament {run_id + 1:3d} complete — {winner_name} wins ({winner_wins}/{total_games})", flush=True)
    return result


def run_tournaments(
    config,
    num_runs: int = 100,
    games_per_matchup: int = 2,
    base_seed: int = None,
    parallelism: int = 6,
    models_dir: str = "models"
) -> tuple:
    """Run multiple tournaments in parallel.

    Returns:
        (results_list, models_list)
    """
    models = discover_gold_models(models_dir)
    if not models:
        raise ValueError(f"No gold models found in {models_dir}")

    print(f"Found {len(models)} gold models: {[m['name'] for m in models]}")
    print(f"Running {num_runs} tournaments with {len(models)} models...")
    print(f"  Games per matchup: {games_per_matchup}")
    print(f"  Parallel workers: {parallelism}")

    # Prepare arguments for pool
    pool_args = [
        (run_id, models, games_per_matchup, base_seed, config)
        for run_id in range(num_runs)
    ]

    # Run tournaments in parallel
    with Pool(processes=parallelism) as pool:
        results = pool.map(run_single_tournament, pool_args)

    return results, models
