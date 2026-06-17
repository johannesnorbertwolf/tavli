import unittest

import torch

from config.config_loader import ConfigLoader
from ai.checkpoint_io import load_agent_from_checkpoint
from ai.paired_eval import run_pairs, summarize


class TestPairedEval(unittest.TestCase):
    def test_summarize_math(self):
        # 3 pairs A wins both, 1 split, 1 B wins both → mean_d=0.4, rate=0.7.
        results = [(1, 2), (1, 2), (1, 2), (0, 1), (-1, 0)]
        s = summarize(results)
        self.assertAlmostEqual(s["mean_d"], 0.4)
        self.assertAlmostEqual(s["rate"], 0.7)
        self.assertEqual(s["pos"], 3)
        self.assertEqual(s["neg"], 1)
        self.assertEqual(s["ties"], 1)
        self.assertEqual(s["num_games"], 10)

    def test_self_comparison_perfectly_cancels(self):
        # A model vs itself on identical dice: the two orientations are byte-identical
        # games, so a_wins == 1 and d_k == 0 for every pair. This proves the duplicate
        # dice (common random numbers) are actually shared across orientations and that
        # move selection is deterministic.
        config = ConfigLoader("config-test.yml")
        agent, _ = load_agent_from_checkpoint(
            "models/gold_v1.pth", config, device=torch.device("cpu"))
        results = run_pairs(agent, agent, config, seeds=range(12), lookahead=1)
        d = [r[0] for r in results]
        a_wins = [r[1] for r in results]
        self.assertTrue(all(x == 0 for x in d), f"expected all d_k==0, got {d}")
        self.assertTrue(all(w == 1 for w in a_wins))
        s = summarize(results)
        self.assertEqual(s["rate"], 0.5)
        self.assertEqual(s["z"], 0.0)
        self.assertEqual(s["ties"], 12)


if __name__ == "__main__":
    unittest.main()
