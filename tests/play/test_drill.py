import types
import unittest
from pathlib import Path

from config.config_loader import ConfigLoader
from domain.board import Board
from domain.constants import WHITE, BLACK
from domain.dice import Dice
from domain.move_generation import legal_moves
from play import loop
from play.session import DiceMode, PlaySession


def _config():
    return ConfigLoader(str(Path(__file__).resolve().parents[2] / "config-test.yml"))


def _key(move) -> str:
    """Space-free canonical key, e.g. '(1->2,3->7)'.

    The v2 Move repr inserts spaces ('(1->2, 3->7)'); this helper gives a stable,
    space-free identity for test assertions and score maps.
    """
    return "(" + ",".join(f"{h.src}->{h.dst}" for h in move.halves) + ")"


def _ranked(setup, color, d1, d2, scores=None):
    """Build a [(Move, score)] list for a board described by `setup`.

    setup: {position: (color_int, count)}.  scores: optional {_key(move): score};
    moves not listed get 0.0.
    """
    cfg = _config()
    board = Board.from_config(cfg)  # empty board
    for pos, (c, n) in setup.items():
        board.set_point(pos, c, n)
    dice = Dice(6)
    dice.set(d1, d2)
    moves = legal_moves(board, color, dice)
    scores = scores or {}
    return [(m, scores.get(_key(m), 0.0)) for m in moves]


def _strs(matches):
    return [_key(m) for m, _ in matches]


class FakeIO(loop.IO):
    def __init__(self, inputs):
        self.inputs = list(inputs)
        self.outputs = []

    def input(self, prompt):
        if not self.inputs:
            raise AssertionError(f"ran out of input at: {prompt!r}")
        return self.inputs.pop(0)

    def output(self, msg):
        self.outputs.append(msg)

    def text(self):
        return "\n".join(self.outputs)


# --- _match_move: non-doubles ------------------------------------------


class TestMatchMoveNonDoubles(unittest.TestCase):
    def setUp(self):
        # White checkers at 1 and 3 (singletons); dice (1, 4).
        self.ranked = _ranked(
            {1: (WHITE, 1), 3: (WHITE, 1),
             10: (WHITE, 13), 24: (BLACK, 15)},
            WHITE, 1, 4,
        )

    def test_ordered_first_die_to_first_input(self):
        # input[0]=1 uses d1=1 (->2); input[1]=3 uses d2=4 (->7)
        self.assertEqual(_strs(_match([1, 3], self.ranked, (1, 4), True)), ["(1->2,3->7)"])

    def test_ordered_reversed_input(self):
        self.assertEqual(_strs(_match([3, 1], self.ranked, (1, 4), True)), ["(3->4,1->5)"])

    def test_merged_single_input(self):
        # One checker at 1 spanning both dice: 1 -> 1+1+4 = 6
        self.assertEqual(_strs(_match([1], self.ranked, (1, 4), True)), ["(1->6)"])

    def test_no_match_returns_empty(self):
        self.assertEqual(_match([7, 9], self.ranked, (1, 4), True), [])

    def test_black_direction(self):
        ranked = _ranked(
            {20: (BLACK, 1), 18: (BLACK, 1),
             15: (BLACK, 13), 1: (WHITE, 15)},
            BLACK, 1, 4,
        )
        # input[0]=20 uses d1=1 (->19); input[1]=18 uses d2=4 (->14)
        self.assertEqual(_strs(_match([20, 18], ranked, (1, 4), False)), ["(20->19,18->14)"])
        self.assertEqual(_strs(_match([18, 20], ranked, (1, 4), False)), ["(18->17,20->16)"])


# --- _match_move: doubles ----------------------------------------------


class TestMatchMoveDoubles(unittest.TestCase):
    def setUp(self):
        # White checkers at 3 and 8; dice (2, 2): every legal move uses all 4 dice.
        self.ranked = _ranked(
            {3: (WHITE, 1), 8: (WHITE, 1),
             12: (WHITE, 13), 24: (BLACK, 15)},
            WHITE, 2, 2,
        )
        self.legal = set(_strs(self.ranked))

    def test_walk_convention(self):
        # Walk the 3-checker three steps, move the 8-checker once.
        m = _match([3, 3, 3, 8], self.ranked, (2, 2), True)
        self.assertEqual(_strs(m), ["(3->5,5->7,7->9,8->10)"])
        self.assertIn("(3->5,5->7,7->9,8->10)", self.legal)

    def test_hop_start_convention_equivalent(self):
        # Listing explicit hop-starts resolves to the same move.
        self.assertEqual(
            _strs(_match([3, 5, 7, 8], self.ranked, (2, 2), True)),
            _strs(_match([3, 3, 3, 8], self.ranked, (2, 2), True)),
        )

    def test_two_inputs_no_partial_pasch(self):
        # Only 2 sources cannot describe a mandatory 4-die move -> no match.
        self.assertEqual(_match([3, 8], self.ranked, (2, 2), True), [])

    def test_match_is_deterministic_single_result(self):
        for froms in ([3, 3, 3, 8], [3, 5, 7, 8], [3, 8], [12, 12, 12, 12]):
            self.assertLessEqual(len(_match(froms, self.ranked, (2, 2), True)), 1)


