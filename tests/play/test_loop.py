import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from play import loop, persistence
from play.session import DiceMode, PlaySession


def _config():
    return ConfigLoader(str(Path(__file__).resolve().parents[2] / "config-test.yml"))


class StubAgent:
    def __init__(self, score=0.5):
        self.score = score

    def evaluate_moves(self, board, moves, color, lookahead_plies=1, **kwargs):
        return [self.score] * len(moves)

    def get_best_move(self, board, moves, color, lookahead_plies=1, **kwargs):
        return moves[0], self.score


class FakeIO(loop.IO):
    def __init__(self, inputs):
        self.inputs = list(inputs)
        self.outputs = []
        self.prompts = []

    def input(self, prompt):
        self.prompts.append(prompt)
        if not self.inputs:
            raise AssertionError(f"FakeIO ran out of input at prompt: {prompt!r}")
        return self.inputs.pop(0)

    def output(self, msg):
        self.outputs.append(msg)

    def all_output(self):
        return "\n".join(self.outputs)


def _new_session(
    dice_mode=DiceMode.MANUAL,
    human_color=WHITE,
    starting_player=WHITE,
    agent=None,
):
    return PlaySession(
        config=_config(),
        agent=agent if agent is not None else StubAgent(),
        ai_checkpoint_path="trained_model.pth",
        dice_mode=dice_mode,
        human_color=human_color,
        eval_depth=4,
        starting_player=starting_player,
    )


# --- basic plays --------------------------------------------------------


class TestPlayOneMoveAndQuit(unittest.TestCase):
    def test_play_one_move_and_quit(self):
        s = _new_session()
        # Script: enter dice, pick rank 1, quit (and discard dirty progress).
        io = FakeIO(["3 5", "1", "q", "q"])
        final = loop.run(s, io)
        self.assertEqual(final.ply_count(), 1)
        self.assertEqual(io.inputs, [])
        self.assertFalse(final.is_terminal())


class TestMalformedDoesNotAdvance(unittest.TestCase):
    def test_typo_then_valid(self):
        s = _new_session()
        io = FakeIO(["3 5", "asdf", "7x", "1", "q", "q"])
        final = loop.run(s, io)
        self.assertEqual(final.ply_count(), 1)
        self.assertTrue(any("unrecognised" in o.lower() for o in io.outputs))


# --- undo behaviour ----------------------------------------------------


class TestUndoFromHumanTurn(unittest.TestCase):
    def test_manual_undo_returns_to_dice_prompt(self):
        s = _new_session(dice_mode=DiceMode.MANUAL)
        io = FakeIO(["3 5", "1", "u", "6 1", "1", "q", "q"])
        final = loop.run(s, io)
        # After undo: pending_dice cleared (manual mode), one re-played ply with new dice.
        self.assertEqual(final.ply_count(), 1)
        self.assertEqual(final.history[-1].dice_for_this_ply, (6, 1))


# --- eval stickiness ---------------------------------------------------


class TestEvalSticky(unittest.TestCase):
    def test_eval_n_updates_session_depth(self):
        s = _new_session()
        self.assertEqual(s.eval_depth, 4)
        io = FakeIO(["3 5", "eval 5", "eval", "1", "q", "q"])
        final = loop.run(s, io)
        self.assertEqual(final.eval_depth, 5)
        self.assertEqual(final.ply_count(), 1)


# --- AI move selection -------------------------------------------------


class RecordingAgent(StubAgent):
    """Captures the kwargs passed to get_best_move so we can assert the
    play loop wires the time-budget lookahead through to the agent."""

    def __init__(self, score=0.5):
        super().__init__(score)
        self.last_kwargs = None

    def get_best_move(self, board, moves, color, lookahead_plies=1, **kwargs):
        self.last_kwargs = kwargs
        return moves[0], self.score


class TestAiTurnUsesTimeBudget(unittest.TestCase):
    def test_ai_turn_forwards_search_knobs(self):
        agent = RecordingAgent()
        # Human is Black, White starts -> the first turn is the AI's (White).
        s = _new_session(human_color=BLACK, starting_player=WHITE, agent=agent)
        s.set_dice(3, 5)
        io = FakeIO([])

        loop._ai_turn(s, io)

        self.assertIsNotNone(agent.last_kwargs)
        self.assertEqual(
            agent.last_kwargs.get("time_budget_s"),
            s.config.get_play_time_budget_s(),
        )
        self.assertEqual(
            agent.last_kwargs.get("relative_cutoff"),
            s.config.get_search_relative_cutoff(),
        )
        self.assertEqual(
            agent.last_kwargs.get("max_branch"),
            s.config.get_search_max_branch(),
        )
        # The AI move was committed.
        self.assertEqual(s.ply_count(), 1)


