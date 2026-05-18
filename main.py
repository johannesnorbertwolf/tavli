import os
import sys
import random
import math
import re
import statistics
from datetime import datetime
import numpy as np
import torch

from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder
from ai.checkpoint_io import load_agent_from_checkpoint, load_state_dict, ENCODER_VERSION_CURRENT
from config.config_loader import ConfigLoader
from ai.td_lambda_training import TdLambdaTraining
from domain.possible_moves import PossibleMoves
from game.game import Game
from ai.agent import RandomAgent
from domain.color import Color


def _percentile(sorted_values, p):
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    idx = (len(sorted_values) - 1) * p
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return float(sorted_values[lo])
    frac = idx - lo
    return float(sorted_values[lo] * (1.0 - frac) + sorted_values[hi] * frac)


def analyze_gold_log_last_x(last_x=50, log_path="training_runs/eval_gold_history.log"):
    if last_x <= 0:
        print("Invalid x. Please provide a positive integer.")
        return
    if not os.path.exists(log_path):
        print(f"Gold eval log not found: {log_path}")
        return

    pattern = re.compile(
        r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}).*?"
        r"white=(?P<white>[0-9]*\.?[0-9]+)\s+"
        r"black=(?P<black>[0-9]*\.?[0-9]+)\s+"
        r"avg=(?P<avg>[0-9]*\.?[0-9]+)"
    )
    rows = []
    with open(log_path, "r") as fh:
        for line in fh:
            m = pattern.search(line.strip())
            if not m:
                continue
            rows.append(
                {
                    "timestamp": m.group("ts"),
                    "white": float(m.group("white")),
                    "black": float(m.group("black")),
                    "avg": float(m.group("avg")),
                }
            )

    if not rows:
        print(f"No valid eval rows found in {log_path}.")
        return

    selected = rows[-last_x:]
    used = len(selected)
    avgs = [r["avg"] for r in selected]
    whites = [r["white"] for r in selected]
    blacks = [r["black"] for r in selected]
    sorted_avgs = sorted(avgs)

    mean_avg = sum(avgs) / used
    median_avg = statistics.median(avgs)
    std_pop = math.sqrt(sum((x - mean_avg) ** 2 for x in avgs) / used)
    min_avg = min(avgs)
    max_avg = max(avgs)
    q1 = _percentile(sorted_avgs, 0.25)
    q3 = _percentile(sorted_avgs, 0.75)
    iqr = q3 - q1
    low_fence = q1 - 1.5 * iqr
    high_fence = q3 + 1.5 * iqr

    outliers = []
    for i, value in enumerate(avgs, start=1):
        if value < low_fence or value > high_fence:
            outliers.append((i, value))

    above_50 = sum(1 for x in avgs if x > 0.5)
    pct_above_50 = 100.0 * above_50 / used
    white_minus_black = sum(w - b for w, b in zip(whites, blacks)) / used

    ci_low = None
    ci_high = None
    p_value = None
    if used >= 2:
        std_sample = math.sqrt(sum((x - mean_avg) ** 2 for x in avgs) / (used - 1))
        if std_sample == 0.0:
            ci_low = mean_avg
            ci_high = mean_avg
            p_value = 0.0 if mean_avg != 0.5 else 1.0
        else:
            se = std_sample / math.sqrt(used)
            ci_low = mean_avg - 1.96 * se
            ci_high = mean_avg + 1.96 * se
            z = (mean_avg - 0.5) / se
            p_value = math.erfc(abs(z) / math.sqrt(2.0))

    print(f"Gold Eval Stats from {log_path}")
    print(f"Requested last x={last_x}, using n={used} valid eval points")
    print(f"Window: {selected[0]['timestamp']} -> {selected[-1]['timestamp']}")
    print(f"Mean avg win rate: {mean_avg:.6f} ({mean_avg*100:.2f}%)")
    print(f"Std dev (population): {std_pop:.6f} ({std_pop*100:.2f}pp)")
    print(f"Median: {median_avg:.6f} ({median_avg*100:.2f}%)")
    print(f"Min/Max: {min_avg:.6f} / {max_avg:.6f}")
    print(f"Q1 (25%): {q1:.6f}")
    print(f"Q3 (75%): {q3:.6f}")
    print(f"IQR: {iqr:.6f}")
    print(f"Outlier fences (IQR rule): [{low_fence:.6f}, {high_fence:.6f}]")
    if outliers:
        preview = ", ".join(f"#{idx}:{val:.4f}" for idx, val in outliers[:10])
        suffix = " ..." if len(outliers) > 10 else ""
        print(f"Outliers: {len(outliers)} ({preview}{suffix})")
    else:
        print("Outliers: 0")
    print(f"% of eval points above 50%: {pct_above_50:.2f}% ({above_50}/{used})")
    print(f"White-Black mean gap: {white_minus_black:.6f} ({white_minus_black*100:.2f}pp)")

    if ci_low is None:
        print("Significance vs 50%: not available (need at least 2 eval points).")
        return

    print(f"95% CI for mean vs 50%: [{ci_low:.6f}, {ci_high:.6f}]")
    print(f"p-value (two-sided, normal approx): {p_value:.6g}")

    if ci_low > 0.5:
        verdict = "Result: current model is significantly better than gold."
    elif ci_high < 0.5:
        verdict = "Result: current model is significantly worse than gold."
    else:
        verdict = "Result: no statistically significant difference from gold."
    print(verdict)


