import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from config.config_loader import ConfigLoader
from domain.constants import WHITE
from play.persistence import (
    SaveFile,
    SCHEMA_VERSION,
    IncompatibleSave,
    autosave_name,
    dump,
    file_exists,
    load,
    resolve_path,
)
from play.session import PlaySession, DiceMode


def _config():
    return ConfigLoader(str(Path(__file__).resolve().parents[2] / "config-test.yml"))


def _seed_session(dice_mode=DiceMode.MANUAL, human_color=WHITE):
    s = PlaySession(
        config=_config(),
        agent=None,
        ai_checkpoint_path="trained_model.pth",
        dice_mode=dice_mode,
        human_color=human_color,
        eval_depth=4,
        starting_player=WHITE,
    )
    # Play 3 plies including a pass.
    s.set_dice(3, 5)
    s.commit_move(s.possible_moves()[0])
    s.set_dice(4, 2)
    s.commit_move(s.possible_moves()[0])
    s.set_dice(6, 6)
    s.commit_pass()
    return s


class TestResolvePath(unittest.TestCase):
    def test_appends_json(self):
        self.assertEqual(resolve_path("foo", base_dir=Path("/tmp")), Path("/tmp/foo.json"))

    def test_keeps_explicit_json(self):
        self.assertEqual(resolve_path("foo.json", base_dir=Path("/tmp")), Path("/tmp/foo.json"))


class TestAutosaveName(unittest.TestCase):
    def test_format(self):
        now = datetime(2026, 5, 17, 14, 30, 45)
        self.assertEqual(autosave_name(now), "autosave_20260517_143045")

    def test_uses_now_by_default(self):
        name = autosave_name()
        self.assertTrue(name.startswith("autosave_"))
        self.assertEqual(len(name), len("autosave_YYYYMMDD_HHMMSS"))


class TestRoundTrip(unittest.TestCase):
    def test_dump_load_round_trip(self):
        s = _seed_session()
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            path = dump(s, "mygame", base_dir=base)
            self.assertEqual(path, base / "mygame.json")
            self.assertTrue(path.exists())

            sf = load(path)
            self.assertEqual(sf.schema_version, SCHEMA_VERSION)
            self.assertEqual(sf.ai_checkpoint_path, "trained_model.pth")
            self.assertEqual(sf.dice_mode, "manual")
            self.assertEqual(sf.human_color, "w")
            self.assertEqual(sf.eval_depth, 4)
            self.assertEqual(sf.starting_player, "white")
            self.assertEqual(len(sf.history), 3)
            self.assertTrue(sf.history[2]["was_pass"])
            self.assertIsNone(sf.history[2]["move"])
            self.assertEqual(sf.history[0]["dice"], [3, 5])

    def test_load_replays_board(self):
        s_orig = _seed_session()
        before = str(s_orig.game.board)
        before_player = s_orig.current_player()
        with tempfile.TemporaryDirectory() as td:
            path = dump(s_orig, "x", base_dir=Path(td))
            sf = load(path)
            s_replayed = PlaySession.from_save(_config(), sf, agent=None)
        self.assertEqual(str(s_replayed.game.board), before)
        self.assertEqual(s_replayed.current_player(), before_player)
        self.assertEqual(s_replayed.ply_count(), s_orig.ply_count())
        self.assertEqual(s_replayed.dice_mode, s_orig.dice_mode)
        self.assertEqual(s_replayed.eval_depth, s_orig.eval_depth)
        # Replayed session should not be dirty (no edits since load).
        self.assertFalse(s_replayed.dirty_since_save)

    def test_appends_json_on_dump(self):
        s = _seed_session()
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            path = dump(s, "noext", base_dir=base)
            self.assertEqual(path.suffix, ".json")
            self.assertTrue(file_exists("noext", base_dir=base))


class TestIncompatibleSchema(unittest.TestCase):
    def test_unknown_schema_raises(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "bogus.json"
            with path.open("w") as fh:
                json.dump({"schema_version": 999}, fh)
            with self.assertRaises(IncompatibleSave):
                load(path)


class TestSerializedShape(unittest.TestCase):
    def test_pass_serializes_with_null_move(self):
        s = _seed_session()
        with tempfile.TemporaryDirectory() as td:
            path = dump(s, "x", base_dir=Path(td))
            with path.open("r") as fh:
                data = json.load(fh)
        pass_entry = data["history"][2]
        self.assertEqual(pass_entry["move"], None)
        self.assertTrue(pass_entry["was_pass"])

    def test_move_serializes_as_from_to_pairs(self):
        s = _seed_session()
        with tempfile.TemporaryDirectory() as td:
            path = dump(s, "x", base_dir=Path(td))
            with path.open("r") as fh:
                data = json.load(fh)
        first_move = data["history"][0]["move"]
        self.assertIsInstance(first_move, list)
        for pair in first_move:
            self.assertEqual(len(pair), 2)
            for v in pair:
                self.assertIsInstance(v, int)


if __name__ == "__main__":
    unittest.main()
