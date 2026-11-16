"""Unattended "train until plateau" driver (#140 / #141 / #142).

Trains a variant from scratch with no reference model and no human watching:
it bootstraps its own ladder of gold snapshots (`<ladder_dir>/<variant>_gold_vK.pth`)
and stops by itself once training no longer produces a stronger net.

Round = train `round_games` self-play games (subprocess: `main.py --config <stage cfg>
train N`, exactly what `./run.sh train` runs) + paired duplicate-dice eval (subprocess,
`ai.paired_eval`) of the live model vs the ladder top (or vs random before v1 exists).

Statistic: for max_points == 1 variants everything runs on the paired win statistic
(d_k = A's wins in the pair - 1; a draw is half a win), exactly as before. For variants
whose games are worth up to max_points > 1 (gammon / mars / mother win), promotion and
plateau run on POINTS: d_k = A's signed points over the pair / (2 * max_points), and
"rate" is the normalized equity 0.5 + mean_d / 2 (see `decision_stats`). The bootstrap
gate vs random stays on win rate (a sanity gate; an equity threshold vs random would
depend on the gammon rate). Logs / status show both win rate and avg points per game.

Decision per round (pure functions below, unit-tested):
  * no ladder yet  -> promote `_gold_v1` once rate vs random >= random_promote_winrate.
  * ladder exists  -> promote `_gold_v{K+1}` iff paired z >= promote_z AND
                      rate >= promote_min_winrate.
  * otherwise the round joins the non-promotion streak. Plateau when the streak is
    >= patience rounds AND the pooled (all streak pairs) one-sided upper confidence
    bound on the edge (rate - 0.5) is < min_edge. A stage also ends at max_rounds.
  * stage end -> next stage (its `overrides` applied via a derived config file);
    the run is finished when the last stage ends, then the final model is measured
    vs random (`final_random_eval_pairs`).

All state lives in `plateau_state_<variant>.json` (atomic writes, phase-tracked), so
the driver can be killed at any time and resumes the exact phase it was in.
"""

import glob
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

DEFAULTS = {
    "round_games": 20000,           # self-play games per round
    "eval_pairs": 2000,             # paired trials (2 games each) vs ladder top per round
    "patience": 4,                  # non-promoting rounds before a plateau can be declared
    "min_edge": 0.015,              # plateau iff pooled UCB on (rate - 0.5) < this
    "plateau_ucb_z": 1.645,         # one-sided 95% upper bound for the pooled edge
    "promote_z": 2.0,               # paired one-sided z needed to promote
    "promote_min_winrate": 0.52,    # ... and at least this win rate
    "max_rounds": 200,              # per stage; a stage that never plateaus ends here
    "random_eval_pairs": 500,       # bootstrap eval vs random (500 pairs = 1000 games)
    "random_promote_winrate": 0.90, # promote _gold_v1 once rate vs random >= this
    "final_random_eval_pairs": 500, # final model vs random after the last stage (0 = skip)
    "max_retries": 1,               # retries per failing subprocess phase before FAILED
    "eval_workers": None,           # None -> num_self_play_workers
    "stages": [],                   # [{name: str, overrides: {cfg_key: value}}]; [] = one stage
    "ladder_dir": "models",
    "state_path": None,             # None -> plateau_state_<variant>.json
    "log_path": None,               # None -> training_runs/plateau_<variant>.log
    "work_dir": None,               # None -> training_runs/plateau_<variant> (derived cfgs)
}


# ---------------------------------------------------------------- pure decision logic