# --- _drill_inner interactive loop -------------------------------------


def _blunder(ranked, played_str, dice, is_white):
    by_str = {_key(m): (m, s) for m, s in ranked}
    best_move, best_score = max(ranked, key=lambda ms: ms[1])
    played_move, played_score = by_str[played_str]
    return {
        "ply_num": 1,
        "snap": types.SimpleNamespace(dice_for_this_ply=dice),
        "board_str": "<board>",
        "ranked": ranked,
        "played_move": played_move,
        "played_score": played_score,
        "best_move": best_move,
        "best_score": best_score,
        "gap": best_score - played_score,
        "player_is_white": is_white,
    }


class TestDrillInner(unittest.TestCase):
    def _scenario(self):
        # (1->2,3->7) is best (0.60); (3->4,1->5) is the played blunder (0.40).
        ranked = _ranked(
            {1: (WHITE, 1), 3: (WHITE, 1),
             10: (WHITE, 13), 24: (BLACK, 15)},
            WHITE, 1, 4,
            scores={"(1->2,3->7)": 0.60, "(3->4,1->5)": 0.40},
        )
        return _blunder(ranked, "(3->4,1->5)", (1, 4), True)

    def test_wrong_then_best(self):
        b = self._scenario()
        io = FakeIO(["3 1", "1 3"])  # wrong (the blunder itself), then the best
        result = loop._drill_inner(b, io, 0.01, 0.03)
        self.assertEqual(result, "next")
        text = io.text()
        self.assertIn("think a little harder", text.lower())
        self.assertIn("excellent", text.lower())

    def test_solution_advances(self):
        b = self._scenario()
        io = FakeIO(["solution"])
        result = loop._drill_inner(b, io, 0.01, 0.03)
        self.assertEqual(result, "next")
        self.assertIn("Best:", io.text())

    def test_skip_advances(self):
        b = self._scenario()
        io = FakeIO(["skip"])
        self.assertEqual(loop._drill_inner(b, io, 0.01, 0.03), "next")

    def test_back_returns_back(self):
        b = self._scenario()
        io = FakeIO(["back"])
        self.assertEqual(loop._drill_inner(b, io, 0.01, 0.03), "back")

    def test_illegal_move_reprompts(self):
        b = self._scenario()
        io = FakeIO(["7 9", "skip"])  # illegal sources, then skip
        result = loop._drill_inner(b, io, 0.01, 0.03)
        self.assertEqual(result, "next")
        self.assertIn("no legal move", io.text().lower())


def _match(user_froms, ranked, dice, is_white):
    return loop._match_move(user_froms, ranked, dice, is_white)


# --- _collect_blunders: relative-gap detection -------------------------


class MapAgent:
    """Scores moves by a {str(move): score} map (default 0.5).  Deterministic."""

    def __init__(self, score_map):
        self.score_map = score_map

    def evaluate_moves(self, board, moves, color, lookahead_plies=1):
        return [self.score_map.get(_key(m), 0.5) for m in moves]

    def get_best_move(self, board, moves, color, lookahead_plies=1):
        scored = [(m, self.score_map.get(_key(m), 0.5)) for m in moves]
        return max(scored, key=lambda ms: ms[1])


class TestCollectBlunders(unittest.TestCase):
    def _session(self, score_map):
        return PlaySession(
            config=_config(),
            agent=MapAgent(score_map),
            ai_checkpoint_path="x.pth",
            dice_mode=DiceMode.MANUAL,
            human_color=WHITE,
            eval_depth=1,
            starting_player=WHITE,
        )

    def test_flags_relative_gap_blunder(self):
        # Probe the opening to choose a played move and a better alternative.
        probe = self._session({})
        probe.set_dice(3, 5)
        moves = probe.possible_moves()
        self.assertGreater(len(moves), 1)
        played, better = moves[0], moves[1]

        s = self._session({_key(better): 0.90, _key(played): 0.50})
        s.set_dice(3, 5)
        s.commit_move(played)

        blunders = loop._collect_blunders(s, threshold=0.10)
        self.assertEqual(len(blunders), 1)
        b = blunders[0]
        self.assertAlmostEqual(b["best_score"], 0.90)
        self.assertAlmostEqual(b["played_score"], 0.50)
        self.assertEqual(_key(b["best_move"]), _key(better))
        self.assertTrue(b["player_is_white"])

    def test_best_move_is_not_flagged(self):
        probe = self._session({})
        probe.set_dice(3, 5)
        moves = probe.possible_moves()
        best = moves[0]

        s = self._session({_key(best): 0.90})  # played == best
        s.set_dice(3, 5)
        s.commit_move(best)

        self.assertEqual(loop._collect_blunders(s, threshold=0.10), [])

    def test_small_gap_below_threshold_not_flagged(self):
        probe = self._session({})
        probe.set_dice(3, 5)
        moves = probe.possible_moves()
        played, better = moves[0], moves[1]

        # relative gap = (0.90 - 0.87)/0.90 ≈ 0.033 < 0.10
        s = self._session({_key(better): 0.90, _key(played): 0.87})
        s.set_dice(3, 5)
        s.commit_move(played)

        self.assertEqual(loop._collect_blunders(s, threshold=0.10), [])


if __name__ == "__main__":
    unittest.main()
