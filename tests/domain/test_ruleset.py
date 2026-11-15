import unittest
from pathlib import Path

from config.config_loader import ConfigLoader
from domain import Board, Dice, WHITE, BLACK, legal_moves
from domain.ruleset import RuleSet, get_ruleset, register_ruleset, registered_variants, _REGISTRY
from domain.plakoto_rules import PlakotoRules

CONFIG_PATH = str(Path(__file__).resolve().parents[2] / "config-test.yml")


class _DummyRules(RuleSet):
    name = "dummy_test_variant"
    default_encoder_version = "dummy_v1"
    supports_bearoff_db = False
    legal_moves = staticmethod(lambda board, color, dice: [])

    def initial_board(self, config):
        return Board.initial(config)

    def has_won(self, board, color):
        return False

    def is_open_for(self, board, i, color):
        return True

    def result_points(self, board, winner):
        return 2

    def make_encoder(self, config, version=None):
        return None


class TestRegistry(unittest.TestCase):
    def tearDown(self):
        _REGISTRY.pop(_DummyRules.name, None)

    def test_plakoto_registered_by_default(self):
        rules = get_ruleset("plakoto")
        self.assertIsInstance(rules, PlakotoRules)
        self.assertIn("plakoto", registered_variants())
        self.assertIs(get_ruleset("Plakoto"), rules)  # case-insensitive, singleton

    def test_unknown_variant_raises(self):
        with self.assertRaises(ValueError) as cm:
            get_ruleset("no_such_variant")
        self.assertIn("plakoto", str(cm.exception))

    def test_register_new_variant(self):
        dummy = register_ruleset(_DummyRules())
        self.assertIs(get_ruleset(_DummyRules.name), dummy)
        with self.assertRaises(ValueError):
            register_ruleset(_DummyRules())
        replacement = register_ruleset(_DummyRules(), replace=True)
        self.assertIs(get_ruleset(_DummyRules.name), replacement)

    def test_register_rejects_non_ruleset(self):
        with self.assertRaises(TypeError):
            register_ruleset(object())

    def test_abstract_methods_enforced(self):
        class Incomplete(RuleSet):
            name = "incomplete"
        with self.assertRaises(TypeError):
            Incomplete()


class TestPlakotoRules(unittest.TestCase):
    def setUp(self):
        self.config = ConfigLoader(CONFIG_PATH)
        self.rules = get_ruleset("plakoto")

    def test_metadata(self):
        self.assertEqual(self.rules.name, "plakoto")
        self.assertEqual(self.rules.default_encoder_version, "unary_v3")
        self.assertTrue(self.rules.supports_bearoff_db)

    def test_legal_moves_is_the_generator_itself(self):
        # Zero-overhead binding: no wrapper frame on the hot path.
        self.assertIs(self.rules.legal_moves, legal_moves)

    def test_initial_board_and_delegations(self):
        board = self.rules.initial_board(self.config)
        ref = Board.initial(self.config)
        self.assertEqual((board.n, board.color, board.pinned), (ref.n, ref.color, ref.pinned))
        for i in range(0, 26):
            for c in (WHITE, BLACK):
                self.assertEqual(self.rules.is_open_for(board, i, c), board.is_open_for(i, c))
        self.assertFalse(self.rules.has_won(board, WHITE))
        self.assertEqual(self.rules.result_points(board, WHITE), 1)

    def test_legal_moves_matches_module(self):
        board = self.rules.initial_board(self.config)
        dice = Dice(6)
        for d1 in range(1, 7):
            for d2 in range(1, 7):
                dice.set(d1, d2)
                self.assertEqual(self.rules.legal_moves(board, BLACK, dice),
                                 legal_moves(board, BLACK, dice))

    def test_make_encoder(self):
        enc = self.rules.make_encoder(self.config)
        self.assertEqual(enc.version, "unary_v3")
        self.assertEqual(enc.input_size, 486)
        legacy = self.rules.make_encoder(self.config, version="legacy_unary_v1")
        self.assertEqual(legacy.version, "legacy_unary_v1")


if __name__ == "__main__":
    unittest.main()
