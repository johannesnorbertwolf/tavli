import torch
import torch.nn.functional as F
from ai.agent import Agent, RandomAgent
from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder
from ai.checkpoint_io import (
    save_checkpoint,
    ENCODER_VERSION_LEGACY,
    HIDDEN_SIZES_LEGACY,
    _migrate_state_dict,
    load_state_dict,
)
from domain.color import Color
from game.game import Game
from tqdm import tqdm
from domain.possible_moves import PossibleMoves
import numpy as np
import random
import time
import json
import os


class ReplayBuffer:
    """Ring buffer of (encoded_state, target) pairs, sampled with priority^alpha.

    Sampling probability is `priority^alpha / Σ(priority^alpha)`. alpha=0 collapses
    to uniform sampling; alpha=1 is pure proportional. Each sample() also returns
    importance-sampling weights `w_i = (size · p_i)^(-beta)`, normalized by max(w),
    to correct the gradient bias introduced by non-uniform sampling.

    New entries get the current max priority so they are seen at least once before
    their priority is refreshed. Call update_priorities() after each minibatch step
    with the fresh |TD error| values for the sampled indices.
    """

    _MIN_PRIORITY = 1e-6

    def __init__(self, capacity: int, state_dim: int, alpha: float = 0.6):
        self.capacity = int(capacity)
        self.state_dim = int(state_dim)
        self.alpha = float(alpha)
        self.states = np.zeros((self.capacity, self.state_dim), dtype=np.float32)
        self.targets = np.zeros(self.capacity, dtype=np.float32)
        self.priorities = np.zeros(self.capacity, dtype=np.float64)
        self.size = 0
        self.cursor = 0
        self._max_priority = 1.0

    def __len__(self):
        return self.size

    def push(self, state: np.ndarray, target: float, priority=None):
        p = max(abs(float(priority)), self._MIN_PRIORITY) if priority is not None else self._max_priority
        self._max_priority = max(self._max_priority, p)
        self.states[self.cursor] = state
        self.targets[self.cursor] = target
        self.priorities[self.cursor] = p
        self.cursor = (self.cursor + 1) % self.capacity
        self.size = min(self.size + 1, self.capacity)

    def push_many(self, states: np.ndarray, targets: np.ndarray, priorities=None):
        n = states.shape[0]
        for i in range(n):
            p = float(priorities[i]) if priorities is not None else None
            self.push(states[i], float(targets[i]), p)

    def sample(self, batch_size: int, beta: float = 1.0):
        if self.size == 0:
            return None, None, None, None
        k = min(batch_size, self.size)
        raw = self.priorities[:self.size]
        scaled = raw ** self.alpha
        probs = scaled / scaled.sum()
        idx = np.random.choice(self.size, size=k, replace=False, p=probs)

        # IS weights: w_i = (N · p_i)^(-beta), normalized so max(w) == 1
        weights = (self.size * probs[idx]) ** (-float(beta))
        weights = weights / weights.max()
        return self.states[idx], self.targets[idx], idx, weights.astype(np.float32)

    def update_priorities(self, indices: np.ndarray, td_errors: np.ndarray):
        new_p = np.maximum(np.abs(np.asarray(td_errors, dtype=np.float64)), self._MIN_PRIORITY)
        self.priorities[indices] = new_p
        if new_p.size > 0:
            self._max_priority = max(self._max_priority, float(new_p.max()))