def generate_gold_progress_graph(log_path="training_runs/eval_gold_history.log", out_path="training_runs/eval_gold_progress.svg", last_x=None):
    if not os.path.exists(log_path):
        print(f"Gold eval log not found: {log_path}")
        return

    pattern = re.compile(r"avg=([0-9]*\.?[0-9]+)")
    values = []
    with open(log_path, "r") as fh:
        for line in fh:
            m = pattern.search(line)
            if m:
                values.append(float(m.group(1)))

    if not values:
        print(f"No avg values found in {log_path}.")
        return

    if last_x is not None:
        values = values[-last_x:]

    window = max(5, min(25, len(values) // 20 if len(values) >= 20 else 5))
    smoothed = []
    for i in range(len(values)):
        start = max(0, i - window + 1)
        chunk = values[start:i + 1]
        smoothed.append(sum(chunk) / len(chunk))

    width, height = 1400, 700
    margin_left, margin_right, margin_top, margin_bottom = 70, 30, 40, 70
    plot_width = width - margin_left - margin_right
    plot_height = height - margin_top - margin_bottom

    vmin = min(values)
    vmax = max(values)
    if 0.4 <= vmin and vmax <= 0.7:
        y_min, y_max = 0.4, 0.7
    else:
        pad = max(0.01, (vmax - vmin) * 0.15)
        y_min = max(0.0, vmin - pad)
        y_max = min(1.0, vmax + pad)

    def to_xy(idx, value, n):
        x = margin_left + (idx / (n - 1) if n > 1 else 0.5) * plot_width
        if y_max > y_min:
            y = margin_top + (1 - (value - y_min) / (y_max - y_min)) * plot_height
        else:
            y = margin_top + plot_height / 2
        return x, y

    def polyline(series, color, stroke_width, opacity=1.0):
        points = []
        n = len(series)
        for i, v in enumerate(series):
            x, y = to_xy(i, v, n)
            points.append(f"{x:.2f},{y:.2f}")
        return (
            f'<polyline fill="none" stroke="{color}" stroke-width="{stroke_width}" '
            f'stroke-linejoin="round" stroke-linecap="round" opacity="{opacity}" '
            f'points="{" ".join(points)}" />'
        )

    grid = []
    for tick in [0.4, 0.45, 0.5, 0.55, 0.6, 0.65, 0.7]:
        if tick < y_min or tick > y_max:
            continue
        _, y = to_xy(0, tick, len(values))
        color = "#d44" if abs(tick - 0.5) < 1e-9 else "#ddd"
        stroke_width = "2" if abs(tick - 0.5) < 1e-9 else "1"
        grid.append(
            f'<line x1="{margin_left}" y1="{y:.2f}" x2="{margin_left+plot_width}" y2="{y:.2f}" '
            f'stroke="{color}" stroke-width="{stroke_width}"/>'
        )
        grid.append(
            f'<text x="{margin_left-10}" y="{y+4:.2f}" font-size="12" text-anchor="end" fill="#666">{tick*100:.0f}%</text>'
        )

    for frac, label in [(0.0, "start"), (0.25, "25%"), (0.5, "50%"), (0.75, "75%"), (1.0, "now")]:
        x = margin_left + frac * plot_width
        grid.append(
            f'<line x1="{x:.2f}" y1="{margin_top}" x2="{x:.2f}" y2="{margin_top+plot_height}" stroke="#eee" stroke-width="1"/>'
        )
        grid.append(
            f'<text x="{x:.2f}" y="{margin_top+plot_height+24}" font-size="12" text-anchor="middle" fill="#666">{label}</text>'
        )

    mean_value = sum(values) / len(values)
    last_value = values[-1]
    _, mean_y = to_xy(0, mean_value, len(values))
    last_x_coord, last_y_coord = to_xy(len(values) - 1, last_value, len(values))

    subtitle_window = f"last {last_x}" if last_x is not None else "all"
    svg = f"""<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{width}\" height=\"{height}\" viewBox=\"0 0 {width} {height}\">\n  <rect width=\"100%\" height=\"100%\" fill=\"#fff\"/>\n  <text x=\"{margin_left}\" y=\"24\" font-size=\"20\" font-weight=\"700\" fill=\"#222\">Eval vs Gold Progress (avg win rate)</text>\n  <text x=\"{margin_left}\" y=\"44\" font-size=\"13\" fill=\"#555\">Points: {len(values)} ({subtitle_window}) | Mean: {mean_value*100:.2f}% | Last: {last_value*100:.2f}% | Log: {log_path}</text>\n  <rect x=\"{margin_left}\" y=\"{margin_top}\" width=\"{plot_width}\" height=\"{plot_height}\" fill=\"#fafafa\" stroke=\"#ddd\"/>\n  {''.join(grid)}\n  {polyline(values, '#6aa9ff', 2, 0.65)}\n  {polyline(smoothed, '#1f5fbf', 3, 1.0)}\n  <line x1=\"{margin_left}\" y1=\"{mean_y:.2f}\" x2=\"{margin_left+plot_width}\" y2=\"{mean_y:.2f}\" stroke=\"#1f5fbf\" stroke-width=\"1\" stroke-dasharray=\"6,6\" opacity=\"0.5\"/>\n  <circle cx=\"{last_x_coord:.2f}\" cy=\"{last_y_coord:.2f}\" r=\"4\" fill=\"#1f5fbf\"/>\n  <text x=\"{margin_left+plot_width-6}\" y=\"{mean_y-6:.2f}\" font-size=\"12\" text-anchor=\"end\" fill=\"#1f5fbf\">mean {mean_value*100:.2f}%</text>\n  <rect x=\"{margin_left+10}\" y=\"{margin_top+10}\" width=\"280\" height=\"54\" fill=\"#fff\" stroke=\"#ddd\"/>\n  <line x1=\"{margin_left+20}\" y1=\"{margin_top+26}\" x2=\"{margin_left+80}\" y2=\"{margin_top+26}\" stroke=\"#6aa9ff\" stroke-width=\"2\"/>\n  <text x=\"{margin_left+90}\" y=\"{margin_top+30}\" font-size=\"12\" fill=\"#444\">raw avg per eval</text>\n  <line x1=\"{margin_left+20}\" y1=\"{margin_top+46}\" x2=\"{margin_left+80}\" y2=\"{margin_top+46}\" stroke=\"#1f5fbf\" stroke-width=\"3\"/>\n  <text x=\"{margin_left+90}\" y=\"{margin_top+50}\" font-size=\"12\" fill=\"#444\">smoothed trend (window={window})</text>\n</svg>"""

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as fh:
        fh.write(svg)
    print(f"Wrote graph to {out_path}")


def get_eval_seed(config):
    configured_seed = config.get_eval_seed()
    if configured_seed is not None:
        return int(configured_seed)
    return random.SystemRandom().randrange(0, 2**32)


def _load_agent_with_network(config, model_path, device, network_override=None, role_name="model"):
    if not os.path.exists(model_path):
        print(f"{role_name.capitalize()} model file not found at {model_path}.")
        return None, None
    try:
        agent, meta = load_agent_from_checkpoint(model_path, config, device=device)
        print(
            f"Loaded {role_name} '{model_path}' "
            f"(network={meta.get('network_type')}, encoder={meta.get('encoder_version')})"
        )
        return agent, meta
    except Exception as exc:
        print(f"Could not load {role_name} from {model_path}: {exc}")
        return None, None


def _try_load_candidate_agent(config, model_load_path, device):
    agent, _ = _load_agent_with_network(config, model_load_path, device, role_name="candidate")
    return agent


def train_ai(config, num_epochs_override=None):
    print("Initializing AI training...")
    training_seed = config.get_training_seed()
    if training_seed is not None:
        random.seed(training_seed)
        np.random.seed(training_seed)
        torch.manual_seed(training_seed)
        print(f"Using training_seed={training_seed}")

    device = torch.device("cpu")
    board_encoder = BoardEncoder(config, version=ENCODER_VERSION_CURRENT)
    board_evaluator = BoardEvaluator(board_encoder.input_size, hidden_sizes=config.get_hidden_sizes()).to(device)

    model_save_path = "trained_model.pth"
    if os.path.exists(model_save_path):
        print(f"Loading existing model from {model_save_path}...")
        try:
            state_dict, meta = load_state_dict(model_save_path, device=device)
            board_evaluator.load_state_dict(state_dict)
            print(
                f"Model loaded successfully "
                f"(checkpoint network={meta.get('network_type')}, encoder={meta.get('encoder_version')})."
            )
        except Exception as e:
            print(f"Could not load model: {e}. Starting from scratch.")

    training = TdLambdaTraining(board_evaluator, board_encoder, config)
    if num_epochs_override is not None:
        training.config.config["num_epochs"] = num_epochs_override
    training.run_training_loop()



HUMAN_GAME_LOG = "training_runs/human_game_history.log"


def _log_human_game(model_path: str, result: str):
    os.makedirs("training_runs", exist_ok=True)
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(HUMAN_GAME_LOG, "a") as fh:
        fh.write(f"{ts} model={model_path} result={result}\n")


def _print_human_record(log_path=HUMAN_GAME_LOG):
    """Print a compact Unicode terminal summary of the human game history."""
    if not os.path.exists(log_path):
        return

    pattern = re.compile(
        r"^(?P<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s+"
        r"model=(?P<model>\S+)\s+"
        r"result=(?P<result>win|loss)"
    )
    rows = []
    with open(log_path) as fh:
        for line in fh:
            m = pattern.match(line.strip())
            if m:
                rows.append(m.groupdict())

    if not rows:
        return

    total = len(rows)
    wins = sum(1 for r in rows if r["result"] == "win")
    losses = total - wins
    win_rate = wins / total

    # Streak
    streak = 0
    streak_type = rows[-1]["result"]
    for r in reversed(rows):
        if r["result"] == streak_type:
            streak += 1
        else:
            break

    # Recent dots (last 20)
    recent = rows[-20:]
    dots = "".join("●" if r["result"] == "win" else "○" for r in recent)

    # Bar (24 chars wide)
    bar_width = 24
    filled = round(win_rate * bar_width)
    bar = "█" * filled + "░" * (bar_width - filled)

    # Per-model breakdown (only if >1 distinct model)
    by_model: dict[str, list[str]] = {}
    for r in rows:
        by_model.setdefault(r["model"], []).append(r["result"])

    box_width = 46
    def row(content=""):
        return f"│  {content:<{box_width - 4}}│"

    lines = [
        "┌" + "─" * (box_width - 2) + "┐",
        row(f"Human vs AI"),
        row(),
        row(f"Overall   {wins}W – {losses}L   ({win_rate*100:.1f}%)"),
        row(f"{bar}  {win_rate*100:.0f}%"),
        row(),
    ]

    if len(by_model) > 1:
        lines.append(row("By model:"))
        for model, results in sorted(by_model.items()):
            n = len(results)
            w = sum(1 for x in results if x == "win")
            short = model if len(model) <= 26 else "…" + model[-25:]
            lines.append(row(f"  {short}  {w}/{n}"))
        lines.append(row())

    recent_label = f"Last {len(recent):<2}" if len(recent) == 20 else f"All {len(recent):<2} "
    lines.append(row(f"{recent_label}   {dots}"))

    streak_arrow = "↑" if streak_type == "win" else "↓"
    streak_word = "win" if streak_type == "win" else "loss"
    streak_str = f"{streak} {streak_word}{'' if streak == 1 else 's'} in a row {streak_arrow}"
    lines.append(row(f"Streak    {streak_str}"))
    lines.append("└" + "─" * (box_width - 2) + "┘")

    print()
    print("\n".join(lines))


def analyze_human_games(log_path=HUMAN_GAME_LOG):
    if not os.path.exists(log_path):
        print(f"No human game log found at {log_path}. Play some games first.")
        return
    _print_human_record(log_path)


def generate_human_progress_graph(log_path=HUMAN_GAME_LOG, out_path="training_runs/human_progress.svg", last_x=None):
    if not os.path.exists(log_path):
        print(f"No human game log found at {log_path}.")
        return

    pattern = re.compile(r"result=(?P<result>win|loss)")
    results = []
    with open(log_path) as fh:
        for line in fh:
            m = pattern.search(line)
            if m:
                results.append(1 if m.group("result") == "win" else 0)

    if not results:
        print(f"No valid game records in {log_path}.")
        return

    if last_x is not None:
        results = results[-last_x:]

    n = len(results)
    cumulative = []
    for i, v in enumerate(results, 1):
        cumulative.append(sum(results[:i]) / i)

    window = max(3, min(15, n // 10 if n >= 10 else 3))
    smoothed = []
    for i in range(n):
        start = max(0, i - window + 1)
        chunk = results[start : i + 1]
        smoothed.append(sum(chunk) / len(chunk))

    width, height = 1200, 600
    ml, mr, mt, mb = 70, 30, 40, 70
    pw = width - ml - mr
    ph = height - mt - mb

    y_min, y_max = 0.0, 1.0

    def to_xy(idx, value):
        x = ml + (idx / (n - 1) if n > 1 else 0.5) * pw
        y = mt + (1 - value) * ph
        return x, y

    def polyline(series, color, stroke_width, opacity=1.0):
        pts = []
        for i, v in enumerate(series):
            x, y = to_xy(i, v)
            pts.append(f"{x:.2f},{y:.2f}")
        return (
            f'<polyline fill="none" stroke="{color}" stroke-width="{stroke_width}" '
            f'stroke-linejoin="round" stroke-linecap="round" opacity="{opacity}" '
            f'points="{" ".join(pts)}" />'
        )

    grid = []
    for tick in [0.0, 0.25, 0.5, 0.75, 1.0]:
        _, y = to_xy(0, tick)
        color = "#d44" if abs(tick - 0.5) < 1e-9 else "#ddd"
        sw = "2" if abs(tick - 0.5) < 1e-9 else "1"
        grid.append(
            f'<line x1="{ml}" y1="{y:.2f}" x2="{ml+pw}" y2="{y:.2f}" stroke="{color}" stroke-width="{sw}"/>'
        )
        grid.append(
            f'<text x="{ml-10}" y="{y+4:.2f}" font-size="12" text-anchor="end" fill="#666">{tick*100:.0f}%</text>'
        )

    total_wins = sum(results)
    overall_rate = total_wins / n
    subtitle = f"last {last_x}" if last_x is not None else "all"
    last_cum = cumulative[-1]
    _, mean_y = to_xy(0, overall_rate)
    last_x_coord, last_y_coord = to_xy(n - 1, cumulative[-1])

    game_dots = []
    for i, v in enumerate(results):
        x, y_raw = to_xy(i, 0.5)
        cy = mt + (1 - (0.85 if v == 1 else 0.15)) * ph
        color = "#2a2" if v == 1 else "#c33"
        game_dots.append(f'<circle cx="{x:.2f}" cy="{cy:.2f}" r="3" fill="{color}" opacity="0.5"/>')

    svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
  <rect width="100%" height="100%" fill="#fff"/>
  <text x="{ml}" y="24" font-size="20" font-weight="700" fill="#222">Human vs AI Win Rate</text>
  <text x="{ml}" y="44" font-size="13" fill="#555">Games: {n} ({subtitle}) | Overall: {overall_rate*100:.1f}% | Cumulative: {last_cum*100:.1f}%</text>
  <rect x="{ml}" y="{mt}" width="{pw}" height="{ph}" fill="#fafafa" stroke="#ddd"/>
  {"".join(grid)}
  {"".join(game_dots)}
  {polyline(smoothed, "#f90", 2, 0.7)}
  {polyline(cumulative, "#1f5fbf", 2.5, 1.0)}
  <line x1="{ml}" y1="{mean_y:.2f}" x2="{ml+pw}" y2="{mean_y:.2f}" stroke="#1f5fbf" stroke-width="1" stroke-dasharray="6,6" opacity="0.4"/>
  <circle cx="{last_x_coord:.2f}" cy="{last_y_coord:.2f}" r="4" fill="#1f5fbf"/>
  <rect x="{ml+10}" y="{mt+10}" width="260" height="70" fill="#fff" stroke="#ddd"/>
  <circle cx="{ml+24}" cy="{mt+26}" r="4" fill="#2a2"/>
  <text x="{ml+34}" y="{mt+30}" font-size="12" fill="#444">win</text>
  <circle cx="{ml+24}" cy="{mt+42}" r="4" fill="#c33"/>
  <text x="{ml+34}" y="{mt+46}" font-size="12" fill="#444">loss</text>
  <line x1="{ml+18}" y1="{mt+58}" x2="{ml+70}" y2="{mt+58}" stroke="#1f5fbf" stroke-width="2.5"/>
  <text x="{ml+80}" y="{mt+62}" font-size="12" fill="#444">cumulative win rate</text>
</svg>"""

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as fh:
        fh.write(svg)
    print(f"Wrote graph to {out_path}")


def _prompt_human_color() -> Color:
    while True:
        line = input("Pick your color [w/b/r] (default w): ").strip().lower()
        if line == "" or line == "w":
            return Color.WHITE
        if line == "b":
            return Color.BLACK
        if line == "r":
            return Color.WHITE if random.random() < 0.5 else Color.BLACK
        print("Please enter w, b, or r.")


def _prompt_dice_mode():
    from play.session import DiceMode
    while True:
        line = input("Dice mode [auto/manual] (default auto): ").strip().lower()
        if line == "" or line in ("a", "auto"):
            return DiceMode.AUTO
        if line in ("m", "manual"):
            return DiceMode.MANUAL
        print("Please enter auto or manual.")


def play_against_ai(config, model_load_path="trained_model.pth", load_name=None):
    from play import loop, persistence
    from play.session import PlaySession

    device = torch.device("cpu")

    def agent_loader(path: str):
        if not os.path.exists(path):
            raise FileNotFoundError(path)
        agent, _ = load_agent_from_checkpoint(path, config, device=device)
        return agent

    if load_name is not None:
        save_path = persistence.resolve_path(load_name)
        if not save_path.exists():
            print(f"No such save: {save_path}")
            return
        save_file = persistence.load(save_path)
        try:
            agent = agent_loader(save_file.ai_checkpoint_path)
        except FileNotFoundError:
            repl = input(
                f"AI checkpoint '{save_file.ai_checkpoint_path}' not found. "
                "Enter replacement path (or blank to cancel): "
            ).strip()
            if not repl:
                return
            try:
                agent = agent_loader(repl)
            except FileNotFoundError:
                print(f"Replacement checkpoint '{repl}' also not found.")
                return
            save_file.ai_checkpoint_path = repl
        session = PlaySession.from_save(config, save_file, agent)
        session.last_save_name = load_name
        print(f"Loaded session from {save_path}")
    else:
        print("Loading trained model and starting game...")
        try:
            agent = agent_loader(model_load_path)
        except FileNotFoundError:
            print(f"Model file not found at {model_load_path}. Please train the AI first.")
            return
        human_color = _prompt_human_color()
        dice_mode = _prompt_dice_mode()
        eval_depth = config.get_play_eval_lookahead_plies()
        session = PlaySession.new_game(
            config=config,
            agent=agent,
            ai_checkpoint_path=model_load_path,
            dice_mode=dice_mode,
            human_color=human_color,
            eval_depth=eval_depth,
        )

    final_session = loop.run(session, loop.StdIO(), agent_loader=agent_loader)

    if final_session.is_terminal():
        winner = final_session.winner()
        if winner is not None:
            human_won = winner == final_session.human_color
            _log_human_game(final_session.ai_checkpoint_path, "win" if human_won else "loss")
            _print_human_record()


def evaluate_against_random(config, model_load_path="trained_model.pth", games_per_color=100):
    print("Loading trained model for evaluation against random...")
    device = torch.device("cpu")

    ai_agent = _try_load_candidate_agent(config, model_load_path, device)
    if ai_agent is None:
        print("Please train the AI first.")
        return

    random_agent = RandomAgent()
    eval_seed = get_eval_seed(config)
    candidate_lookahead = max(1, int(config.get_eval_candidate_lookahead_plies()))
    py_state = random.getstate()
    np_state = np.random.get_state()

    def play_game(ai_color: Color):
        game = Game(config, starting_player=Color.WHITE)
        while not game.is_over():
            current_player = game.current_player
            game.dice.roll()
            possible_moves = PossibleMoves(game.board, current_player, game.dice).find_moves()
            if not possible_moves:
                game.switch_turn()
                continue
            if current_player == ai_color:
                move, _ = ai_agent.get_best_move(game.board, possible_moves, current_player, lookahead_plies=candidate_lookahead)
            else:
                move = random_agent.get_move(possible_moves)
            game.board.apply(move)
            game.switch_turn()
        return game.get_winner()

    try:
        for ai_color in (Color.WHITE, Color.BLACK):
            random.seed(eval_seed)
            np.random.seed(eval_seed)
            wins = 0
            losses = 0
            for _ in range(games_per_color):
                winner = play_game(ai_color)
                if winner == ai_color:
                    wins += 1
                else:
                    losses += 1
            print(f"AI as {ai_color}: {wins}-{losses} over {games_per_color} games (seed={eval_seed})")
    finally:
        random.setstate(py_state)
        np.random.set_state(np_state)


def evaluate_against_gold(
    config,
    model_load_path="trained_model.pth",
    gold_model_path=None,
    games_per_color=100,
):
    if gold_model_path is None:
        gold_model_path = config.get_gold_model_path()

    print("Loading candidate and gold models for head-to-head evaluation...")
    device = torch.device("cpu")

    candidate_agent = _try_load_candidate_agent(config, model_load_path, device)
    if candidate_agent is None:
        return

    gold_agent, _ = _load_agent_with_network(config, gold_model_path, device, role_name="gold")
    if gold_agent is None:
        return

    eval_seed = get_eval_seed(config)
    candidate_lookahead = max(1, int(config.get_eval_candidate_lookahead_plies()))
    gold_lookahead = max(1, int(config.get_eval_gold_lookahead_plies()))
    print(f"Lookahead plies: candidate={candidate_lookahead}, gold={gold_lookahead}")
    py_state = random.getstate()
    np_state = np.random.get_state()

    def play_game(candidate_color: Color):
        game = Game(config, starting_player=Color.WHITE)
        while not game.is_over():
            current_player = game.current_player
            game.dice.roll()
            possible_moves = PossibleMoves(game.board, current_player, game.dice).find_moves()
            if not possible_moves:
                game.switch_turn()
                continue
            if current_player == candidate_color:
                move, _ = candidate_agent.get_best_move(game.board, possible_moves, current_player, lookahead_plies=candidate_lookahead)
            else:
                move, _ = gold_agent.get_best_move(game.board, possible_moves, current_player, lookahead_plies=gold_lookahead)
            game.board.apply(move)
            game.switch_turn()
        return game.get_winner()

    try:
        for candidate_color in (Color.WHITE, Color.BLACK):
            random.seed(eval_seed)
            np.random.seed(eval_seed)
            wins = 0
            losses = 0
            for _ in range(games_per_color):
                winner = play_game(candidate_color)
                if winner == candidate_color:
                    wins += 1
                else:
                    losses += 1
            print(f"Candidate as {candidate_color}: {wins}-{losses} over {games_per_color} games (seed={eval_seed})")
    finally:
        random.setstate(py_state)
        np.random.set_state(np_state)

    print(f"Compared candidate '{model_load_path}' vs gold '{gold_model_path}'.")


def main():
    config = ConfigLoader("config/config.yml")

    if len(sys.argv) < 2:
        print(
            "Usage: python main.py "
            "[train [num_epochs]|play|"
            "eval-random [games_per_color]|eval-gold [games_per_color] [gold_model_path]|"
            "eval-gold-stats [x]|eval-gold-graph [x]]"
        )
        return

    mode = sys.argv[1]

    if mode == 'train':
        num_epochs = None
        if len(sys.argv) >= 3:
            try:
                num_epochs = int(sys.argv[2])
                if num_epochs <= 0:
                    raise ValueError("num_epochs must be positive")
            except ValueError:
                print("Invalid num_epochs. Please provide a positive integer.")
                return
        train_ai(config, num_epochs_override=num_epochs)
    elif mode == 'play':
        network_path = "trained_model.pth"
        load_name = None
        args = sys.argv[2:]
        i = 0
        while i < len(args):
            arg = args[i]
            if arg == "--network" and i + 1 < len(args):
                network_path = args[i + 1]
                i += 2
                continue
            if arg == "--load" and i + 1 < len(args):
                load_name = args[i + 1]
                i += 2
                continue
            if not arg.startswith("--") and i == 0:
                network_path = arg
                i += 1
                continue
            print(f"Unknown play argument: {arg}")
            return
        play_against_ai(config, model_load_path=network_path, load_name=load_name)
    elif mode in ('eval-random', 'evaluate-random'):
        games_per_color = 100
        if len(sys.argv) >= 3:
            try:
                games_per_color = int(sys.argv[2])
                if games_per_color <= 0:
                    raise ValueError("games_per_color must be positive")
            except ValueError:
                print("Invalid games_per_color. Please provide a positive integer.")
                return
        evaluate_against_random(config, games_per_color=games_per_color)
    elif mode in ('eval-gold', 'evaluate-gold'):
        games_per_color = 100
        if len(sys.argv) >= 3:
            try:
                games_per_color = int(sys.argv[2])
                if games_per_color <= 0:
                    raise ValueError("games_per_color must be positive")
            except ValueError:
                print("Invalid games_per_color. Please provide a positive integer.")
                return
        gold_model_path = sys.argv[3] if len(sys.argv) >= 4 and not sys.argv[3].startswith("--") else None
        evaluate_against_gold(config, games_per_color=games_per_color, gold_model_path=gold_model_path)
    elif mode in ('eval-gold-stats', 'analyze-gold'):
        last_x = 50
        if len(sys.argv) >= 3:
            try:
                last_x = int(sys.argv[2])
                if last_x <= 0:
                    raise ValueError("x must be positive")
            except ValueError:
                print("Invalid x. Please provide a positive integer.")
                return
        analyze_gold_log_last_x(last_x=last_x)
    elif mode in ('eval-gold-graph', 'graph-gold'):
        last_x = None
        if len(sys.argv) >= 3:
            try:
                last_x = int(sys.argv[2])
                if last_x <= 0:
                    raise ValueError("x must be positive")
            except ValueError:
                print("Invalid x. Please provide a positive integer.")
                return
        generate_gold_progress_graph(last_x=last_x)
    elif mode in ('human-stats',):
        analyze_human_games()
    elif mode in ('human-graph',):
        last_x = None
        if len(sys.argv) >= 3:
            try:
                last_x = int(sys.argv[2])
                if last_x <= 0:
                    raise ValueError("x must be positive")
            except ValueError:
                print("Invalid x. Please provide a positive integer.")
                return
        generate_human_progress_graph(last_x=last_x)
    else:
        print(
            f"Unknown mode: {mode}. Use 'train', 'play', "
            "'eval-random', 'eval-gold', 'eval-gold-stats', 'eval-gold-graph', "
            "'human-stats', or 'human-graph'."
        )


if __name__ == "__main__":
    main()
