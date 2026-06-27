"""Tests for the automatic game log + optional analysis write-back (#104).

Pure persistence / loop wiring — no model inference: a `StubAgent` supplies constant
scores so blunder detection and analysis serialization can be exercised deterministically.
"""
import json
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from domain.move import HalfMove, Move
from play import loop, persistence
from play.session import DiceMode, PlaySession


def _config():
    return ConfigLoader(str(Path(__file__).resolve().parents[2] / "config-test.yml"))


class StubAgent:
    """Ranks the *first* legal move highest and the rest lower, so a played move that
    isn't first registers a measurable relative gap (a blunder for the drill/review)."""

    def evaluate_moves(self, board, moves, color, lookahead_plies=1, **kwargs):
        return [0.8 if i == 0 else 0.4 for i in range(len(moves))]

    def get_best_move(self, board, moves, color, lookahead_plies=1, **kwargs):
        return moves[0], 0.8


def _seed_session(dice_mode=DiceMode.MANUAL, human_color=WHITE, agent=None):
    s = PlaySession(
        config=_config(),
        agent=agent if agent is not None else StubAgent(),
        ai_checkpoint_path="trained_model.pth",
        dice_mode=dice_mode,
        human_color=human_color,
        eval_depth=2,
        starting_player=WHITE,
    )
    s.set_dice(3, 5)
    s.commit_move(s.possible_moves()[0])
    s.set_dice(4, 2)
    s.commit_move(s.possible_moves()[0])
    return s


# ── Game-log naming + file IO ────────────────────────────────────────────────────


class TestLogName(unittest.TestCase):
    def test_format(self):
        now = datetime(2026, 6, 26, 14, 30, 45)
        self.assertEqual(persistence.log_name(now), "game_20260626_143045")

    def test_uses_now_by_default(self):
        name = persistence.log_name()
        self.assertTrue(name.startswith("game_"))
        self.assertEqual(len(name), len("game_YYYYMMDD_HHMMSS"))


class TestLogGame(unittest.TestCase):
    def test_log_game_writes_replayable_v1_file(self):
        s = _seed_session()
        with tempfile.TemporaryDirectory() as td:
            path = persistence.log_game(s, log_dir=Path(td),
                                        now=datetime(2026, 6, 26, 1, 2, 3))
            self.assertEqual(path.name, "game_20260626_010203.json")
            with path.open() as fh:
                data = json.load(fh)
        # No analysis yet → stays a v1 file, no `analysis` key.
        self.assertEqual(data["schema_version"], persistence.SCHEMA_VERSION)
        self.assertNotIn("analysis", data)
        self.assertEqual(len(data["history"]), 2)

    def test_logged_game_replays(self):
        s = _seed_session()
        before = str(s.game.board)
        with tempfile.TemporaryDirectory() as td:
            path = persistence.log_game(s, log_dir=Path(td))
            sf = persistence.load(path)
            replayed = PlaySession.from_save(_config(), sf, agent=None)
        self.assertEqual(str(replayed.game.board), before)
        # v1 load yields empty analysis.
        self.assertEqual(sf.analysis, [])


# ── v1 back-compat ───────────────────────────────────────────────────────────────


