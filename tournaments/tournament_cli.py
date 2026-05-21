"""CLI interface for tournament system."""
import sys
import argparse
from tournaments.tournament_runner import run_tournaments
from tournaments.tournament_aggregator import TournamentAggregator
from tournaments.tournament_reporter import TournamentReporter


def run_tournament_cli(config, args):
    """Entry point for tournament command from main.py."""
    parser = argparse.ArgumentParser(description="Run round-robin tournaments")
    parser.add_argument(
        "--num-runs",
        type=int,
        default=100,
        help="Number of tournament runs (default: 100)"
    )
    parser.add_argument(
        "--games-per-matchup",
        type=int,
        default=2,
        help="Games per matchup (default: 2)"
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducibility (default: None)"
    )
    parser.add_argument(
        "--parallelism",
        type=int,
        default=6,
        help="Number of parallel workers (default: 6)"
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default="tournament_results",
        help="Output directory (default: tournament_results)"
    )

    parsed_args = parser.parse_args(args)

    print(f"\n{'='*60}")
    print("TOURNAMENT RUNNER")
    print(f"{'='*60}")
    print(f"Num runs:           {parsed_args.num_runs}")
    print(f"Games per matchup:  {parsed_args.games_per_matchup}")
    print(f"Seed:               {parsed_args.seed}")
    print(f"Parallelism:        {parsed_args.parallelism}")
    print(f"Output dir:         {parsed_args.output_dir}")
    print(f"{'='*60}\n")

    # Run tournaments
    results, models = run_tournaments(
        config,
        num_runs=parsed_args.num_runs,
        games_per_matchup=parsed_args.games_per_matchup,
        base_seed=parsed_args.seed,
        parallelism=parsed_args.parallelism,
        models_dir="models"
    )

    print(f"✓ Completed {parsed_args.num_runs} tournament runs")

    # Aggregate results
    aggregator = TournamentAggregator(results)
    aggregates = aggregator.compute_aggregates()
    h2h = aggregator.compute_head_to_head()
    placement_freq = aggregator.compute_placement_frequency()

    print(f"✓ Aggregated results for {len(aggregates)} models")

    # Generate reports
    reporter = TournamentReporter(output_dir=parsed_args.output_dir)
    reporter.save_raw_results(results)
    reporter.save_csv_results(aggregates)
    reporter.save_head_to_head_csv(h2h)
    reporter.save_placement_frequency_json(placement_freq)
    reporter.generate_summary_html(aggregates)
    reporter.generate_elo_evolution_chart(results)
    reporter.generate_placement_frequency_chart(placement_freq)
    reporter.generate_head_to_head_matrix(h2h, results)

    print(f"✓ Generated reports in {parsed_args.output_dir}/")
    print(f"\nResults:")
    print(f"  - Summary table:           {parsed_args.output_dir}/html/summary.html")
    print(f"  - ELO evolution:           {parsed_args.output_dir}/html/elo_evolution.html")
    print(f"  - Placement frequency:     {parsed_args.output_dir}/html/placement_frequency.html")
    print(f"  - Head-to-head matrix:     {parsed_args.output_dir}/html/head_to_head_matrix.html")
    print(f"  - CSV results:             {parsed_args.output_dir}/aggregated_results.csv")
    print(f"  - Match matrix CSV:        {parsed_args.output_dir}/match_matrix.csv")
    print(f"\nTop 3 models by ELO:")
    sorted_models = sorted(
        aggregates.items(),
        key=lambda x: x[1]["elo"],
        reverse=True
    )[:3]
    for i, (model, stats) in enumerate(sorted_models, 1):
        print(f"  {i}. {model}: {stats['elo']} ELO ({stats['win_rate']:.1%} WR)")