def pool_results(results, ucb_z=DEFAULTS["plateau_ucb_z"]):
    """Pool per-round paired summaries ({num_pairs, mean_d, std_d}) into one sample.

    Exact pooling of the d_k values via sufficient statistics (n, sum, sum of squares),
    so between-round differences inflate the variance (conservative). The edge is in
    win-rate units: edge = rate - 0.5 = mean_d / 2."""
    n = sum(int(r["num_pairs"]) for r in results)
    if n == 0:
        return {"num_pairs": 0, "mean_d": 0.0, "std_d": 0.0, "edge": 0.0,
                "se_edge": float("inf"), "edge_ucb": float("inf"), "rate": 0.5}
    s = sum(r["num_pairs"] * r["mean_d"] for r in results)
    ss = sum((r["num_pairs"] - 1) * r["std_d"] ** 2 + r["num_pairs"] * r["mean_d"] ** 2
             for r in results)
    mean = s / n
    var = max(0.0, (ss - n * mean * mean) / (n - 1)) if n > 1 else 0.0
    se_edge = math.sqrt(var / n) / 2.0 if n > 1 else float("inf")
    edge = mean / 2.0
    return {"num_pairs": n, "mean_d": mean, "std_d": math.sqrt(var), "edge": edge,
            "se_edge": se_edge, "edge_ucb": edge + ucb_z * se_edge, "rate": 0.5 + edge}


def decision_stats(summary, max_points):
    """Pick the statistic promotion / plateau run on from a paired-eval summary
    (`ai.paired_eval.summarize`). max_points == 1: the win statistic, unchanged.
    max_points > 1: the normalized points statistic (`pts_*`). Always carries the plain
    `win_rate` and average points per game `ppg` for logging."""
    out = {k: summary[k] for k in ("num_pairs", "num_games", "mean_d", "std_d", "z", "rate")}
    use_points = max_points > 1 and summary.get("pts_mean_d") is not None
    if use_points:
        out.update(mean_d=summary["pts_mean_d"], std_d=summary["pts_std_d"],
                   z=summary["pts_z"], rate=summary["pts_rate"])
    out["metric"] = "points" if use_points else "wins"
    out["win_rate"] = summary["rate"]
    out["ppg"] = summary.get("points_per_game")
    return out


def should_promote(result, promote_z, promote_min_winrate):
    return result["z"] >= promote_z and result["rate"] >= promote_min_winrate


def plateau_check(streak, settings):
    """(is_plateau, pooled) for the current non-promotion streak of round summaries."""
    pooled = pool_results(streak, settings["plateau_ucb_z"])
    is_plateau = len(streak) >= settings["patience"] and pooled["edge_ucb"] < settings["min_edge"]
    return is_plateau, pooled


def decide(has_ladder, result, streak, stage_rounds, settings):
    """Decide one round. `streak` = prior non-promoting results this stage (vs the
    current top); `stage_rounds` includes this round. Returns
    {promote: bool, stage_end: None|'plateau'|'max_rounds', pooled: dict|None}."""
    pooled = None
    stage_end = None
    if not has_ladder:
        promote = result.get("win_rate", result["rate"]) >= settings["random_promote_winrate"]
    else:
        promote = should_promote(result, settings["promote_z"], settings["promote_min_winrate"])
        if not promote:
            is_plateau, pooled = plateau_check(list(streak) + [result], settings)
            if is_plateau:
                stage_end = "plateau"
    if stage_end is None and stage_rounds >= settings["max_rounds"]:
        stage_end = "max_rounds"
    return {"promote": promote, "stage_end": stage_end, "pooled": pooled}


# ---------------------------------------------------------------- settings / paths