# --- save / load -------------------------------------------------------


class TestSaveLoadRoundTrip(unittest.TestCase):
    def test_save_then_load_in_fresh_session(self):
        with tempfile.TemporaryDirectory() as td:
            with patch.object(persistence, "SAVED_GAMES_DIR", Path(td)):
                # Session 1: play 1 ply, save, quit.
                s1 = _new_session()
                io1 = FakeIO(["3 5", "1", "save mygame", "q"])
                final1 = loop.run(s1, io1, agent_loader=lambda path: StubAgent())
                self.assertEqual(final1.ply_count(), 1)
                self.assertEqual(final1.last_save_name, "mygame")

                # Session 2: fresh, then load.
                s2 = _new_session()
                io2 = FakeIO(["load mygame", "q"])
                final2 = loop.run(s2, io2, agent_loader=lambda path: StubAgent())
                self.assertEqual(final2.ply_count(), 1)
                self.assertEqual(final2.last_save_name, "mygame")


class TestAutoSaveOnLoadWhileDirty(unittest.TestCase):
    def test_load_other_autosaves_first(self):
        # Pre-create a saved donor session in temp dir.
        donor = _new_session()
        donor.set_dice(1, 2)
        donor.commit_move(donor.possible_moves()[0])
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            with patch.object(persistence, "SAVED_GAMES_DIR", base):
                persistence.dump(donor, "donor")

                # Now start a fresh session, play a move (so it's dirty + never saved),
                # then `load donor`. We expect an autosave_* file to appear.
                s = _new_session()
                io = FakeIO([
                    "3 5", "1",
                    "load donor",
                    "q", "q",
                ])
                final = loop.run(s, io, agent_loader=lambda path: StubAgent())

                autosaves = list(base.glob("autosave_*.json"))
                self.assertEqual(len(autosaves), 1, f"expected one autosave, got {autosaves}")
                self.assertTrue(any("auto-saved" in o for o in io.outputs))
                self.assertEqual(final.last_save_name, "donor")


# --- post-terminal -----------------------------------------------------


class TestPostTerminalRejectsPlay(unittest.TestCase):
    def _setup_one_move_from_win(self, s):
        b = s.game.board
        for i in range(0, b.board_size + 2):
            b.set_point(i, 0, 0)
        b.borne_off[WHITE] = 14
        b.borne_off[BLACK] = 0
        b.set_point(23, WHITE, 1)
        b.set_point(1, BLACK, 5)

    def test_play_then_post_game_rejects_rank(self):
        s = _new_session()
        self._setup_one_move_from_win(s)
        s.set_dice(2, 5)
        # Find the rank of the winning move in `ranked_moves`.
        ranked = s.ranked_moves()
        winning_rank = None
        for idx, (move, _) in enumerate(ranked, start=1):
            token = s.game.board.apply(move, WHITE)
            won = s.game.board.has_won(WHITE)
            s.game.board.undo(token)
            if won:
                winning_rank = idx
                break
        self.assertIsNotNone(winning_rank)

        io = FakeIO([str(winning_rank), "1", "u", "q"])
        # After play: terminal. Then "1" should be rejected; "u" un-ends; then on
        # the now-active human turn we quit (no dirty prompt because the only ply
        # got undone — wait, undo also marks dirty=True; so q triggers dirty prompt).
        # Append a second "q" to discard.
        io.inputs.append("q")
        final = loop.run(s, io)
        self.assertFalse(final.is_terminal())
        # Post-game "1" should have triggered the reject message.
        self.assertTrue(
            any("post-game accepts" in o or "post-game" in o for o in io.outputs),
            f"expected post-game rejection message; got: {io.outputs}",
        )


# --- post-game review --------------------------------------------------


