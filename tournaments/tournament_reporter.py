"""Generate visualizations and reports from tournament results."""
import os
import csv
import json
from typing import List, Dict
from tournaments.tournament_aggregator import TournamentAggregator


class TournamentReporter:
    """Generate reports and visualizations from aggregated tournament data."""

    def __init__(self, output_dir: str = "tournament_results"):
        self.output_dir = output_dir
        self._ensure_output_dirs()

    def _ensure_output_dirs(self):
        """Create output directories if they don't exist."""
        os.makedirs(os.path.join(self.output_dir, "raw"), exist_ok=True)
        os.makedirs(os.path.join(self.output_dir, "html"), exist_ok=True)

    def save_raw_results(self, results: List[Dict]):
        """Save raw tournament JSON files."""
        for result in results:
            run_id = result.get("run_id", 0)
            filename = os.path.join(self.output_dir, "raw", f"run_{run_id:04d}.json")
            with open(filename, "w") as f:
                json.dump(result, f, indent=2)

    def save_csv_results(self, aggregates: Dict[str, Dict]):
        """Save aggregated results as CSV."""
        filename = os.path.join(self.output_dir, "aggregated_results.csv")
        with open(filename, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=[
                "model", "total_games", "wins", "losses", "win_rate",
                "white_wins", "black_wins", "white_wr", "elo",
                "ci_low", "ci_high"
            ])
            writer.writeheader()

            for model in sorted(aggregates.keys()):
                stats = aggregates[model]
                writer.writerow({
                    "model": model,
                    "total_games": stats["total_games"],
                    "wins": stats["wins"],
                    "losses": stats["losses"],
                    "win_rate": f"{stats['win_rate']:.4f}",
                    "white_wins": stats["white_wins"],
                    "black_wins": stats["black_wins"],
                    "white_wr": f"{stats['white_wr']:.4f}",
                    "elo": stats["elo"],
                    "ci_low": f"{stats['ci_low']:.4f}",
                    "ci_high": f"{stats['ci_high']:.4f}"
                })

    def save_head_to_head_csv(self, h2h: Dict[str, Dict[str, Dict]]):
        """Save head-to-head matrix as CSV."""
        filename = os.path.join(self.output_dir, "match_matrix.csv")
        models = sorted(h2h.keys())

        with open(filename, "w", newline="") as f:
            f.write("model_a,model_b,wins,losses,win_rate\n")
            for a in models:
                for b in models:
                    if a < b and b in h2h[a]:
                        row = h2h[a][b]
                        f.write(f"{a},{b},{row['wins']},{row['losses']},{row['wr']:.4f}\n")

    def generate_summary_html(self, aggregates: Dict[str, Dict]):
        """Generate summary table HTML."""
        models = sorted(aggregates.keys())
        html_parts = [
            "<!DOCTYPE html>",
            "<html>",
            "<head>",
            "  <meta charset='utf-8'>",
            "  <title>Tournament Rankings</title>",
            "  <style>",
            "    body { font-family: monospace; margin: 20px; }",
            "    table { border-collapse: collapse; margin: 20px 0; }",
            "    th, td { border: 1px solid #ccc; padding: 8px; text-align: right; }",
            "    th { background: #f0f0f0; font-weight: bold; }",
            "    td:first-child, th:first-child { text-align: left; }",
            "    .rank { font-weight: bold; width: 30px; }",
            "  </style>",
            "</head>",
            "<body>",
            "  <h1>Gold Model Tournament Rankings</h1>",
            "  <table>",
            "    <tr>",
            "      <th>Rank</th>",
            "      <th>Model</th>",
            "      <th>Games</th>",
            "      <th>Wins</th>",
            "      <th>Loss</th>",
            "      <th>Win Rate</th>",
            "      <th>ELO</th>",
            "      <th>95% CI</th>",
            "      <th>W: W/L</th>",
            "      <th>B: W/L</th>",
            "    </tr>"
        ]

        # Sort by ELO (descending)
        sorted_models = sorted(
            models,
            key=lambda m: aggregates[m]["elo"],
            reverse=True
        )

        for rank, model in enumerate(sorted_models, 1):
            stats = aggregates[model]
            html_parts.append("    <tr>")
            html_parts.append(f"      <td class='rank'>{rank}</td>")
            html_parts.append(f"      <td>{model}</td>")
            html_parts.append(f"      <td>{stats['total_games']}</td>")
            html_parts.append(f"      <td>{stats['wins']}</td>")
            html_parts.append(f"      <td>{stats['losses']}</td>")
            html_parts.append(f"      <td>{stats['win_rate']:.1%}</td>")
            html_parts.append(f"      <td>{stats['elo']}</td>")
            ci_str = f"{stats['ci_low']:.1%}–{stats['ci_high']:.1%}"
            html_parts.append(f"      <td>{ci_str}</td>")
            html_parts.append(f"      <td>{stats['white_wins']}/{stats['black_wins']}</td>")
            html_parts.append(f"      <td>{stats['white_wr']:.1%}</td>")
            html_parts.append("    </tr>")

        html_parts.extend([
            "  </table>",
            "</body>",
            "</html>"
        ])

        filename = os.path.join(self.output_dir, "html", "summary.html")
        with open(filename, "w") as f:
            f.write("\n".join(html_parts))

    def generate_elo_evolution_chart(self, results: List[Dict]):
        """Generate ELO evolution chart (HTML with Chart.js)."""
        # Compute ELO for each model at each tournament run
        models = set()
        for result in results:
            for match in result["matches"]:
                models.add(match["model_a"])
                models.add(match["model_b"])

        models = sorted(list(models))

        # For each run, compute running ELO
        elo_by_run = {model: [] for model in models}

        for result in results:
            aggregator = TournamentAggregator([result])
            agg = aggregator.compute_aggregates()
            for model in models:
                if model in agg:
                    elo_by_run[model].append(agg[model]["elo"])
                else:
                    # Didn't play in this tournament (shouldn't happen in round-robin)
                    elo_by_run[model].append(elo_by_run[model][-1] if elo_by_run[model] else 1200)

        # Generate HTML with Chart.js
        html_parts = [
            "<!DOCTYPE html>",
            "<html>",
            "<head>",
            "  <meta charset='utf-8'>",
            "  <title>ELO Evolution</title>",
            "  <script src='https://cdn.jsdelivr.net/npm/chart.js'></script>",
            "  <style>",
            "    body { font-family: sans-serif; margin: 20px; }",
            "    #chart { max-width: 1200px; }",
            "  </style>",
            "</head>",
            "<body>",
            "  <h1>ELO Rating Evolution Across Tournaments</h1>",
            "  <canvas id='chart'></canvas>",
            "  <script>"
        ]

        # Build dataset colors
        colors = [
            "#FF6384", "#36A2EB", "#FFCE56", "#4BC0C0", "#9966FF",
            "#FF9F40", "#FF6384", "#C9CBCF", "#4BC0C0", "#FF6384"
        ]

        datasets = []
        for i, model in enumerate(models):
            color = colors[i % len(colors)]
            datasets.append({
                "label": model,
                "data": elo_by_run[model],
                "borderColor": color,
                "fill": False,
                "tension": 0.1
            })

        html_parts.append("    const ctx = document.getElementById('chart').getContext('2d');")
        html_parts.append("    const chart = new Chart(ctx, {")
        html_parts.append("      type: 'line',")
        html_parts.append("      data: {")
        html_parts.append(f"        labels: {list(range(1, len(results) + 1))},")
        html_parts.append(f"        datasets: {json.dumps(datasets)}")
        html_parts.append("      },")
        html_parts.append("      options: {")
        html_parts.append("        responsive: true,")
        html_parts.append("        plugins: {")
        html_parts.append("          legend: { position: 'top' }")
        html_parts.append("        },")
        html_parts.append("        scales: {")
        html_parts.append("          y: { beginAtZero: false, min: 1000, max: 1600 }")
        html_parts.append("        }")
        html_parts.append("      }")
        html_parts.append("    });")
        html_parts.extend([
            "  </script>",
            "</body>",
            "</html>"
        ])

        filename = os.path.join(self.output_dir, "html", "elo_evolution.html")
        with open(filename, "w") as f:
            f.write("\n".join(html_parts))

    def generate_placement_frequency_chart(self, placement_freq: Dict[str, Dict[int, int]]):
        """Generate placement frequency visualization (heatmap + table)."""
        if not placement_freq:
            return  # No results to visualize

        models = sorted(placement_freq.keys())
        num_models = len(models)

        # Generate HTML with heatmap (using CSS grid)
        html_parts = [
            "<!DOCTYPE html>",
            "<html>",
            "<head>",
            "  <meta charset='utf-8'>",
            "  <title>Placement Frequency</title>",
            "  <style>",
            "    body { font-family: sans-serif; margin: 20px; }",
            "    .heatmap { display: inline-block; margin-right: 40px; }",
            "    .grid { display: grid; gap: 1px; margin: 20px 0; background: #ccc; padding: 10px; }",
            "    .header-row { display: grid; gap: 1px; margin-bottom: -1px; font-weight: bold; }",
            "    .cell { padding: 8px; text-align: center; font-size: 12px; min-width: 30px; }",
            "    .label { padding: 8px; font-weight: bold; text-align: right; min-width: 80px; }",
            "    .count-0 { background: white; }",
            "    .count-1 { background: #f0f0ff; }",
            "    .count-2 { background: #e0e0ff; }",
            "    .count-3 { background: #d0d0ff; }",
            "    .count-4 { background: #b0b0ff; }",
            "    .count-5 { background: #9090ff; }",
            "    .count-high { background: #00cc00; color: white; }",
            "    table { border-collapse: collapse; margin-top: 40px; }",
            "    th, td { border: 1px solid #ccc; padding: 8px; text-align: right; }",
            "    th { background: #f0f0f0; font-weight: bold; }",
            "    td:first-child, th:first-child { text-align: left; }",
            "  </style>",
            "</head>",
            "<body>",
            "  <h1>Placement Frequency Heatmap</h1>",
            "  <p>Shows how often each model finished in each placement across all tournaments.</p>",
            "  <p>Brighter green = more frequent in that placement.</p>",
            "  <div class='heatmap'>"
        ]

        # Build heatmap grid
        max_count = max(max(freq.values()) for freq in placement_freq.values())

        # Header row
        html_parts.append("    <div style='display: grid; gap: 1px; margin-bottom: 10px;'>")
        html_parts.append("      <div class='label'></div>")
        for placement in range(1, num_models + 1):
            html_parts.append(f"      <div class='cell' style='font-weight: bold;'>{placement}</div>")
        html_parts.append("    </div>")

        # Data rows
        for model in models:
            html_parts.append("    <div style='display: grid; gap: 1px; margin-bottom: 10px;'>")
            html_parts.append(f"      <div class='label'>{model}</div>")
            for placement in range(1, num_models + 1):
                count = placement_freq[model].get(placement, 0)
                if count == 0:
                    color_class = "count-0"
                elif count >= max_count * 0.7:
                    color_class = "count-high"
                else:
                    intensity = int((count / max_count) * 6)
                    color_class = f"count-{intensity}"
                html_parts.append(f"      <div class='cell {color_class}'>{count}</div>")
            html_parts.append("    </div>")

        html_parts.extend([
            "  </div>",
            "  <h2>Placement Frequency Table</h2>",
            "  <table>",
            "    <tr>",
            "      <th>Model</th>"
        ])

        for i in range(1, num_models + 1):
            html_parts.append(f"      <th>{i}st/nd/rd/th</th>" if i == 1 else f"      <th>{i}</th>")

        html_parts.append("    </tr>")

        # Sort by average placement (lower is better)
        avg_placement = {}
        for model in models:
            total = sum(placement_freq[model].values())
            weighted_sum = sum(p * c for p, c in placement_freq[model].items())
            avg_placement[model] = weighted_sum / total if total > 0 else num_models

        sorted_models = sorted(models, key=lambda m: avg_placement[m])

        for model in sorted_models:
            html_parts.append("    <tr>")
            html_parts.append(f"      <td>{model}</td>")
            for placement in range(1, num_models + 1):
                count = placement_freq[model].get(placement, 0)
                html_parts.append(f"      <td>{count}</td>")
            html_parts.extend([
                "    </tr>"
            ])

        html_parts.extend([
            "  </table>",
            "</body>",
            "</html>"
        ])

        filename = os.path.join(self.output_dir, "html", "placement_frequency.html")
        with open(filename, "w") as f:
            f.write("\n".join(html_parts))

    def generate_head_to_head_matrix(self, h2h: Dict[str, Dict[str, Dict]], results: List[Dict]):
        """Generate head-to-head matrix with separate WHITE/BLACK win rates."""
        models = sorted(h2h.keys())

        html_parts = [
            "<!DOCTYPE html>",
            "<html>",
            "<head>",
            "  <meta charset='utf-8'>",
            "  <title>Head-to-Head Matrix</title>",
            "  <style>",
            "    body { font-family: monospace; margin: 20px; }",
            "    table { border-collapse: collapse; margin: 20px 0; }",
            "    th, td { border: 1px solid #999; padding: 6px 4px; text-align: center; font-size: 11px; width: 45px; height: 45px; }",
            "    th { background: #f0f0f0; font-weight: bold; writing-mode: vertical-rl; text-orientation: mixed; }",
            "    .row-header { text-align: left; background: #f0f0f0; font-weight: bold; width: 80px; }",
            "    .cell-content { display: flex; flex-direction: column; height: 100%; justify-content: space-around; font-size: 10px; }",
            "    .white-wr { color: #0066cc; font-weight: bold; }",
            "    .black-wr { color: #cc0000; font-weight: bold; }",
            "  </style>",
            "</head>",
            "<body>",
            "  <h1>Head-to-Head Win Rate Matrix</h1>",
            "  <p><strong style='color: #0066cc'>Blue = A's win % as WHITE</strong> | ",
            "  <strong style='color: #cc0000'>Red = A's win % as BLACK</strong></p>",
            "  <p>Read as: Row player vs Column player. Example: gold_v9 vs gold_v7 shows v9's win rates.</p>",
            "  <table>",
            "    <tr><th></th>"
        ]

        # Header row with model names
        for model in models:
            html_parts.append(f"      <th>{model}</th>")
        html_parts.append("    </tr>")

        # Data rows
        for model_a in models:
            html_parts.append("    <tr>")
            html_parts.append(f"      <td class='row-header'>{model_a}</td>")

            for model_b in models:
                if model_a == model_b:
                    html_parts.append("      <td>—</td>")
                else:
                    # Compute WHITE and BLACK win rates
                    white_wins = 0
                    white_total = 0
                    black_wins = 0
                    black_total = 0

                    for tourney in results:
                        for match in tourney["matches"]:
                            if (match["model_a"] == model_a and match["model_b"] == model_b):
                                for game in match["games"]:
                                    if game["a_color"] == "WHITE":
                                        white_total += 1
                                        if game["winner"] == model_a:
                                            white_wins += 1
                                    else:  # BLACK
                                        black_total += 1
                                        if game["winner"] == model_a:
                                            black_wins += 1
                            elif (match["model_a"] == model_b and match["model_b"] == model_a):
                                for game in match["games"]:
                                    if game["a_color"] == "WHITE":
                                        black_total += 1
                                        if game["winner"] == model_a:
                                            black_wins += 1
                                    else:  # BLACK
                                        white_total += 1
                                        if game["winner"] == model_a:
                                            white_wins += 1

                    white_wr = (white_wins / white_total * 100) if white_total > 0 else 50
                    black_wr = (black_wins / black_total * 100) if black_total > 0 else 50

                    # Color cells based on win rate
                    def color_for_wr(wr):
                        if wr > 66:
                            return "background: #00cc00"  # bright green
                        elif wr > 55:
                            return "background: #ccff99"  # light green
                        elif wr < 34:
                            return "background: #ff3333"  # bright red
                        elif wr < 45:
                            return "background: #ffcccc"  # light red
                        else:
                            return "background: #ffff99"  # yellow (neutral)

                    style_white = color_for_wr(white_wr)
                    style_black = color_for_wr(black_wr)

                    html_parts.append(f"      <td style='{style_white} border-right: 3px solid {style_black};'>")
                    html_parts.append("        <div class='cell-content'>")
                    html_parts.append(f"          <div class='white-wr'>{white_wr:.0f}%</div>")
                    html_parts.append(f"          <div class='black-wr'>{black_wr:.0f}%</div>")
                    html_parts.append("        </div>")
                    html_parts.append("      </td>")

            html_parts.append("    </tr>")

        html_parts.extend([
            "  </table>",
            "</body>",
            "</html>"
        ])

        filename = os.path.join(self.output_dir, "html", "head_to_head_matrix.html")
        with open(filename, "w") as f:
            f.write("\n".join(html_parts))

    def save_placement_frequency_json(self, placement_freq: Dict[str, Dict[int, int]]):
        """Save placement frequency data as JSON."""
        filename = os.path.join(self.output_dir, "placement_frequency.json")
        with open(filename, "w") as f:
            json.dump(placement_freq, f, indent=2)