def load_settings(base_cfg):
    variant = str(base_cfg.get("variant") or "plakoto").strip().lower()
    s = dict(DEFAULTS)
    s.update({k: v for k, v in (base_cfg.get("plateau") or {}).items() if v is not None})
    for k in ("round_games", "eval_pairs", "patience", "max_rounds", "random_eval_pairs",
              "final_random_eval_pairs", "max_retries"):
        s[k] = int(s[k])
    for k in ("min_edge", "plateau_ucb_z", "promote_z", "promote_min_winrate",
              "random_promote_winrate"):
        s[k] = float(s[k])
    s["stages"] = list(s.get("stages") or []) or [{"name": "default", "overrides": {}}]
    s["variant"] = variant
    try:
        from domain.ruleset import get_ruleset
        s["max_points"] = int(get_ruleset(variant).max_points)
    except ValueError:
        s["max_points"] = 1
    s["state_path"] = s["state_path"] or f"plateau_state_{variant}.json"
    s["log_path"] = s["log_path"] or os.path.join("training_runs", f"plateau_{variant}.log")
    s["work_dir"] = s["work_dir"] or os.path.join("training_runs", f"plateau_{variant}")
    return s


def _ladder_re(variant):
    return re.compile(rf"^{re.escape(variant)}_gold_v(\d+)\.pth$")


def ladder_on_disk(ladder_dir, variant):
    """Existing snapshots, sorted by version: [(K, path)]."""
    pat = _ladder_re(variant)
    out = []
    for p in glob.glob(os.path.join(ladder_dir, f"{variant}_gold_v*.pth")):
        m = pat.match(os.path.basename(p))
        if m:
            out.append((int(m.group(1)), p))
    return sorted(out)


def _atomic_write_json(path, obj):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=1, sort_keys=True)
    os.replace(tmp, path)


def _copy_no_overwrite(src, dest):
    """Copy src -> dest, refusing to overwrite (O_EXCL). Returns False if dest exists."""
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    try:
        with open(src, "rb") as fin, open(dest, "xb") as fout:
            shutil.copyfileobj(fin, fout)
    except FileExistsError:
        return False
    return True


def _fmt_pp(x):
    return "n/a" if x is None or math.isinf(x) else f"{x * 100:+.2f}pp"


# ---------------------------------------------------------------- subprocess runners

