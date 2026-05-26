#!/usr/bin/env python3
"""Live monitor for tournament progress. Run in another terminal while tournaments run."""
import os
import json
import time
import sys
from pathlib import Path

# Handle imports when run as script or module
try:
    from tournaments.tournament_aggregator import TournamentAggregator
except ImportError:
    # Add parent dir to path if run directly
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from tournaments.tournament_aggregator import TournamentAggregator


def get_completed_tournaments(output_dir: str = "tournament_results") -> list:
    """Get list of completed tournament JSON files."""
    raw_dir = Path(output_dir) / "raw"
    if not raw_dir.exists():
        return []
    return sorted([f for f in raw_dir.glob("run_*.json")])


def load_results(json_files: list) -> list:
    """Load all tournament results from JSON files."""
    results = []
    for f in json_files:
        try:
            with open(f) as fh:
                results.append(json.load(fh))
        except (json.JSONDecodeError, IOError):
            pass
    return results


def print_status(output_dir: str = "tournament_results"):
    """Print current tournament status and rankings."""
    json_files = get_completed_tournaments(output_dir)
    num_completed = len(json_files)

    if num_completed == 0:
        print("No tournament results yet...")
        return

    results = load_results(json_files)
    aggregator = TournamentAggregator(results)
    aggregates = aggregator.compute_aggregates()

    # Compute tournament winners
    winners = {}
    for tourney in results:
        model_names = tourney["models"]
        wins_by_model = {model: 0 for model in model_names}

        for match in tourney["matches"]:
            a, b = match["model_a"], match["model_b"]
            for game in match["games"]:
                if game["winner"] == a:
                    wins_by_model[a] += 1
                else:
                    wins_by_model[b] += 1

        winner = max(wins_by_model.items(), key=lambda x: x[1])[0]
        winners[winner] = winners.get(winner, 0) + 1

    print(f"\n{'='*70}")
    print(f"TOURNAMENT PROGRESS: {num_completed} tournaments completed")
    print(f"{'='*70}")
    print(f"\nTournament Wins (who won how many tournaments):")
    for model in sorted(winners.keys(), key=lambda m: winners[m], reverse=True):
        count = winners[model]
        pct = 100 * count / num_completed
        bar = "█" * (count // max(1, num_completed // 20))
        print(f"  {model:12} {bar} {count:3d}/{num_completed} ({pct:5.1f}%)")

    # Sort by ELO
    sorted_models = sorted(
        aggregates.items(),
        key=lambda x: x[1]["elo"],
        reverse=True
    )

    print(f"\n{'Rank':<5} {'Model':<12} {'Games':<8} {'W-L':<12} {'WR':<8} {'ELO':<6} {'95% CI':<18}")
    print("-" * 70)

    for rank, (model, stats) in enumerate(sorted_models, 1):
        wins = stats["wins"]
        losses = stats["losses"]
        total = stats["total_games"]
        wr = stats["win_rate"]
        elo = stats["elo"]
        ci_low = stats["ci_low"]
        ci_high = stats["ci_high"]

        print(
            f"{rank:<5} {model:<12} {total:<8} {wins}-{losses:<10} "
            f"{wr:>6.1%} {elo:>6} {ci_low:.1%}–{ci_high:.1%}"
        )

    # Show color asymmetry
    print(f"\n{'Model':<12} {'WHITE WR':<12} {'BLACK WR':<12} {'Difference':<12}")
    print("-" * 48)
    for model, stats in sorted_models:
        white_wr = stats["white_wr"]
        black_wr = 1.0 - white_wr if stats["white_wins"] + stats["black_wins"] > 0 else 0.5
        diff = white_wr - black_wr
        print(f"{model:<12} {white_wr:>10.1%} {black_wr:>12.1%} {diff:>+11.1%}")

    print(f"\n✓ Last updated at {time.strftime('%H:%M:%S')}")


def watch_progress(output_dir: str = "tournament_results", interval: int = 10):
    """Watch and update progress every N seconds."""
    print("🎮 Tournament Monitor (Ctrl+C to stop)")
    print(f"Checking every {interval} seconds...\n")

    try:
        while True:
            print_status(output_dir)
            time.sleep(interval)
    except KeyboardInterrupt:
        print("\n👋 Monitor stopped")


if __name__ == "__main__":
    interval = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    watch_progress(interval=interval)