def compute_lambda_returns(values: np.ndarray, movers: np.ndarray,
                            terminal_winner_white: bool, lambda_: float) -> np.ndarray:
    """Compute λ-returns for each non-terminal state in a trajectory.

    Args:
        values: shape (T+1,), bootstrap V[s_i] from network at trajectory ingest.
        movers: shape (T,), bool — True if White is the mover at state i.
        terminal_winner_white: who won the game.
        lambda_: TD(λ) trace decay.

    Returns:
        targets: shape (T+1,), one target per state.
            - For i in [0, T): λ-return from mover_i's perspective.
            - For i == T (post-terminal state): target = 0
              (mover_T is the loser; their win prob is 0).
    """
    T = len(movers)
    targets = np.zeros(T + 1, dtype=np.float32)

    # Post-terminal state: encoded from the loser's perspective. Target = 0.
    targets[T] = 0.0

    if T == 0:
        return targets

    lam = float(lambda_)
    for i in range(T):
        mover_i_white = bool(movers[i])
        N = T - i  # steps until (and including) terminal
        # Build n-step returns G^{(n)}_i for n = 1..N
        # G^{(n)}_i = U(s_{i+n}, mover_i) for i+n < T (bootstrap),
        # or U_terminal(mover_i) for i+n == T.
        # All from mover_i's perspective: U(j, mover_i) = V[j] if mover_j == mover_i else 1 - V[j].
        # U_terminal: 1 if mover_i won, else 0.
        terminal_value = 1.0 if (mover_i_white == bool(terminal_winner_white)) else 0.0

        # Vectorized λ-return: G^λ_i = (1-λ) Σ_{n=1..N-1} λ^{n-1} G^{(n)}_i + λ^{N-1} G^{(N)}_i
        # Compute G^{(n)}_i for n=1..N as a vector.
        bootstrap_g = np.empty(N, dtype=np.float32)
        for n in range(1, N + 1):
            j = i + n
            if j == T:
                bootstrap_g[n - 1] = terminal_value
            else:
                v = float(values[j])
                mover_j_white = bool(movers[j])
                bootstrap_g[n - 1] = v if (mover_j_white == mover_i_white) else (1.0 - v)

        if N == 1:
            targets[i] = bootstrap_g[0]
        else:
            # weights: (1-λ) * λ^{n-1} for n=1..N-1, plus λ^{N-1} for n=N
            n_range = np.arange(N, dtype=np.float64)
            lam_pow = lam ** n_range  # λ^0, λ^1, ..., λ^{N-1}
            weights = (1.0 - lam) * lam_pow
            weights[-1] = lam ** (N - 1)
            targets[i] = float(np.dot(weights, bootstrap_g.astype(np.float64)))

    return targets