def _sub_env():
    env = dict(os.environ)
    env["PYTHONPATH"] = REPO_ROOT + (os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")
    env.pop("TAVLI_CONFIG", None)   # the explicit --config wins anyway; avoid confusion
    return env


def subprocess_train(config_path, num_epochs, log_path):
    """Run `main.py --config CFG train N` (what ./run.sh train runs); stdout appended
    to the config's training_log_path. Returns the exit code."""
    os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
    cmd = [sys.executable, os.path.join(REPO_ROOT, "main.py"), "--config", config_path,
           "train", str(int(num_epochs))]
    with open(log_path, "a") as fh:
        fh.write(f"\n===== plateau driver: {' '.join(cmd)} @ {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        fh.flush()
        return subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT, env=_sub_env())


def subprocess_eval(config_path, model_a, opponent, num_pairs, base_seed, workers,
                    out_json, log_path):
    """Run the paired eval in a subprocess; returns (exit_code, summary|None)."""
    if os.path.exists(out_json):
        os.remove(out_json)
    cmd = [sys.executable, "-m", "ai.plateau_driver", "_eval", config_path, model_a,
           opponent, str(int(num_pairs)), str(int(base_seed)), str(int(workers)), out_json]
    os.makedirs(os.path.dirname(log_path) or ".", exist_ok=True)
    with open(log_path, "a") as fh:
        fh.write(f"\n===== plateau driver: {' '.join(cmd)} @ {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        fh.flush()
        rc = subprocess.call(cmd, stdout=fh, stderr=subprocess.STDOUT, env=_sub_env())
    if rc != 0 or not os.path.exists(out_json):
        return (rc or 1), None
    with open(out_json) as fh:
        return 0, json.load(fh)


class _RandomMover:
    """Random opponent with the Agent.get_best_move signature. Own RNG, so it never
    perturbs the global dice stream that paired eval seeds per orientation."""

    def __init__(self, seed):
        import random
        self.rng = random.Random(seed)

    def get_best_move(self, board, moves, player, lookahead_plies=1):
        return self.rng.choice(list(moves)), None


def _random_worker(model_a, config_path, seeds, lookahead, result_q):
    import torch
    from config.config_loader import ConfigLoader
    from ai.checkpoint_io import load_agent_from_checkpoint
    from ai.paired_eval import run_pairs
    torch.set_num_threads(1)
    config = ConfigLoader(config_path)
    agent, _ = load_agent_from_checkpoint(model_a, config, device=torch.device("cpu"))
    rnd = _RandomMover(seeds[0] if seeds else 0)
    for s in seeds:
        (res,) = run_pairs(agent, rnd, config, [s], lookahead)
        result_q.put(res)


def _eval_vs_random(config, model_a, num_pairs, base_seed, workers):
    import multiprocessing as mp
    from ai.paired_eval import summarize
    max_points = config.get_ruleset().max_points
    lookahead = max(1, int(config.get_eval_candidate_lookahead_plies()))
    seeds = [base_seed + k for k in range(num_pairs)]
    chunks = [c for c in (seeds[i::workers] for i in range(workers)) if c]
    ctx = mp.get_context("spawn")
    q = ctx.Queue()
    procs = [ctx.Process(target=_random_worker, args=(model_a, config.config_file, c, lookahead, q))
             for c in chunks]
    for p in procs:
        p.start()
    results = [q.get() for _ in range(num_pairs)]
    for p in procs:
        p.join()
    s = summarize(results, max_points)
    print(f"vs random: rate={s['rate']:.4f} over {s['num_games']} games  z={s['z']:.2f}"
          + (f"  points/game={s['points_per_game']:+.3f}" if max_points > 1 else ""))
    return s


def _eval_main(argv):
    """`python -m ai.plateau_driver _eval CFG MODEL_A OPP|random PAIRS SEED WORKERS OUT`."""
    config_path, model_a, opponent, pairs, seed, workers, out_json = argv
    from config.config_loader import ConfigLoader
    config = ConfigLoader(config_path)
    pairs, seed, workers = int(pairs), int(seed), max(1, int(workers))
    if opponent == "random":
        s = _eval_vs_random(config, model_a, pairs, seed, workers)
    else:
        from ai.paired_eval import evaluate_paired
        s = evaluate_paired(config, model_a, opponent, num_pairs=pairs,
                            num_workers=workers, base_seed=seed)
    s = {k: (None if isinstance(v, float) and math.isinf(v) else v) for k, v in s.items()}
    _atomic_write_json(out_json, s)


# ---------------------------------------------------------------- the driver

class PlateauDriver:
    """Resumable round loop. `train_runner(cfg_path, epochs, log) -> rc` and
    `eval_runner(cfg_path, a, opp, pairs, seed, workers, out_json, log) -> (rc, summary)`
    are injectable for tests; defaults run real subprocesses."""

    def __init__(self, config_path, train_runner=None, eval_runner=None, out=print):
        self.config_path = config_path
        with open(config_path) as fh:
            self.base_cfg = yaml.safe_load(fh) or {}
        self.s = load_settings(self.base_cfg)
        self.variant = self.s["variant"]
        self.train_runner = train_runner or subprocess_train
        self.eval_runner = eval_runner or subprocess_eval
        self.out = out
        self.model_path = self.base_cfg.get("model_save_path", "trained_model.pth")
        self.training_state_path = self.base_cfg.get("training_state_path", "training_state.json")
        self.training_log_path = self.base_cfg.get("training_log_path", "training_log_td.txt")
        self.state = self._load_or_init_state()

    # -- state ---------------------------------------------------------------
    def _load_or_init_state(self):
        if os.path.exists(self.s["state_path"]):
            with open(self.s["state_path"]) as fh:
                return json.load(fh)
        return {
            "variant": self.variant, "config": self.config_path, "status": "running",
            "stage": 0, "stage_round": 0, "round": 0, "phase": "train", "attempts": 0,
            "ladder": [], "streak": [], "rounds": [], "stage_results": [],
            "games_played": 0, "pending": None, "final_vs_random": None,
            "verdict": None, "error": None,
            "started": time.strftime("%Y-%m-%d %H:%M:%S"),
        }

    def save(self):
        self.state["updated"] = time.strftime("%Y-%m-%d %H:%M:%S")
        _atomic_write_json(self.s["state_path"], self.state)

    def _log(self, line):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        os.makedirs(os.path.dirname(self.s["log_path"]) or ".", exist_ok=True)
        with open(self.s["log_path"], "a") as fh:
            fh.write(f"{ts} {line}\n")
        self.out(f"[plateau {ts}] {line}")

    def _sync_ladder_from_disk(self):
        """Adopt snapshots already on disk (e.g. state file deleted) — never lose a rung."""
        known = set(self.state["ladder"])
        for _, p in ladder_on_disk(self.s["ladder_dir"], self.variant):
            if p not in known:
                self.state["ladder"].append(p)
        self.state["ladder"].sort(key=lambda p: int(_ladder_re(self.variant).match(
            os.path.basename(p)).group(1)))

    @property
    def top(self):
        return self.state["ladder"][-1] if self.state["ladder"] else None

    # -- derived per-stage config -------------------------------------------
    def stage_config_path(self):
        st = self.state["stage"]
        stage = self.s["stages"][st]
        cfg = json.loads(json.dumps(self.base_cfg))  # deep copy
        cfg.update(stage.get("overrides") or {})
        if self.top:
            cfg["gold_model_path"] = self.top
        else:
            cfg["eval_against_gold"] = False
        path = os.path.join(self.s["work_dir"], f"stage{st + 1}_config.yml")
        os.makedirs(self.s["work_dir"], exist_ok=True)
        with open(path, "w") as fh:
            fh.write(f"# GENERATED by ai/plateau_driver.py from {self.config_path} "
                     f"(stage {st + 1}: {stage.get('name', '')}). Do not edit.\n")
            yaml.safe_dump(cfg, fh, sort_keys=False)
        return path, cfg

    def _games_played(self):
        try:
            with open(self.training_state_path) as fh:
                return int(json.load(fh).get("global_game_num", 0))
        except Exception:
            return self.state["games_played"]

    # -- phases ---------------------------------------------------------------
    def _fail_or_retry(self, what, rc):
        self.state["attempts"] += 1
        if self.state["attempts"] > self.s["max_retries"]:
            self.state["status"] = "failed"
            self.state["error"] = (f"{what} subprocess failed (exit {rc}) "
                                   f"{self.state['attempts']}x in round {self.state['round'] + 1}")
            self._log(f"FAILED: {self.state['error']}")
            self.save()
            return False
        self._log(f"{what} failed (exit {rc}); retrying (attempt {self.state['attempts'] + 1})")
        self.save()
        return True

    def _phase_train(self, cfg_path, cfg):
        gpe = max(1, int(cfg.get("games_per_epoch", 100)))
        # A stage may carry its own `round_games` (depth-1 rounds are cheap, depth-2 rounds are not).
        stage = self.s["stages"][self.state["stage"]]
        round_games = int(stage.get("round_games") or self.s["round_games"])
        epochs = max(1, math.ceil(round_games / gpe))
        rc = self.train_runner(cfg_path, epochs, self.training_log_path)
        if rc != 0:
            return self._fail_or_retry("training", rc)
        self.state["games_played"] = self._games_played()
        self.state.update(phase="eval", attempts=0)
        self.save()
        return True

    def _phase_eval(self, cfg_path, cfg):
        rnd = self.state["round"] + 1
        opp = self.top or "random"
        pairs = self.s["eval_pairs"] if self.top else self.s["random_eval_pairs"]
        workers = self.s["eval_workers"] or int(cfg.get("num_self_play_workers", 1))
        out_json = os.path.join(self.s["work_dir"], "last_eval.json")
        rc, summary = self.eval_runner(cfg_path, self.model_path, opp, pairs, rnd * 1_000_003,
                                       workers, out_json,
                                       os.path.join(self.s["work_dir"], "eval_output.log"))
        if rc != 0 or summary is None:
            return self._fail_or_retry("eval", rc)
        self.state["pending"] = decision_stats(summary, self.s["max_points"])
        self.state["pending"]["opponent"] = opp
        self.state.update(phase="decide", attempts=0)
        self.save()
        return True

    def _phase_decide(self):
        st = self.state
        res = st["pending"]
        has_ladder = res["opponent"] != "random"
        d = decide(has_ladder, res, st["streak"], st["stage_round"] + 1, self.s)
        new_top = None
        if d["promote"]:
            # Destination is fixed in state before copying, so a crash mid-copy resumes
            # onto the same file instead of minting a second rung.
            dest = res.get("promote_to")
            if not dest:
                on_disk = ladder_on_disk(self.s["ladder_dir"], self.variant)
                k = (on_disk[-1][0] if on_disk else 0) + 1
                dest = os.path.join(self.s["ladder_dir"], f"{self.variant}_gold_v{k}.pth")
                while os.path.exists(dest):
                    k += 1
                    dest = os.path.join(self.s["ladder_dir"], f"{self.variant}_gold_v{k}.pth")
                res["promote_to"] = dest
                self.save()
            if not os.path.exists(dest):
                _copy_no_overwrite(self.model_path, dest)
            new_top = dest

        rnd = st["round"] + 1
        rec = {
            "round": rnd, "stage": st["stage"] + 1, "stage_round": st["stage_round"] + 1,
            "ts": time.strftime("%Y-%m-%d %H:%M:%S"), "games": st["games_played"],
            "opponent": res["opponent"], "num_pairs": res["num_pairs"], "rate": res["rate"],
            "z": res["z"], "mean_d": res["mean_d"], "std_d": res["std_d"],
            "promoted": bool(d["promote"]), "new_top": new_top,
            "metric": res.get("metric", "wins"), "win_rate": res.get("win_rate", res["rate"]),
            "ppg": res.get("ppg"),
            "vs_random": res.get("win_rate", res["rate"]) if not has_ladder else None,
            "pooled_edge": d["pooled"]["edge"] if d["pooled"] else None,
            "pooled_ucb": d["pooled"]["edge_ucb"] if d["pooled"] else None,
        }
        st["rounds"].append(rec)
        st["round"] = rnd
        st["stage_round"] += 1
        if new_top:
            st["ladder"].append(new_top)
            st["streak"] = []
        elif has_ladder:
            st["streak"].append({k: res[k] for k in ("num_pairs", "mean_d", "std_d", "z", "rate")})

        opp_name = os.path.basename(res["opponent"]).replace(".pth", "")
        line = (f"stage={st['stage'] + 1}/{len(self.s['stages'])} round={rnd} "
                f"games={st['games_played']} vs={opp_name} pairs={res['num_pairs']} "
                f"rate={res['rate']:.4f} z={res['z']:.2f} "
                + (f"[points: win_rate={res.get('win_rate', res['rate']):.4f} "
                   f"ppg={res['ppg']:+.3f}] " if res.get("metric") == "points" else "")
                + f"promoted={'yes->' + os.path.basename(new_top) if new_top else 'no'} "
                f"streak={len(st['streak'])}/{self.s['patience']}")
        if d["pooled"]:
            line += f" pooled_edge={_fmt_pp(d['pooled']['edge'])} ucb={_fmt_pp(d['pooled']['edge_ucb'])}"
        if not has_ladder:
            line += f" vs_random={res.get('win_rate', res['rate']):.4f}/{res['num_games']}g"
        self._log(line)

        st["pending"] = None
        st["phase"] = "train"
        if d["stage_end"]:
            self._end_stage(d["stage_end"], d["pooled"])
        self.save()

    def _end_stage(self, reason, pooled):
        st = self.state
        stage = self.s["stages"][st["stage"]]
        if reason == "plateau":
            msg = (f"stage {st['stage'] + 1} ({stage.get('name', '')}) PLATEAU after "
                   f"{len(st['streak'])} non-promoting rounds: pooled edge vs "
                   f"{os.path.basename(self.top)} {_fmt_pp(pooled['edge'])} "
                   f"(UCB {_fmt_pp(pooled['edge_ucb'])} < min_edge {_fmt_pp(self.s['min_edge'])}, "
                   f"{pooled['num_pairs']} pairs)")
        else:
            msg = (f"stage {st['stage'] + 1} ({stage.get('name', '')}) hit max_rounds="
                   f"{self.s['max_rounds']} without a confirmed plateau")
        st["stage_results"].append({"stage": st["stage"] + 1, "reason": reason, "message": msg,
                                    "round": st["round"], "top": self.top})
        self._log(msg)
        if st["stage"] + 1 < len(self.s["stages"]):
            st["stage"] += 1
            st["stage_round"] = 0
            st["streak"] = []
            self._log(f"advancing to stage {st['stage'] + 1}/{len(self.s['stages'])} "
                      f"({self.s['stages'][st['stage']].get('name', '')}): "
                      f"overrides={self.s['stages'][st['stage']].get('overrides') or {}}")
        else:
            st["phase"] = "final" if self.s["final_random_eval_pairs"] > 0 and self.top else "done"

    def _phase_final(self, cfg_path, cfg):
        workers = self.s["eval_workers"] or int(cfg.get("num_self_play_workers", 1))
        out_json = os.path.join(self.s["work_dir"], "final_random.json")
        rc, summary = self.eval_runner(cfg_path, self.model_path, "random",
                                       self.s["final_random_eval_pairs"], 987_654_321, workers,
                                       out_json, os.path.join(self.s["work_dir"], "eval_output.log"))
        if rc != 0 or summary is None:
            return self._fail_or_retry("final random eval", rc)
        self.state["final_vs_random"] = {"rate": summary["rate"], "games": summary["num_games"],
                                         "ppg": summary.get("points_per_game")}
        self.state["phase"] = "done"
        self.save()
        return True

    def _finish(self):
        st = self.state
        last = st["stage_results"][-1] if st["stage_results"] else None
        fr = st["final_vs_random"]
        st["status"] = "finished"
        st["verdict"] = (
            f"FINISHED {self.variant}: {len(self.s['stages'])} stage(s), {st['round']} rounds, "
            f"{st['games_played']} games. Ladder top: {self.top or 'none'} "
            f"({len(st['ladder'])} rungs). Last stage: {last['message'] if last else 'n/a'}."
            + (f" Final vs random: {fr['rate']:.4f} over {fr['games']} games"
               + (f", {fr['ppg']:+.3f} points/game." if fr.get("ppg") is not None else ".")
               if fr else ""))
        self._log(st["verdict"])
        self.save()

    # -- main loop ------------------------------------------------------------
    def run(self):
        st = self.state
        if st["status"] == "finished":
            self.out(st["verdict"])
            return 0
        if st["status"] == "failed":
            self._log(f"resuming after FAILED ({st['error']}); retry budget reset")
            st.update(status="running", attempts=0, error=None)
        self._sync_ladder_from_disk()
        self.save()
        self._log(f"start/resume: variant={self.variant} stage={st['stage'] + 1}/"
                  f"{len(self.s['stages'])} round={st['round']} phase={st['phase']} "
                  f"top={self.top or 'none (bootstrap vs random)'}")
        while st["status"] == "running":
            if st["phase"] == "done":
                self._finish()
                break
            cfg_path, cfg = self.stage_config_path()
            if st["phase"] == "train":
                ok = self._phase_train(cfg_path, cfg)
            elif st["phase"] == "eval":
                ok = self._phase_eval(cfg_path, cfg)
            elif st["phase"] == "decide":
                self._phase_decide()
                ok = True
            elif st["phase"] == "final":
                ok = self._phase_final(cfg_path, cfg)
            else:
                raise RuntimeError(f"unknown phase {st['phase']!r}")
            if not ok:
                return 1
        return 0 if st["status"] == "finished" else 1


# ---------------------------------------------------------------- status

def format_status(config_path):
    with open(config_path) as fh:
        base_cfg = yaml.safe_load(fh) or {}
    s = load_settings(base_cfg)
    if not os.path.exists(s["state_path"]):
        return f"plateau {s['variant']}: NOT STARTED (no {s['state_path']})"
    with open(s["state_path"]) as fh:
        st = json.load(fh)
    ladder = st.get("ladder") or []
    lines = [
        f"plateau {st['variant']}: {st['status'].upper()}  stage {st['stage'] + 1}/"
        f"{len(s['stages'])} ({s['stages'][min(st['stage'], len(s['stages']) - 1)].get('name', '')})  "
        f"round {st['round']} (stage round {st['stage_round']})  games {st['games_played']}  "
        f"phase {st['phase']}  updated {st.get('updated', '?')}",
        f"ladder: {len(ladder)} rung(s), top={ladder[-1] if ladder else 'none'}",
    ]
    if ladder:
        streak = st.get("streak") or []
        pooled = pool_results(streak, s["plateau_ucb_z"]) if streak else None
        lines.append(f"streak: {len(streak)}/{s['patience']} non-promoting"
                     + (f", pooled edge {_fmt_pp(pooled['edge'])} UCB {_fmt_pp(pooled['edge_ucb'])}"
                        f" (plateau needs UCB < {_fmt_pp(s['min_edge'])})" if pooled else ""))
    vr = [r for r in st.get("rounds", []) if r.get("vs_random") is not None]
    if vr:
        r = vr[-1]
        lines.append(f"vs_random: {r['vs_random']:.4f} over {2 * r['num_pairs']} games (round {r['round']})")
    if st.get("final_vs_random"):
        fr = st["final_vs_random"]
        lines.append(f"final vs_random: {fr['rate']:.4f} over {fr['games']} games"
                     + (f", {fr['ppg']:+.3f} points/game" if fr.get("ppg") is not None else ""))
    if s["max_points"] > 1:
        lines.append(f"decision statistic: normalized points (max_points={s['max_points']}; "
                     f"rate = 0.5 + mean signed points / (2*max_points))")
    lines.append("  rnd stg   games  vs                 rate      z  win_rate    ppg  promoted")
    for r in st.get("rounds", [])[-10:]:
        opp = os.path.basename(r["opponent"]).replace(".pth", "")[:18]
        promo = os.path.basename(r["new_top"]).replace(".pth", "") if r.get("new_top") else "-"
        win = r.get("win_rate", r["rate"])
        ppg = f"{r['ppg']:+.3f}" if r.get("ppg") is not None else "   n/a"
        lines.append(f"  {r['round']:>3} {r['stage']:>3} {r['games']:>7}  {opp:<18} "
                     f"{r['rate']:.4f} {r['z']:>6.2f}    {win:.4f} {ppg}  {promo}")
    for sr in st.get("stage_results", []):
        lines.append(f"stage {sr['stage']}: {sr['reason']}")
    if st.get("error"):
        lines.append(f"error: {st['error']}")
    if st.get("verdict"):
        lines.append(st["verdict"])
    return "\n".join(lines)


def run_driver(config_path):
    return PlateauDriver(config_path).run()


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "_eval":
        _eval_main(sys.argv[2:])
    else:
        print("Use `python main.py --config CFG plateau` / `plateau-status`.")
        sys.exit(2)