class TestPostGameReview(unittest.TestCase):
    def _setup_one_move_from_win(self, s):
        b = s.game.board
        for i in range(0, b.board_size + 2):
            b.set_point(i, 0, 0)
        b.borne_off[WHITE] = 14
        b.borne_off[BLACK] = 0
        b.set_point(23, WHITE, 1)
        b.set_point(1, BLACK, 5)

    def test_review_runs_and_produces_output(self):
        s = _new_session()
        self._setup_one_move_from_win(s)
        s.set_dice(2, 5)
        ranked = s.ranked_moves()
        winning_rank = None
        for idx, (move, _) in enumerate(ranked, start=1):
            token = s.game.board.apply(move, WHITE)
            won = s.game.board.has_won(WHITE)
            s.game.board.undo(token)
            if won:
                winning_rank = idx
                break
        self.assertIsNotNone(winning_rank)

        # Play the winning move → terminal. Then run review, then quit.
        io = FakeIO([str(winning_rank), "review", "q", "q"])
        final = loop.run(s, io)
        self.assertTrue(final.is_terminal())
        review_output = " ".join(io.outputs)
        self.assertTrue(
            "blunder" in review_output.lower() or "well played" in review_output.lower(),
            f"expected review output; got: {io.outputs}",
        )

    def test_review_threshold_arg_accepted(self):
        s = _new_session()
        self._setup_one_move_from_win(s)
        s.set_dice(2, 5)
        ranked = s.ranked_moves()
        winning_rank = None
        for idx, (move, _) in enumerate(ranked, start=1):
            token = s.game.board.apply(move, WHITE)
            won = s.game.board.has_won(WHITE)
            s.game.board.undo(token)
            if won:
                winning_rank = idx
                break
        self.assertIsNotNone(winning_rank)
        io = FakeIO([str(winning_rank), "review 5", "q", "q"])
        final = loop.run(s, io)
        self.assertTrue(final.is_terminal())


# --- post-game drill ---------------------------------------------------


class TestPostGameDrill(unittest.TestCase):
    def _setup_one_move_from_win(self, s):
        b = s.game.board
        for i in range(0, b.board_size + 2):
            b.set_point(i, 0, 0)
        b.borne_off[WHITE] = 14
        b.borne_off[BLACK] = 0
        b.set_point(23, WHITE, 1)
        b.set_point(1, BLACK, 5)

    def _winning_rank(self, s):
        ranked = s.ranked_moves()
        for idx, (move, _) in enumerate(ranked, start=1):
            token = s.game.board.apply(move, WHITE)
            won = s.game.board.has_won(WHITE)
            s.game.board.undo(token)
            if won:
                return idx
        return None

    def test_drill_skip_exits_cleanly(self):
        s = _new_session()
        self._setup_one_move_from_win(s)
        s.set_dice(2, 5)
        rank = self._winning_rank(s)
        self.assertIsNotNone(rank)
        # After winning: drill → skip (no blunders in test board) → q q
        io = FakeIO([str(rank), "drill", "q", "q"])
        final = loop.run(s, io)
        self.assertTrue(final.is_terminal())

    def test_drill_solution_shows_best_move(self):
        s = _new_session()
        self._setup_one_move_from_win(s)
        s.set_dice(2, 5)
        rank = self._winning_rank(s)
        self.assertIsNotNone(rank)
        # If there are blunders: solution reveals them; if none: "No blunders" shown.
        io = FakeIO([str(rank), "drill", "q", "q"])
        final = loop.run(s, io)
        all_out = " ".join(io.outputs)
        self.assertTrue(
            "blunder" in all_out.lower() or "well played" in all_out.lower(),
            f"expected drill output; got: {io.outputs}",
        )
        self.assertTrue(final.is_terminal())


# --- no-moves ----------------------------------------------------------


class TestNoMovesPrompt(unittest.TestCase):
    def test_enter_records_pass(self):
        s = _new_session(dice_mode=DiceMode.MANUAL, human_color=WHITE)
        s.set_dice(3, 5)
        io = FakeIO([""])
        act = loop._no_moves(s, io)
        self.assertEqual(act.kind, "advance")
        self.assertEqual(s.ply_count(), 1)
        self.assertTrue(s.history[-1].was_pass)

    def test_u_when_no_prior_human_decision_is_noop(self):
        # human=BLACK so that after white's opening ply, it's the human's turn.
        # The human hasn't made any decision yet, so 'u' from no-moves is a no-op.
        s = _new_session(dice_mode=DiceMode.MANUAL, human_color=BLACK)
        s.set_dice(3, 5)
        s.commit_move(s.possible_moves()[0])  # white plays ply 1
        s.set_dice(3, 5)                       # now BLACK (human) to move
        io = FakeIO(["u"])
        act = loop._no_moves(s, io)
        self.assertEqual(act.kind, "advance")
        self.assertEqual(s.ply_count(), 1)


if __name__ == "__main__":
    unittest.main()