class TestV1BackCompat(unittest.TestCase):
    def test_v1_file_loads_with_empty_analysis(self):
        """A pre-#104 file (schema 1, no `analysis`/`outcome` keys) loads cleanly."""
        v1 = {
            "schema_version": 1,
            "encoder_version": "unary_v3",
            "ai_checkpoint_path": "trained_model.pth",
            "dice_mode": "manual",
            "human_color": "w",
            "eval_depth": 2,
            "starting_player": "white",
            "history": [{"dice": [3, 5], "move": [[1, 4]], "was_pass": False}],
        }
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "old.json"
            with path.open("w") as fh:
                json.dump(v1, fh)
            sf = persistence.load(path)
        self.assertEqual(sf.schema_version, 1)
        self.assertEqual(sf.analysis, [])
        self.assertIsNone(sf.outcome)

    def test_unknown_schema_still_rejected(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "future.json"
            with path.open("w") as fh:
                json.dump({"schema_version": 999}, fh)
            with self.assertRaises(persistence.IncompatibleSave):
                persistence.load(path)


# ── Analysis serialization + write-back round-trip ───────────────────────────────


class TestBlundersToAnalysis(unittest.TestCase):
    def test_shape_matches_schema(self):
        blunders = [{
            "ply_num": 3,
            "played_move": Move((HalfMove(13, 7),)),
            "played_score": 0.42,
            "best_move": Move((HalfMove(13, 10), HalfMove(10, 7))),
            "best_score": 0.61,
        }]
        out = persistence.blunders_to_analysis(blunders, depth=2)
        self.assertEqual(out, [{
            "plyNumber": 3,
            "playedMove": [[13, 7]],
            "playedScore": 0.42,
            "bestMove": [[13, 10], [10, 7]],
            "bestScore": 0.61,
            "depth": 2,
        }])


class TestPatchAnalysisRoundTrip(unittest.TestCase):
    def test_patch_bumps_to_v2_and_round_trips(self):
        s = _seed_session()
        with tempfile.TemporaryDirectory() as td:
            path = persistence.log_game(s, log_dir=Path(td))
            analysis = [{
                "plyNumber": 1, "playedMove": [[1, 4]], "playedScore": 0.4,
                "bestMove": [[1, 6]], "bestScore": 0.8, "depth": 2,
            }]
            persistence.patch_analysis(path, analysis)

            with path.open() as fh:
                data = json.load(fh)
            self.assertEqual(data["schema_version"], persistence.SCHEMA_VERSION_ANALYSIS)
            self.assertEqual(data["analysis"], analysis)

            # And it reads back through both the SaveFile loader and the helper.
            self.assertEqual(persistence.load(path).analysis, analysis)
            self.assertEqual(persistence.load_analysis(path), analysis)

            # History is untouched by the patch.
            self.assertEqual(len(data["history"]), 2)

    def test_patch_missing_file_is_noop(self):
        with tempfile.TemporaryDirectory() as td:
            missing = Path(td) / "nope.json"
            persistence.patch_analysis(missing, [{"plyNumber": 1}])  # must not raise
            self.assertFalse(missing.exists())

    def test_load_analysis_missing_file_returns_empty(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(persistence.load_analysis(Path(td) / "nope.json"), [])


# ── End-to-end loop wiring ───────────────────────────────────────────────────────


class FakeIO(loop.IO):
    def __init__(self, inputs):
        self.inputs = list(inputs)
        self.outputs = []

    def input(self, prompt):
        if not self.inputs:
            raise AssertionError(f"FakeIO ran out of input at prompt: {prompt!r}")
        return self.inputs.pop(0)

    def output(self, msg):
        self.outputs.append(msg)


class TestLoopAutoLogsAndWritesBack(unittest.TestCase):
    """Drive a game to completion through the loop, then run review, and confirm the
    game was auto-logged and the analysis written back — and that a *second* review
    reads the cached analysis instead of recomputing (#104)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._patch = patch.object(persistence, "GAME_LOG_DIR", Path(self._tmp.name))
        self._patch.start()

    def tearDown(self):
        self._patch.stop()
        self._tmp.cleanup()

    def _one_move_from_win(self, s):
        b = s.game.board
        for i in range(0, b.board_size + 2):
            b.set_point(i, 0, 0)
        b.borne_off[WHITE] = 14
        b.borne_off[BLACK] = 0
        b.set_point(23, WHITE, 1)
        b.set_point(1, BLACK, 5)

    def _winning_rank(self, s):
        for idx, (move, _) in enumerate(s.ranked_moves(), start=1):
            token = s.game.board.apply(move, WHITE)
            won = s.game.board.has_won(WHITE)
            s.game.board.undo(token)
            if won:
                return idx
        return None

    def test_auto_log_on_game_over(self):
        s = PlaySession(config=_config(), agent=StubAgent(),
                        ai_checkpoint_path="trained_model.pth",
                        dice_mode=DiceMode.MANUAL, human_color=WHITE,
                        eval_depth=2, starting_player=WHITE)
        self._one_move_from_win(s)
        s.set_dice(2, 5)
        rank = self._winning_rank(s)
        self.assertIsNotNone(rank)

        io = FakeIO([str(rank), "q", "q"])
        final = loop.run(s, io)
        self.assertTrue(final.is_terminal())

        # The game was logged automatically (no `save` issued).
        self.assertIsNotNone(final.log_path)
        self.assertTrue(final.log_path.exists())
        logged = list(Path(self._tmp.name).glob("game_*.json"))
        self.assertEqual(len(logged), 1)
        # No analysis until review/drill runs.
        self.assertEqual(persistence.load_analysis(final.log_path), [])

    def test_review_writes_analysis_back_then_reuses_it(self):
        # A short, fully-legal game: White opens with a non-optimal move (the StubAgent
        # ranks the first legal move highest, so any other choice is a recorded blunder
        # under a 0% threshold). No board force-mutation, so `_collect_blunders`'
        # replay reproduces the game faithfully and the write-back is deterministic.
        s = _seed_session()
        s.log_path = persistence.log_game(s, log_dir=Path(self._tmp.name))

        # Re-seed with a guaranteed non-optimal opening ply so a blunder exists.
        s2 = PlaySession(config=_config(), agent=StubAgent(),
                         ai_checkpoint_path="trained_model.pth",
                         dice_mode=DiceMode.MANUAL, human_color=WHITE,
                         eval_depth=2, starting_player=WHITE)
        s2.set_dice(3, 5)
        moves = s2.possible_moves()
        self.assertGreater(len(moves), 1)
        s2.commit_move(moves[-1])          # White: a lower-scored choice → blunder
        s2.set_dice(2, 4)
        s2.commit_move(s2.possible_moves()[0])   # Black replies
        s2.log_path = persistence.log_game(s2, log_dir=Path(self._tmp.name))

        # First review at a 0% threshold flags the sub-optimal White ply and writes it
        # back; the analysis file becomes v2.
        io1 = FakeIO([])
        loop._handle_review(s2, io1, threshold=0.0)
        cached = persistence.load_analysis(s2.log_path)
        self.assertTrue(cached, "expected the non-optimal White ply to be recorded")
        for e in cached:
            self.assertEqual(set(e), {"plyNumber", "playedMove", "playedScore",
                                      "bestMove", "bestScore", "depth"})
            self.assertEqual(e["depth"], 2)
        with s2.log_path.open() as fh:
            self.assertEqual(json.load(fh)["schema_version"],
                             persistence.SCHEMA_VERSION_ANALYSIS)

        # Second review reuses the saved analysis — announced inline, no recompute.
        io2 = FakeIO([])
        loop._handle_review(s2, io2, threshold=0.0)
        self.assertIn("(using saved analysis)", " ".join(io2.outputs))


if __name__ == "__main__":
    unittest.main()
