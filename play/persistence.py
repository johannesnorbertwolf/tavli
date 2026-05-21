import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import List, Optional

from domain.constants import WHITE
from play.session import DiceMode, PlaySession


SAVED_GAMES_DIR = Path("saved_games")
SCHEMA_VERSION = 1


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


def _serialize_session(session: PlaySession, encoder_version: str) -> dict:
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
    return {
        "schema_version": SCHEMA_VERSION,
        "encoder_version": encoder_version,
        "ai_checkpoint_path": session.ai_checkpoint_path,
        "dice_mode": session.dice_mode.value,
        "human_color": "w" if session.human_color == WHITE else "b",
        "eval_depth": session.eval_depth,
        "starting_player": "white" if session.starting_player == WHITE else "black",
        "history": history,
    }


def dump(session: PlaySession, name: str, encoder_version: str = "unary_v3",
         base_dir: Optional[Path] = None) -> Path:
    path = resolve_path(name, base_dir=base_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _serialize_session(session, encoder_version)
    with path.open("w") as fh:
        json.dump(data, fh, indent=2)
    return path


def load(path: Path) -> SaveFile:
    with path.open("r") as fh:
        data = json.load(fh)
    schema = data.get("schema_version")
    if schema != SCHEMA_VERSION:
        raise IncompatibleSave(
            f"unsupported schema_version {schema!r} (this build expects {SCHEMA_VERSION})"
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
    )


def file_exists(name: str, base_dir: Optional[Path] = None) -> bool:
    return resolve_path(name, base_dir=base_dir).exists()
