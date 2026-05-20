import unittest

from play.parser import (
    parse_command,
    parse_move_input,
    PlayMove,
    Undo,
    History,
    Eval,
    Save,
    Load,
    Review,
    Drill,
    Help,
    Quit,
    Unparseable,
)


class TestParseCommand(unittest.TestCase):
    # ---- rank / play-move ------------------------------------------------

    def test_play_move_basic(self):
        self.assertEqual(parse_command("1"), PlayMove(1))
        self.assertEqual(parse_command("12"), PlayMove(12))

    def test_play_move_with_whitespace(self):
        self.assertEqual(parse_command(" 2 "), PlayMove(2))

    def test_play_move_zero_padded(self):
        self.assertEqual(parse_command("01"), PlayMove(1))

    def test_play_move_zero_or_negative_is_unparseable(self):
        self.assertIsInstance(parse_command("0"), Unparseable)
        self.assertIsInstance(parse_command("-1"), Unparseable)

    # ---- undo ------------------------------------------------------------

    def test_undo_default_one(self):
        self.assertEqual(parse_command("u"), Undo(1))
        self.assertEqual(parse_command("undo"), Undo(1))

    def test_undo_with_count(self):
        self.assertEqual(parse_command("u 3"), Undo(3))
        self.assertEqual(parse_command("undo 3"), Undo(3))
        self.assertEqual(parse_command("u3"), Undo(3))
        self.assertEqual(parse_command("undo3"), Undo(3))

    def test_undo_count_must_be_positive(self):
        self.assertIsInstance(parse_command("u 0"), Unparseable)

    def test_undo_extra_tokens_is_unparseable(self):
        self.assertIsInstance(parse_command("u 3 4"), Unparseable)

    # ---- history / help / quit ------------------------------------------

    def test_history(self):
        self.assertEqual(parse_command("h"), History())
        self.assertEqual(parse_command("history"), History())

    def test_help(self):
        self.assertEqual(parse_command("?"), Help())
        self.assertEqual(parse_command("help"), Help())

    def test_quit(self):
        self.assertEqual(parse_command("q"), Quit())
        self.assertEqual(parse_command("quit"), Quit())

    # ---- eval ------------------------------------------------------------

    def test_eval_no_arg(self):
        self.assertEqual(parse_command("e"), Eval(None))
        self.assertEqual(parse_command("eval"), Eval(None))

    def test_eval_with_depth(self):
        self.assertEqual(parse_command("eval 5"), Eval(5))
        self.assertEqual(parse_command("e 5"), Eval(5))
        self.assertEqual(parse_command("eval5"), Eval(5))

    def test_eval_non_int_arg_is_unparseable(self):
        result = parse_command("eval x")
        self.assertIsInstance(result, Unparseable)
        self.assertIn("integer", result.reason)

    def test_eval_zero_or_negative_is_unparseable(self):
        self.assertIsInstance(parse_command("eval 0"), Unparseable)
        self.assertIsInstance(parse_command("eval -2"), Unparseable)

    # ---- save / load -----------------------------------------------------

    def test_save_with_name(self):
        self.assertEqual(parse_command("save foo"), Save("foo"))

    def test_save_preserves_case_and_extension(self):
        self.assertEqual(parse_command("save Foo.json"), Save("Foo.json"))

    def test_save_without_name_is_unparseable(self):
        self.assertIsInstance(parse_command("save"), Unparseable)
        self.assertIsInstance(parse_command("save   "), Unparseable)

    def test_load_with_name(self):
        self.assertEqual(parse_command("load foo"), Load("foo"))

    def test_load_without_name_is_unparseable(self):
        self.assertIsInstance(parse_command("load"), Unparseable)

    # ---- case / whitespace insensitivity --------------------------------

    def test_verb_case_insensitive(self):
        self.assertEqual(parse_command("UNDO 2"), Undo(2))
        self.assertEqual(parse_command("Quit"), Quit())
        self.assertEqual(parse_command("EVAL"), Eval(None))
        self.assertEqual(parse_command("Save foo"), Save("foo"))

    # ---- garbage ---------------------------------------------------------

    def test_empty_is_unparseable(self):
        result = parse_command("")
        self.assertIsInstance(result, Unparseable)
        self.assertTrue(result.reason)

    def test_whitespace_only_is_unparseable(self):
        self.assertIsInstance(parse_command("   "), Unparseable)

    def test_garbage_strings(self):
        for s in ("asdf", "7x", "u 3 4", "evalfoo bar"):
            with self.subTest(input=s):
                result = parse_command(s)
                self.assertIsInstance(result, Unparseable)
                self.assertTrue(result.reason, f"reason empty for {s!r}")


# ---- review / drill commands ------------------------------------------


class TestReviewDrillCommands(unittest.TestCase):
    def test_review_default_threshold(self):
        self.assertEqual(parse_command("review"), Review(threshold=0.10))

    def test_review_custom_threshold(self):
        self.assertEqual(parse_command("review 15"), Review(threshold=0.15))

    def test_drill_default_threshold(self):
        self.assertEqual(parse_command("drill"), Drill(threshold=0.10))

    def test_drill_custom_threshold(self):
        self.assertEqual(parse_command("drill 5"), Drill(threshold=0.05))

    def test_drill_zero_threshold_is_unparseable(self):
        self.assertIsInstance(parse_command("drill 0"), Unparseable)


# ---- parse_move_input --------------------------------------------------


class TestParseMoveInput(unittest.TestCase):
    def test_two_positions(self):
        self.assertEqual(parse_move_input("15 16"), [15, 16])

    def test_single_position(self):
        self.assertEqual(parse_move_input("8"), [8])

    def test_doubles_four_positions(self):
        self.assertEqual(parse_move_input("1 1 1 1"), [1, 1, 1, 1])

    def test_empty_returns_none(self):
        self.assertIsNone(parse_move_input(""))

    def test_command_word_returns_none(self):
        self.assertIsNone(parse_move_input("solution"))
        self.assertIsNone(parse_move_input("skip"))
        self.assertIsNone(parse_move_input("back"))

    def test_whitespace_ignored(self):
        self.assertEqual(parse_move_input("  3   5  "), [3, 5])


if __name__ == "__main__":
    unittest.main()