class TdLambdaTraining:
    def __init__(self, board_evaluator: BoardEvaluator, board_encoder: BoardEncoder, config):
        self.board_evaluator = board_evaluator
        self.board_encoder = board_encoder
        self.config = config
        self.agent = Agent(self.board_evaluator, self.board_encoder)

        # TD(Lambda) parameters
        self.lambda_start = self.config.get_lambda_start()
        self.lambda_end = self.config.get_lambda_end()
        self.lambda_ = self.lambda_start
        self.gamma = self.config.get_discount_factor()
        self.epsilon_start = self.config.get_epsilon_start()
        self.epsilon = self.epsilon_start
        self.epsilon_end = self.config.get_epsilon_end()
        self.epsilon_decay = self.config.get_epsilon_decay()
        self.epsilon_decay_games = self.config.get_epsilon_decay_games()
        self.exploration_temperature = self.config.get_exploration_temperature()
        self.lambda_decay_games = max(0, int(self.config.get_lambda_decay_games()))
        self.training_state_path = self.config.get_training_state_path()
        self.state_save_every_games = max(0, int(self.config.get_state_save_every_games()))
        self.global_game_num = 0
        self.max_grad_norm = self.config.get_max_grad_norm()
        self.model_save_every_epochs = max(0, int(self.config.get_model_save_every_epochs()))

        # Optimizer + replay knobs
        self.learning_rate = float(self.config.get_learning_rate())
        self.lr_warmup_steps = max(0, int(self.config.get_lr_warmup_steps()))
        self.replay_capacity = max(1, int(self.config.get_replay_buffer_capacity()))
        self.minibatch_size = max(1, int(self.config.get_minibatch_size()))
        self.updates_per_game = max(0, int(self.config.get_updates_per_game()))
        self.min_buffer_to_train = max(0, int(self.config.get_min_buffer_to_train()))

        # Prioritized replay knobs
        self.priority_alpha = max(0.0, float(self.config.get_priority_alpha()))
        self.priority_beta_start = float(self.config.get_priority_beta_start())
        self.priority_beta_end = float(self.config.get_priority_beta_end())
        self.priority_beta_anneal_steps = max(0, int(self.config.get_priority_beta_anneal_steps()))

        self.eval_every_epochs = max(1, int(self.config.get_eval_every_epochs()))
        self.eval_games_per_color = max(1, int(self.config.get_eval_games_per_color()))
        self.eval_seed = self.config.get_eval_seed()
        self.eval_against_random = bool(self.config.get_eval_against_random())
        self.eval_against_gold = bool(self.config.get_eval_against_gold())
        self.eval_candidate_lookahead_plies = max(1, int(self.config.get_eval_candidate_lookahead_plies()))
        self.eval_gold_lookahead_plies = max(1, int(self.config.get_eval_gold_lookahead_plies()))
        self.num_self_play_workers = max(1, int(self.config.get_num_self_play_workers()))
        self.gold_model_path = self.config.get_gold_model_path()
        self.gold_eval_log_path = os.path.join("training_runs", "eval_gold_history.log")
        self.random_agent = RandomAgent()
        self.device = next(self.board_evaluator.parameters()).device
        self.gold_agent = None

        self.model_save_path = "trained_model.pth"

        # Replay buffer + Adam optimizer
        self.replay = ReplayBuffer(self.replay_capacity, self.board_encoder.input_size, alpha=self.priority_alpha)
        self.optimizer = torch.optim.Adam(self.board_evaluator.parameters(), lr=self.learning_rate)
        self.optimizer_steps = 0

        self._try_load_gold_agent()
        self._try_load_optimizer_state()
        self._load_training_state()
        self._update_lambda()

    def _append_gold_eval_log(self, epoch_num: int, games_per_color: int, white_rate, black_rate, avg_rate, status="ok"):
        log_dir = os.path.dirname(self.gold_eval_log_path)
        if log_dir:
            os.makedirs(log_dir, exist_ok=True)
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        if status != "ok":
            line = (
                f"{timestamp} epoch={epoch_num} games_per_color={games_per_color} "
                f"status={status} gold_model_path={self.gold_model_path}\n"
            )
        else:
            line = (
                f"{timestamp} epoch={epoch_num} games_per_color={games_per_color} "
                f"white={white_rate:.4f} black={black_rate:.4f} avg={avg_rate:.4f}\n"
            )
        with open(self.gold_eval_log_path, "a") as fh:
            fh.write(line)

    def _get_eval_seed(self):
        if self.eval_seed is not None:
            return int(self.eval_seed)
        return random.SystemRandom().randrange(0, 2**32)

    def _to_model_tensor(self, encoded_board: np.ndarray) -> torch.Tensor:
        return torch.from_numpy(encoded_board).float().unsqueeze(0).to(self.device)

    def _select_move_self_play(self, board, possible_moves, current_player):
        if len(possible_moves) == 1:
            return possible_moves[0], None

        move_scores = self.agent.evaluate_moves(board, possible_moves, current_player)
        best_idx = int(np.argmax(move_scores))

        if np.random.random() >= self.epsilon:
            return possible_moves[best_idx], move_scores[best_idx]

        scores = np.array(move_scores, dtype=np.float64) / self.exploration_temperature
        scores -= np.max(scores)
        exp_scores = np.exp(scores)
        probs = exp_scores / np.sum(exp_scores)
        choice_idx = int(np.random.choice(len(possible_moves), p=probs))
        return possible_moves[choice_idx], move_scores[choice_idx]

    def _update_schedules(self, game_num):
        if self.epsilon_decay_games and self.epsilon_decay_games > 0:
            progress = min(game_num + 1, self.epsilon_decay_games) / self.epsilon_decay_games
            self.epsilon = self.epsilon_start + (self.epsilon_end - self.epsilon_start) * progress
        else:
            self.epsilon = max(self.epsilon_end, self.epsilon * self.epsilon_decay)

    def _update_lambda(self):
        if self.lambda_decay_games <= 0:
            self.lambda_ = self.lambda_start
            return
        progress = min(self.global_game_num, self.lambda_decay_games) / self.lambda_decay_games
        self.lambda_ = self.lambda_end + (self.lambda_start - self.lambda_end) * np.exp(-1.0 * progress * 10.0)

    def _current_priority_beta(self) -> float:
        if self.priority_beta_anneal_steps <= 0:
            return self.priority_beta_end
        frac = min(1.0, self.optimizer_steps / float(self.priority_beta_anneal_steps))
        return self.priority_beta_start + (self.priority_beta_end - self.priority_beta_start) * frac

    def _current_lr(self) -> float:
        if self.lr_warmup_steps <= 0:
            return self.learning_rate
        step = self.optimizer_steps
        if step >= self.lr_warmup_steps:
            return self.learning_rate
        # Linear warmup from 0.1·lr → lr
        frac = step / float(self.lr_warmup_steps)
        return self.learning_rate * (0.1 + 0.9 * frac)

    def _set_lr(self, lr: float):
        for pg in self.optimizer.param_groups:
            pg["lr"] = lr

    def _save_training_state(self):
        state = {
            "global_game_num": int(self.global_game_num),
            "lambda": float(self.lambda_),
            "epsilon": float(self.epsilon),
            "optimizer_steps": int(self.optimizer_steps),
        }
        tmp_path = f"{self.training_state_path}.tmp"
        with open(tmp_path, "w") as fh:
            json.dump(state, fh)
        os.replace(tmp_path, self.training_state_path)

    def _load_training_state(self):
        if not self.training_state_path or not os.path.exists(self.training_state_path):
            return
        try:
            with open(self.training_state_path, "r") as fh:
                state = json.load(fh)
            self.global_game_num = int(state.get("global_game_num", 0))
            self.lambda_ = float(state.get("lambda", self.lambda_))
            self.epsilon = float(state.get("epsilon", self.epsilon))
            self.optimizer_steps = int(state.get("optimizer_steps", 0))
            print(
                f"Loaded training state from {self.training_state_path}: "
                f"games={self.global_game_num}, lambda={self.lambda_:.4f}, "
                f"epsilon={self.epsilon:.4f}, optimizer_steps={self.optimizer_steps}"
            )
        except Exception as exc:
            print(f"Could not load training state from {self.training_state_path}: {exc}. Starting fresh.")

    def _try_load_optimizer_state(self):
        if not os.path.exists(self.model_save_path):
            return
        try:
            _, meta = load_state_dict(self.model_save_path, device=self.device)
            opt_state = meta.get("optimizer_state_dict")
            if opt_state is not None:
                self.optimizer.load_state_dict(opt_state)
                print(f"Loaded Adam optimizer state from {self.model_save_path}")
            else:
                print(f"Checkpoint at {self.model_save_path} has no optimizer state; starting Adam fresh")
        except Exception as exc:
            print(f"Could not load optimizer state from {self.model_save_path}: {exc}. Starting Adam fresh.")

    def _evaluate_against_random(self, games_per_color: int):
        def play_game(ai_color: Color):
            game = Game(self.config, starting_player=Color.WHITE)
            while not game.is_over():
                current_player = game.current_player
                game.dice.roll()
                possible_moves = PossibleMoves(game.board, current_player, game.dice).find_moves()
                if not possible_moves:
                    game.switch_turn()
                    continue

                if current_player == ai_color:
                    move, _ = self.agent.get_best_move(
                        game.board, possible_moves, current_player,
                        lookahead_plies=self.eval_candidate_lookahead_plies,
                    )
                else:
                    move = self.random_agent.get_move(possible_moves)

                game.board.apply(move)
                game.switch_turn()
            return game.get_winner()

        self.board_evaluator.eval()
        eval_seed = self._get_eval_seed()
        py_state = random.getstate()
        np_state = np.random.get_state()
        try:
            random.seed(eval_seed)
            np.random.seed(eval_seed)
            white_wins = 0
            for _ in range(games_per_color):
                if play_game(Color.WHITE) == Color.WHITE:
                    white_wins += 1
            random.seed(eval_seed)
            np.random.seed(eval_seed)
            black_wins = 0
            for _ in range(games_per_color):
                if play_game(Color.BLACK) == Color.BLACK:
                    black_wins += 1
        finally:
            random.setstate(py_state)
            np.random.set_state(np_state)
            self.board_evaluator.train()

        white_rate = white_wins / games_per_color
        black_rate = black_wins / games_per_color
        avg_rate = (white_rate + black_rate) / 2.0
        return white_rate, black_rate, avg_rate

    def _try_load_gold_agent(self):
        if not self.eval_against_gold:
            return
        if not self.gold_model_path or not os.path.exists(self.gold_model_path):
            print(f"Gold model not found at {self.gold_model_path}; skipping gold eval.")
            return
        try:
            payload = torch.load(self.gold_model_path, map_location=self.device, weights_only=True)
            if isinstance(payload, dict) and "state_dict" in payload:
                state_dict = payload["state_dict"]
                encoder_version = payload.get("encoder_version", ENCODER_VERSION_LEGACY)
                hidden_sizes = payload.get("hidden_sizes", HIDDEN_SIZES_LEGACY)
            else:
                state_dict = payload
                encoder_version = ENCODER_VERSION_LEGACY
                hidden_sizes = HIDDEN_SIZES_LEGACY
            gold_encoder = BoardEncoder(self.config, version=encoder_version)
            gold_evaluator = BoardEvaluator(gold_encoder.input_size, hidden_sizes=hidden_sizes).to(self.device)
            gold_evaluator.load_state_dict(_migrate_state_dict(state_dict))
            gold_evaluator.eval()
            self.gold_agent = Agent(gold_evaluator, gold_encoder)
            print(f"Loaded gold model from {self.gold_model_path}")
        except Exception as exc:
            print(f"Could not load gold model from {self.gold_model_path}: {exc}. Skipping gold eval.")
            self.gold_agent = None

    def _evaluate_against_gold(self, games_per_color: int):
        if self.gold_agent is None:
            return None

        def play_game(candidate_color: Color):
            game = Game(self.config, starting_player=Color.WHITE)
            while not game.is_over():
                current_player = game.current_player
                game.dice.roll()
                possible_moves = PossibleMoves(game.board, current_player, game.dice).find_moves()
                if not possible_moves:
                    game.switch_turn()
                    continue

                if current_player == candidate_color:
                    move, _ = self.agent.get_best_move(
                        game.board, possible_moves, current_player,
                        lookahead_plies=self.eval_candidate_lookahead_plies,
                    )
                else:
                    move, _ = self.gold_agent.get_best_move(
                        game.board, possible_moves, current_player,
                        lookahead_plies=self.eval_gold_lookahead_plies,
                    )

                game.board.apply(move)
                game.switch_turn()
            return game.get_winner()

        self.board_evaluator.eval()
        self.gold_agent.board_evaluator.eval()
        eval_seed = self._get_eval_seed()
        py_state = random.getstate()
        np_state = np.random.get_state()
        try:
            random.seed(eval_seed)
            np.random.seed(eval_seed)
            white_wins = 0
            for _ in range(games_per_color):
                if play_game(Color.WHITE) == Color.WHITE:
                    white_wins += 1
            random.seed(eval_seed)
            np.random.seed(eval_seed)
            black_wins = 0
            for _ in range(games_per_color):
                if play_game(Color.BLACK) == Color.BLACK:
                    black_wins += 1
        finally:
            random.setstate(py_state)
            np.random.set_state(np_state)
            self.board_evaluator.train()
            self.gold_agent.board_evaluator.eval()

        white_rate = white_wins / games_per_color
        black_rate = black_wins / games_per_color
        avg_rate = (white_rate + black_rate) / 2.0
        return white_rate, black_rate, avg_rate

    def _ingest_trajectory(self, traj):
        """Compute λ-returns from a worker (or local) trajectory and push to replay buffer.

        Returns stats dict: plies, td_abs_sum, td_count, game_seconds.
        td_abs_sum/td_count measure |target - V(s)| on the freshly-computed targets
        (analogous to mean |TD error| in the old code), useful for tracking learning progress.
        """
        states = traj["states"]
        movers = traj["movers"]
        terminal_winner_white = bool(traj["terminal_winner_white"])
        plies = traj["plies"]
        T = len(movers)

        if T == 0:
            return {"plies": 0, "td_abs_sum": 0.0, "td_count": 0, "game_seconds": traj.get("game_seconds", 0.0)}

        # Forward-pass all states once to get bootstrap V values.
        states_np = np.stack(states)  # shape (T+1, state_dim)
        self.board_evaluator.eval()
        with torch.no_grad():
            values = self.board_evaluator(torch.from_numpy(states_np).float().to(self.device)).squeeze(-1).cpu().numpy()
        self.board_evaluator.train()

        movers_arr = np.array(movers, dtype=bool)
        targets = compute_lambda_returns(values, movers_arr, terminal_winner_white, self.lambda_)

        # Push all T+1 (state, target) pairs; priority = |TD error| at ingest time.
        td_errors = np.abs(targets - values)
        self.replay.push_many(states_np, targets, td_errors)

        td_abs_sum = float(np.sum(td_errors))
        td_count = T + 1

        return {
            "plies": plies,
            "td_abs_sum": td_abs_sum,
            "td_count": td_count,
            "game_seconds": traj.get("game_seconds", 0.0),
        }

    def _train_minibatches(self):
        """Run self.updates_per_game Adam SGD steps from the replay buffer."""
        if self.updates_per_game <= 0:
            return
        if len(self.replay) < max(1, self.min_buffer_to_train):
            return
        for _ in range(self.updates_per_game):
            beta = self._current_priority_beta()
            states_np, targets_np, indices, weights_np = self.replay.sample(self.minibatch_size, beta=beta)
            if states_np is None:
                return
            states_t = torch.from_numpy(states_np).float().to(self.device)
            targets_t = torch.from_numpy(targets_np).float().to(self.device)
            weights_t = torch.from_numpy(weights_np).float().to(self.device)

            self._set_lr(self._current_lr())
            self.optimizer.zero_grad()
            logits = self.board_evaluator.forward_logits(states_t).squeeze(-1)
            per_sample = F.binary_cross_entropy_with_logits(logits, targets_t, reduction="none")
            loss = (weights_t * per_sample).mean()
            # Capture pre-step predictions for priority refresh (saves a second forward pass).
            pre_preds = torch.sigmoid(logits).detach().cpu().numpy()
            loss.backward()
            if self.max_grad_norm > 0:
                torch.nn.utils.clip_grad_norm_(self.board_evaluator.parameters(), self.max_grad_norm)
            self.optimizer.step()
            self.optimizer_steps += 1

            fresh_td_errors = np.abs(targets_np - pre_preds)
            self.replay.update_priorities(indices, fresh_td_errors)

    def _apply_trajectory(self, traj):
        """Ingest a trajectory and run a round of minibatch SGD updates."""
        stats = self._ingest_trajectory(traj)
        self._train_minibatches()
        return stats

    def _get_worker_fn(self):
        from ai.self_play_worker import worker_main
        return worker_main

    def _send_weights_to_worker(self, weight_q):
        weights = {k: v.detach().cpu().numpy().copy() for k, v in self.board_evaluator.state_dict().items()}
        weight_q.put((weights, float(self.epsilon), float(self.exploration_temperature)))

    def _play_one_game_local(self, verbose_log_file=None):
        """Self-play one full game in-process, collecting a trajectory dict matching the
        worker's output format. No mid-game weight updates."""
        game = Game(self.config)
        log_fh = None
        if verbose_log_file:
            log_fh = open(verbose_log_file, 'w')
        game_start_time = time.perf_counter()

        states = [self.board_encoder.encode_board(game.board, game.current_player == Color.WHITE)]
        movers = []

        self.board_evaluator.eval()
        try:
            while True:
                current_player = game.current_player
                is_white_to_move = current_player == Color.WHITE

                dice = game.dice.roll()
                possible_moves = PossibleMoves(game.board, current_player, game.dice).find_moves()

                move, score = None, None
                if not possible_moves:
                    game.switch_turn()
                    move = "pass"
                else:
                    move, score = self._select_move_self_play(game.board, possible_moves, current_player)
                    game.board.apply(move)
                    game.switch_turn()

                movers.append(is_white_to_move)
                states.append(self.board_encoder.encode_board(game.board, game.current_player == Color.WHITE))

                if log_fh:
                    log_fh.write(f"Player: {current_player}\n")
                    log_fh.write(f"Dice: {dice}\n")
                    log_fh.write(f"Board:\n{game.board}\n")
                    log_fh.write(f"Move chosen: {move}\n")
                    if score is not None:
                        log_fh.write(f"Board score: {score}\n")
                    log_fh.write(f"Lambda value: {self.lambda_}.\n")
                    log_fh.write(f"Epsilon value: {self.epsilon}.\n")
                    log_fh.write("-" * 20 + "\n")

                if game.is_over():
                    if log_fh:
                        log_fh.write(f"Game over. Winner is {game.get_winner()}.\n")
                    return {
                        "states": states,
                        "movers": movers,
                        "terminal_winner_white": (game.get_winner() == Color.WHITE),
                        "plies": len(movers),
                        "game_seconds": time.perf_counter() - game_start_time,
                    }
        finally:
            self.board_evaluator.train()
            if log_fh:
                log_fh.close()

    def train_one_game(self, verbose_log_file=None):
        """Self-play one full game to a real terminal, then apply replay+Adam updates."""
        traj = self._play_one_game_local(verbose_log_file=verbose_log_file)
        return self._apply_trajectory(traj)

    def run_training_loop(self):
        if self.num_self_play_workers > 1:
            return self._run_training_loop_parallel()
        self.board_evaluator.train()
        num_epochs = self.config.get_num_epochs()
        games_per_epoch = self.config.get_games_per_epoch()
        run_total_games = num_epochs * games_per_epoch

        overall_start = time.perf_counter()
        total_game_seconds = 0.0
        total_plies = 0
        total_td_abs_sum = 0.0
        total_td_count = 0

        for epoch in range(num_epochs):
            print(f"Epoch {epoch + 1}/{num_epochs}")
            epoch_start = time.perf_counter()
            epoch_plies = 0
            epoch_td_abs_sum = 0.0
            epoch_td_count = 0
            for i in tqdm(range(games_per_epoch), desc=f"Training epoch {epoch+1}"):
                is_last_game = (epoch == num_epochs - 1) and (i == games_per_epoch - 1)
                log_file = "last_game_log.txt" if is_last_game else None

                stats = self.train_one_game(verbose_log_file=log_file)
                total_game_seconds += stats["game_seconds"]
                total_plies += stats["plies"]
                epoch_plies += stats["plies"]
                total_td_abs_sum += stats["td_abs_sum"]
                total_td_count += stats["td_count"]
                epoch_td_abs_sum += stats["td_abs_sum"]
                epoch_td_count += stats["td_count"]
                self.global_game_num += 1
                self._update_lambda()
                self._update_schedules(self.global_game_num - 1)
                if self.state_save_every_games > 0 and self.global_game_num % self.state_save_every_games == 0:
                    self._save_training_state()

            epoch_seconds = time.perf_counter() - epoch_start
            epoch_games_per_second = games_per_epoch / epoch_seconds if epoch_seconds > 0 else 0.0
            epoch_plies_per_second = epoch_plies / epoch_seconds if epoch_seconds > 0 else 0.0
            epoch_td_mae = (epoch_td_abs_sum / epoch_td_count) if epoch_td_count > 0 else 0.0
            print(
                f"Epoch {epoch + 1} timing: {epoch_seconds:.2f}s total, "
                f"{epoch_games_per_second:.2f} games/s, {epoch_plies_per_second:.2f} plies/s"
            )
            print(f"Epoch {epoch + 1} mean |TD error|: {epoch_td_mae:.6f}  (buffer={len(self.replay)}, opt_steps={self.optimizer_steps})")
            self._save_training_state()

            if self.model_save_every_epochs > 0 and (epoch + 1) % self.model_save_every_epochs == 0:
                save_checkpoint(self.model_save_path, self.board_evaluator, self.config, optimizer=self.optimizer)
                print(f"Model checkpoint saved at epoch {epoch + 1}")

            if (epoch + 1) % self.eval_every_epochs == 0:
                self._run_eval(epoch + 1)

        total_seconds = time.perf_counter() - overall_start
        total_games_per_second = run_total_games / total_seconds if total_seconds > 0 else 0.0
        total_plies_per_second = total_plies / total_seconds if total_seconds > 0 else 0.0
        avg_seconds_per_game = total_game_seconds / run_total_games if run_total_games > 0 else 0.0
        total_td_mae = (total_td_abs_sum / total_td_count) if total_td_count > 0 else 0.0
        print(
            f"Training timing summary: {total_seconds:.2f}s total, "
            f"{avg_seconds_per_game:.3f}s/game, {total_games_per_second:.2f} games/s, "
            f"{total_plies_per_second:.2f} plies/s"
        )
        print(f"Training mean |TD error|: {total_td_mae:.6f}")

        save_checkpoint(self.model_save_path, self.board_evaluator, self.config, optimizer=self.optimizer)
        self._save_training_state()
        print(f"Model saved to {self.model_save_path}")

    def _run_eval(self, epoch_num: int):
        if self.eval_against_random:
            white_rate, black_rate, avg_rate = self._evaluate_against_random(self.eval_games_per_color)
            print(
                f"Eval vs random @ epoch {epoch_num}: "
                f"white {white_rate*100:.1f}%, black {black_rate*100:.1f}%, avg {avg_rate*100:.1f}% "
                f"({self.eval_games_per_color} games/color)"
            )
        if self.eval_against_gold:
            gold_eval = self._evaluate_against_gold(self.eval_games_per_color)
            if gold_eval is None:
                print(
                    f"Eval vs gold @ epoch {epoch_num}: skipped "
                    f"(missing or unloadable gold model: {self.gold_model_path})"
                )
                self._append_gold_eval_log(
                    epoch_num=epoch_num,
                    games_per_color=self.eval_games_per_color,
                    white_rate=0.0, black_rate=0.0, avg_rate=0.0,
                    status="skipped",
                )
            else:
                white_rate, black_rate, avg_rate = gold_eval
                print(
                    f"Eval vs gold @ epoch {epoch_num}: "
                    f"white {white_rate*100:.1f}%, black {black_rate*100:.1f}%, avg {avg_rate*100:.1f}% "
                    f"({self.eval_games_per_color} games/color)"
                )
                self._append_gold_eval_log(
                    epoch_num=epoch_num,
                    games_per_color=self.eval_games_per_color,
                    white_rate=white_rate, black_rate=black_rate, avg_rate=avg_rate,
                )

    def _run_training_loop_parallel(self):
        import multiprocessing as mp

        ctx = mp.get_context("spawn")
        num_workers = self.num_self_play_workers
        weight_qs = [ctx.Queue(maxsize=2) for _ in range(num_workers)]
        traj_q = ctx.Queue()

        config_path = self.config.config_file
        base_seed = random.SystemRandom().randrange(0, 2**32)
        hidden_sizes = list(self.board_evaluator.hidden_sizes)
        worker_fn = self._get_worker_fn()

        workers = []
        for wid in range(num_workers):
            p = ctx.Process(
                target=worker_fn,
                args=(wid, weight_qs[wid], traj_q, config_path, hidden_sizes, base_seed),
                daemon=True,
            )
            p.start()
            workers.append(p)

        def send_weights(wid):
            self._send_weights_to_worker(weight_qs[wid])

        try:
            for wid in range(num_workers):
                send_weights(wid)

            self.board_evaluator.train()
            num_epochs = self.config.get_num_epochs()
            games_per_epoch = self.config.get_games_per_epoch()
            run_total_games = num_epochs * games_per_epoch

            print(f"Parallel self-play: {num_workers} workers")
            overall_start = time.perf_counter()
            total_game_seconds = 0.0
            total_plies = 0
            total_td_abs_sum = 0.0
            total_td_count = 0

            for epoch in range(num_epochs):
                print(f"Epoch {epoch + 1}/{num_epochs}")
                epoch_start = time.perf_counter()
                epoch_plies = 0
                epoch_td_abs_sum = 0.0
                epoch_td_count = 0

                for _ in tqdm(range(games_per_epoch), desc=f"Training epoch {epoch+1}"):
                    wid, traj = traj_q.get()
                    stats = self._apply_trajectory(traj)
                    total_game_seconds += stats["game_seconds"]
                    total_plies += stats["plies"]
                    epoch_plies += stats["plies"]
                    total_td_abs_sum += stats["td_abs_sum"]
                    total_td_count += stats["td_count"]
                    epoch_td_abs_sum += stats["td_abs_sum"]
                    epoch_td_count += stats["td_count"]
                    self.global_game_num += 1
                    self._update_lambda()
                    self._update_schedules(self.global_game_num - 1)
                    if self.state_save_every_games > 0 and self.global_game_num % self.state_save_every_games == 0:
                        self._save_training_state()
                    send_weights(wid)

                epoch_seconds = time.perf_counter() - epoch_start
                epoch_games_per_second = games_per_epoch / epoch_seconds if epoch_seconds > 0 else 0.0
                epoch_plies_per_second = epoch_plies / epoch_seconds if epoch_seconds > 0 else 0.0
                epoch_td_mae = (epoch_td_abs_sum / epoch_td_count) if epoch_td_count > 0 else 0.0
                print(
                    f"Epoch {epoch + 1} timing: {epoch_seconds:.2f}s total, "
                    f"{epoch_games_per_second:.2f} games/s, {epoch_plies_per_second:.2f} plies/s"
                )
                print(f"Epoch {epoch + 1} mean |TD error|: {epoch_td_mae:.6f}  (buffer={len(self.replay)}, opt_steps={self.optimizer_steps})")
                self._save_training_state()

                if self.model_save_every_epochs > 0 and (epoch + 1) % self.model_save_every_epochs == 0:
                    save_checkpoint(self.model_save_path, self.board_evaluator, self.config, optimizer=self.optimizer)
                    print(f"Model checkpoint saved at epoch {epoch + 1}")

                if (epoch + 1) % self.eval_every_epochs == 0:
                    self._run_eval(epoch + 1)

            total_seconds = time.perf_counter() - overall_start
            total_games_per_second = run_total_games / total_seconds if total_seconds > 0 else 0.0
            total_plies_per_second = total_plies / total_seconds if total_seconds > 0 else 0.0
            avg_seconds_per_game = total_game_seconds / run_total_games if run_total_games > 0 else 0.0
            total_td_mae = (total_td_abs_sum / total_td_count) if total_td_count > 0 else 0.0
            print(
                f"Training timing summary: {total_seconds:.2f}s total, "
                f"{avg_seconds_per_game:.3f}s/game (worker), {total_games_per_second:.2f} games/s (wall), "
                f"{total_plies_per_second:.2f} plies/s"
            )
            print(f"Training mean |TD error|: {total_td_mae:.6f}")

            save_checkpoint(self.model_save_path, self.board_evaluator, self.config, optimizer=self.optimizer)
            self._save_training_state()
            print(f"Model saved to {self.model_save_path}")
        finally:
            for q in weight_qs:
                try: q.put_nowait(None)
                except Exception: pass
            for p in workers:
                p.join(timeout=3)
                if p.is_alive():
                    p.terminate()
