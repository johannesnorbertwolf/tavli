import json
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import List, Optional

from domain.constants import WHITE, BLACK
from play.session import DiceMode, PlaySession


SAVED_GAMES_DIR = Path("saved_games")
# Append-only log of every finished game (#104), one file per game, never pruned.
# Separate from the named/autosave saves under SAVED_GAMES_DIR.
GAME_LOG_DIR = SAVED_GAMES_DIR / "log"
# Schema 1: original resume save (move history only). Schema 2: optionally carries an
# `analysis` array of per-ply evaluations (#104). A file is written at version 2 only
# when it gains an `analysis` block; otherwise it stays a version-1 file that older
# readers load unchanged.
SCHEMA_VERSION = 1
SCHEMA_VERSION_ANALYSIS = 2


class MissingCheckpoint(FileNotFoundError):
    """Raised when a saved session references a checkpoint path that no longer exists."""

    def __init__(self, path: str):
        super().__init__(f"AI checkpoint not found: {path}")
        self.path = path


class IncompatibleSave(ValueError):
    """Raised when a save file is from an unknown schema version."""


@dataclass
class SaveFile:
    schema_version: int
    encoder_version: str
    ai_checkpoint_path: str
    dice_mode: str
    human_color: str
    eval_depth: int
    starting_player: str
    history: List[dict]
    # Per-ply post-game analysis (#104). Empty list when none has been computed (and
    # for every v1 file, which has no `analysis` key). Each entry:
    # {plyNumber, playedMove, playedScore, bestMove, bestScore, depth}.
    analysis: List[dict] = field(default_factory=list)
    # The winner ("white"/"black"/None) once decided. Persisted for the game log so a
    # listed game shows its result; resume saves leave it None.
    outcome: Optional[str] = None


def resolve_path(name: str, base_dir: Optional[Path] = None) -> Path:
    if base_dir is None:
        base_dir = SAVED_GAMES_DIR
    if not name.endswith(".json"):
        name = name + ".json"
    return base_dir / name


def autosave_name(now: Optional[datetime] = None) -> str:
    if now is None:
        now = datetime.now()
    return "autosave_" + now.strftime("%Y%m%d_%H%M%S")


def _winner_str(session: PlaySession) -> Optional[str]:
    winner = session.winner()
    if winner is None:
        return None
    return "white" if winner == WHITE else "black"


def _serialize_session(
    session: PlaySession,
    encoder_version: str,
    analysis: Optional[List[dict]] = None,
) -> dict:
    history = []
    for snap in session.history[1:]:
        if snap.was_pass:
            entry = {
                "dice": list(snap.dice_for_this_ply),
                "move": None,
                "was_pass": True,
            }
        else:
            half_moves = [[h.src, h.dst] for h in snap.move_played.halves]
            entry = {
                "dice": list(snap.dice_for_this_ply),
                "move": half_moves,
                "was_pass": False,
            }
        history.append(entry)
    data = {
        # Bump to v2 only when an analysis block is actually attached, so analysis-free
        # saves stay v1 files (older readers load them unchanged).
        "schema_version": SCHEMA_VERSION_ANALYSIS if analysis else SCHEMA_VERSION,
        "encoder_version": encoder_version,
        "ai_checkpoint_path": session.ai_checkpoint_path,
        "dice_mode": session.dice_mode.value,
        "human_color": "w" if session.human_color == WHITE else "b",
        "eval_depth": session.eval_depth,
        "starting_player": "white" if session.starting_player == WHITE else "black",
        "outcome": _winner_str(session),
        "history": history,
    }
    if analysis:
        data["analysis"] = analysis
    return data


