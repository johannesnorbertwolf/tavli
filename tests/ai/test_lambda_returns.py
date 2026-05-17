import unittest

import numpy as np

from ai.td_lambda_training import compute_lambda_returns, ReplayBuffer


class TestComputeLambdaReturns(unittest.TestCase):
    def test_t1_white_wins_immediately(self):
        # White's single move ends the game with a White win.
        # movers = [W=True], terminal_winner_white = True
        # i=0: N=1, terminal_value=1.0 → target=1.0
        # post-terminal state target = 0.0
        values = np.array([0.5, 0.5], dtype=np.float32)
        movers = np.array([True], dtype=bool)
        targets = compute_lambda_returns(values, movers, terminal_winner_white=True, lambda_=0.7)
        np.testing.assert_allclose(targets, [1.0, 0.0], atol=1e-6)

    def test_t1_mover_loses(self):
        # Mover_0 plays and loses (hypothetical; in practice the winning move is the last mover).
        # Here we test the math: mover_0 != winner → terminal_value = 0.
        values = np.array([0.5, 0.5], dtype=np.float32)
        movers = np.array([True], dtype=bool)
        targets = compute_lambda_returns(values, movers, terminal_winner_white=False, lambda_=0.7)
        np.testing.assert_allclose(targets, [0.0, 0.0], atol=1e-6)

    def test_t2_lambda_half_perspective_flip(self):
        # T=2, λ=0.5. movers=[W, B], winner=Black (consistent: mover_{T-1}=B=winner).
        # values[0]=0.6, values[1]=0.4, values[2]=anything (post-terminal not used in computation).
        # i=0 (W): N=2, terminal_value=0.0 (W lost).
        #   G^(1) = U(1, W) = 1 - V[1] = 0.6  (mover_1=B≠W flips)
        #   G^(2) = 0.0
        #   weights = [(1-λ)·λ^0, λ^1] = [0.5, 0.5]
        #   target = 0.5·0.6 + 0.5·0.0 = 0.3
        # i=1 (B): N=1, terminal_value=1.0 (B won)
        #   target = 1.0
        values = np.array([0.6, 0.4, 0.99], dtype=np.float32)
        movers = np.array([True, False], dtype=bool)
        targets = compute_lambda_returns(values, movers, terminal_winner_white=False, lambda_=0.5)
        np.testing.assert_allclose(targets, [0.3, 1.0, 0.0], atol=1e-6)

    def test_t3_lambda_one_is_monte_carlo(self):
        # λ=1.0 → only terminal return matters: G^λ_i = U_terminal(mover_i).
        # movers=[B, W, B], winner=B.
        values = np.array([0.5, 0.5, 0.5, 0.5], dtype=np.float32)
        movers = np.array([False, True, False], dtype=bool)
        targets = compute_lambda_returns(values, movers, terminal_winner_white=False, lambda_=1.0)
        # targets[0]: B==B → 1.0
        # targets[1]: W≠B → 0.0
        # targets[2]: B==B → 1.0
        # targets[3]: post-terminal → 0.0
        np.testing.assert_allclose(targets, [1.0, 0.0, 1.0, 0.0], atol=1e-6)

    def test_t3_lambda_zero_is_td0(self):
        # λ=0 → only n=1 bootstrap matters: G^λ_i = U(i+1, mover_i).
        values = np.array([0.4, 0.6, 0.3, 0.7], dtype=np.float32)
        movers = np.array([False, True, False], dtype=bool)
        targets = compute_lambda_returns(values, movers, terminal_winner_white=False, lambda_=0.0)
        # i=0 (B): j=1, mover_1=W≠B → flip → 1-0.6 = 0.4
        # i=1 (W): j=2, mover_2=B≠W → flip → 1-0.3 = 0.7
        # i=2 (B): j=3=T, terminal_value = 1.0 (B won)
        # targets[3] = 0.0
        np.testing.assert_allclose(targets, [0.4, 0.7, 1.0, 0.0], atol=1e-6)

    def test_targets_bounded_in_unit_interval(self):
        # Sanity: targets must lie in [0, 1] when V is in [0, 1].
        rng = np.random.default_rng(42)
        for _ in range(20):
            T = rng.integers(1, 30)
            values = rng.random(T + 1).astype(np.float32)
            movers = rng.random(T) > 0.5
            winner = bool(rng.random() > 0.5)
            lam = float(rng.random())
            targets = compute_lambda_returns(values, movers, winner, lam)
            self.assertTrue(np.all(targets >= -1e-6))
            self.assertTrue(np.all(targets <= 1.0 + 1e-6))


class TestReplayBuffer(unittest.TestCase):
    def test_push_and_sample(self):
        buf = ReplayBuffer(capacity=10, state_dim=4)
        self.assertEqual(len(buf), 0)
        buf.push(np.array([1.0, 2.0, 3.0, 4.0], dtype=np.float32), 0.7)
        self.assertEqual(len(buf), 1)
        states, targets = buf.sample(8)
        self.assertEqual(states.shape, (1, 4))
        self.assertEqual(targets.shape, (1,))
        np.testing.assert_allclose(states[0], [1.0, 2.0, 3.0, 4.0])
        self.assertAlmostEqual(float(targets[0]), 0.7, places=5)

    def test_ring_buffer_wraps(self):
        buf = ReplayBuffer(capacity=3, state_dim=2)
        for i in range(5):
            buf.push(np.array([i, i], dtype=np.float32), float(i))
        self.assertEqual(len(buf), 3)  # capped at capacity
        # The buffer should hold the 3 most recent samples (2, 3, 4) in some order.
        # Sample everything and check.
        states, targets = buf.sample(100)
        all_targets = set(float(t) for t in targets)
        # With random sampling we might not see all 3, but each must be from {2,3,4}.
        for t in all_targets:
            self.assertIn(t, {2.0, 3.0, 4.0})

    def test_empty_buffer_sample(self):
        buf = ReplayBuffer(capacity=10, state_dim=4)
        states, targets = buf.sample(8)
        self.assertIsNone(states)
        self.assertIsNone(targets)


if __name__ == "__main__":
    unittest.main()