def dump(session: PlaySession, name: str, encoder_version: str = "unary_v3",
         base_dir: Optional[Path] = None,
         analysis: Optional[List[dict]] = None) -> Path:
    path = resolve_path(name, base_dir=base_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _serialize_session(session, encoder_version, analysis=analysis)
    with path.open("w") as fh:
        json.dump(data, fh, indent=2)
    return path


def load(path: Path) -> SaveFile:
    with path.open("r") as fh:
        data = json.load(fh)
    schema = data.get("schema_version")
    # Accept v1 (no analysis) and v2 (optional analysis) — a missing `analysis` key
    # reads back as an empty list, so both versions load cleanly (#104). Anything else
    # is genuinely unknown and rejected.
    if schema not in (SCHEMA_VERSION, SCHEMA_VERSION_ANALYSIS):
        raise IncompatibleSave(
            f"unsupported schema_version {schema!r} "
            f"(this build expects {SCHEMA_VERSION} or {SCHEMA_VERSION_ANALYSIS})"
        )
    return SaveFile(
        schema_version=schema,
        encoder_version=data.get("encoder_version", "unknown"),
        ai_checkpoint_path=data["ai_checkpoint_path"],
        dice_mode=data["dice_mode"],
        human_color=data["human_color"],
        eval_depth=int(data["eval_depth"]),
        starting_player=data["starting_player"],
        history=list(data["history"]),
        analysis=list(data.get("analysis", [])),
        outcome=data.get("outcome"),
    )


def file_exists(name: str, base_dir: Optional[Path] = None) -> bool:
    return resolve_path(name, base_dir=base_dir).exists()


# ── Automatic game log (#104) ────────────────────────────────────────────────────


def log_name(now: Optional[datetime] = None) -> str:
    """Filename stem for a logged game: ``game_YYYYMMDD_HHMMSS`` (no extension)."""
    if now is None:
        now = datetime.now()
    return "game_" + now.strftime("%Y%m%d_%H%M%S")


def log_game(
    session: PlaySession,
    encoder_version: str = "unary_v3",
    log_dir: Optional[Path] = None,
    now: Optional[datetime] = None,
    analysis: Optional[List[dict]] = None,
) -> Path:
    """Append a finished game to the append-only log (#104), one file per game.

    Called at the end of every game regardless of outcome or any manual save. Reuses
    the resume `dump` format (so a logged game is itself replayable) and returns the
    written path — the caller keeps it to patch analysis back in later.
    """
    base = GAME_LOG_DIR if log_dir is None else log_dir
    return dump(session, log_name(now), encoder_version=encoder_version,
                base_dir=base, analysis=analysis)


def blunders_to_analysis(blunders: List[dict], depth: int) -> List[dict]:
    """Serialize ``_collect_blunders`` output to the persisted ``analysis`` schema.

    Field names and shape match the iOS `AnalysisEntry` exactly so the two platforms
    are interchangeable. `depth` is the look-ahead the ranking used (the CLI ranks at a
    single fixed `eval_depth`, unlike the iOS progressive 1→2→3-ply).
    """
    entries = []
    for b in blunders:
        entries.append({
            "plyNumber": b["ply_num"],
            "playedMove": [[h.src, h.dst] for h in b["played_move"].halves],
            "playedScore": float(b["played_score"]),
            "bestMove": [[h.src, h.dst] for h in b["best_move"].halves],
            "bestScore": float(b["best_score"]),
            "depth": int(depth),
        })
    return entries


def patch_analysis(path: Path, analysis: List[dict]) -> None:
    """Patch the ``analysis`` array into an existing game file in place (#104).

    Bumps the file to schema v2. No-op-safe: a missing file is silently skipped (the
    log may have been cleared). Read-modify-write so the move history and metadata are
    preserved untouched.
    """
    if not path.exists():
        return
    with path.open("r") as fh:
        data = json.load(fh)
    data["analysis"] = analysis
    data["schema_version"] = SCHEMA_VERSION_ANALYSIS
    with path.open("w") as fh:
        json.dump(data, fh, indent=2)


def load_analysis(path: Path) -> List[dict]:
    """The saved ``analysis`` for a game file, or ``[]`` if absent/none (#104).

    Lets a later review/drill detect cached analysis and skip recomputation. Reads
    cleanly from both v1 (no key) and v2 files.
    """
    if not path.exists():
        return []
    return load(path).analysis
