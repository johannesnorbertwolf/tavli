import torch
import torch.nn.functional as F
from ai.agent import Agent, RandomAgent
from ai.bearoff import BearoffDB, exact_value_on_roll
from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder
from ai.checkpoint_io import (
    save_checkpoint,
    ENCODER_VERSION_LEGACY,
    HIDDEN_SIZES_LEGACY,
    _migrate_state_dict,
    load_state_dict,
)
from domain.constants import WHITE, BLACK
from domain.move_generation import legal_moves
from game.game import Game
from tqdm import tqdm
import numpy as np
import random
import time
import json
import os


class ReplayBuffer:
    """Ring buffer of (encoded_state, target) pairs. Pure numpy, uniform sampling."""

    def __init__(self, capacity: int, state_dim: int, aux_dim: int = 0):
        self.capacity = int(capacity)
        self.state_dim = int(state_dim)
        self.aux_dim = int(aux_dim)
        self.states = np.zeros((self.capacity, self.state_dim), dtype=np.float32)
        self.targets = np.zeros(self.capacity, dtype=np.float32)
        self.aux = np.zeros((self.capacity, self.aux_dim), dtype=np.float32) if self.aux_dim > 0 else None
        self.size = 0
        self.cursor = 0

    def __len__(self):
        return self.size

    def push(self, state: np.ndarray, target: float, aux: np.ndarray = None):
        self.states[self.cursor] = state
        self.targets[self.cursor] = target
        if self.aux is not None and aux is not None:
            self.aux[self.cursor] = aux
        self.cursor = (self.cursor + 1) % self.capacity
        self.size = min(self.size + 1, self.capacity)

    def push_many(self, states: np.ndarray, targets: np.ndarray, aux: np.ndarray = None):
        n = states.shape[0]
        for i in range(n):
            self.push(states[i], float(targets[i]), None if aux is None else aux[i])

    def sample(self, batch_size: int):
        if self.size == 0:
            return None, None
        k = min(batch_size, self.size)
        idx = np.random.randint(0, self.size, size=k)
        return self.states[idx], self.targets[idx]

    def sample_aux(self, batch_size: int):
        """Like sample(), but also returns the aux-target rows (requires aux_dim > 0)."""
        if self.size == 0:
            return None, None, None
        k = min(batch_size, self.size)
        idx = np.random.randint(0, self.size, size=k)
        return self.states[idx], self.targets[idx], self.aux[idx]


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

        # Exact bear-off DB: built eagerly here (cached on disk) so self-play
        # workers spawned later only ever load the cache.
        self.bearoff = None
        if bool(self.config.get_use_bearoff_db()):
            self.bearoff = BearoffDB.load_or_build(self.config.get_bearoff_db_path())
        self.agent = Agent(self.board_evaluator, self.board_encoder, bearoff=self.bearoff)

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
        self.selfplay_2ply_margin = self.config.get_selfplay_2ply_margin()
        self.selfplay_2ply_max_moves = self.config.get_selfplay_2ply_max_moves()
        self.selfplay_seeded_fraction = self.config.get_selfplay_seeded_fraction()
        self.seed_pool = None
        if self.selfplay_seeded_fraction > 0.0:
            pool_path = self.config.get_selfplay_seed_pool_path()
            if not os.path.exists(pool_path):
                raise FileNotFoundError(
                    f"selfplay_seeded_fraction > 0 but seed pool not found: {pool_path} "
                    f"(build it with: python main.py seed-pool)")
            from ai.seed_pool import SeedPool
            self.seed_pool = SeedPool(pool_path)
        self.selfplay_league_fraction = self.config.get_selfplay_league_fraction()
        self.league_opponents = None
        if self.selfplay_league_fraction > 0.0:
            from ai.checkpoint_io import load_agent_from_checkpoint
            paths = self.config.get_selfplay_league_opponents()
            self.league_opponents = [load_agent_from_checkpoint(p, self.config)[0] for p in paths]
            if not self.league_opponents:
                self.selfplay_league_fraction = 0.0
        self.aux_heads_n = self.config.get_aux_heads()
        self.aux_loss_weight = self.config.get_aux_loss_weight()
        if self.aux_heads_n > 0 and getattr(self.board_evaluator, "aux_heads", 0) != self.aux_heads_n:
            raise ValueError(
                f"aux_heads={self.aux_heads_n} in config but the evaluator was built with "
                f"aux_heads={getattr(self.board_evaluator, 'aux_heads', 0)}")
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

        self.model_save_path = self.config.get_model_save_path()

        # Replay buffer + Adam optimizer
        self.replay = ReplayBuffer(self.replay_capacity, self.board_encoder.input_size,
                                   aux_dim=self.aux_heads_n)
        self.optimizer = torch.optim.Adam(self.board_evaluator.parameters(), lr=self.learning_rate)
        self.optimizer_steps = 0

        # EMA / Polyak weights (E13): a shadow copy of the parameters tracked as an
        # exponential moving average, saved alongside the raw checkpoint for eval/deploy.
        # ema_decay = 0 disables it (raw weights only). Self-play workers always use the
        # raw weights, so EMA only changes what we deploy, not the data distribution.
        self.ema_decay = float(self.config.get_ema_decay())
        self.ema_params = None
        if self.ema_decay > 0.0:
            self.ema_params = {n: p.detach().clone()
                               for n, p in self.board_evaluator.named_parameters()}

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

    def _state_exact_value(self, game) -> float:
        """Exact win prob of the player to move (bear-off DB), NaN outside races."""
        v = exact_value_on_roll(game.board, game.current_player == WHITE, self.bearoff)
        return float("nan") if v is None else float(v)

    def _select_move_self_play(self, board, possible_moves, current_player):
        from ai.self_play_worker import select_self_play_move
        move = select_self_play_move(
            self.agent, board, possible_moves, current_player,
            self.epsilon, self.exploration_temperature,
            twoply_margin=self.selfplay_2ply_margin,
            twoply_max_moves=self.selfplay_2ply_max_moves,
        )
        return move, None

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
                # torch only validates group structure on load; a state saved for a
                # different architecture would otherwise crash at the first step().
                params = [p for g in self.optimizer.param_groups for p in g["params"]]
                for key, entry in opt_state.get("state", {}).items():
                    exp_avg = entry.get("exp_avg")
                    if exp_avg is not None and tuple(exp_avg.shape) != tuple(params[int(key)].shape):
                        print(f"Optimizer state in {self.model_save_path} does not match the "
                              f"current architecture; starting Adam fresh")
                        return
                self.optimizer.load_state_dict(opt_state)
                print(f"Loaded Adam optimizer state from {self.model_save_path}")
            else:
                print(f"Checkpoint at {self.model_save_path} has no optimizer state; starting Adam fresh")
        except Exception as exc:
            print(f"Could not load optimizer state from {self.model_save_path}: {exc}. Starting Adam fresh.")

    def _evaluate_against_random(self, games_per_color: int):
        def play_game(ai_color: int):
            game = Game(self.config, starting_player=WHITE)
            while not game.is_over():
                current_player = game.current_player
                game.dice.roll()
                possible_moves = legal_moves(game.board, current_player, game.dice)
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

                game.board.apply(move, current_player)
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
                if play_game(WHITE) == WHITE:
                    white_wins += 1
            random.seed(eval_seed)
            np.random.seed(eval_seed)
            black_wins = 0
            for _ in range(games_per_color):
                if play_game(BLACK) == BLACK:
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
            self.gold_agent = Agent(gold_evaluator, gold_encoder, bearoff=self.bearoff)
            print(f"Loaded gold model from {self.gold_model_path}")
        except Exception as exc:
            print(f"Could not load gold model from {self.gold_model_path}: {exc}. Skipping gold eval.")
            self.gold_agent = None

    def _evaluate_against_gold(self, games_per_color: int):
        if self.gold_agent is None:
            return None

        def play_game(candidate_color: int):
            game = Game(self.config, starting_player=WHITE)
            while not game.is_over():
                current_player = game.current_player
                game.dice.roll()
                possible_moves = legal_moves(game.board, current_player, game.dice)
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

                game.board.apply(move, current_player)
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
                if play_game(WHITE) == WHITE:
                    white_wins += 1
            random.seed(eval_seed)
            np.random.seed(eval_seed)
            black_wins = 0
            for _ in range(games_per_color):
                if play_game(BLACK) == BLACK:
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

        # Exact-race states (bear-off DB): bootstrap on truth instead of the
        # net's own estimate, and train the race states toward the exact value.
        exact_mask = None
        exact_arr = traj.get("exact_values")
        if exact_arr is not None:
            exact_arr = np.asarray(exact_arr, dtype=np.float32)
            exact_mask = ~np.isnan(exact_arr)
            if exact_mask.any():
                values = values.copy()
                values[exact_mask] = exact_arr[exact_mask]

        movers_arr = np.array(movers, dtype=bool)
        targets = compute_lambda_returns(values, movers_arr, terminal_winner_white, self.lambda_)
        if exact_mask is not None and exact_mask.any():
            targets[exact_mask] = exact_arr[exact_mask]

        # Auxiliary side targets (#106), mover's perspective per state:
        # col 0 — does this game end by pinning the start point (game-level);
        # col 1 — final borne-off margin, normalized to [0,1].
        aux_targets = None
        if self.aux_heads_n > 0 and "win_by_pin" in traj:
            persp_white = np.empty(T + 1, dtype=bool)
            persp_white[:T] = movers_arr
            persp_white[T] = not movers_arr[T - 1]
            pieces = float(self.config.get_pieces_per_player())
            bo_w = float(traj["final_borne_off_white"])
            bo_b = float(traj["final_borne_off_black"])
            margin_white = (bo_w - bo_b + pieces) / (2.0 * pieces)
            aux_targets = np.empty((T + 1, self.aux_heads_n), dtype=np.float32)
            aux_targets[:, 0] = 1.0 if traj["win_by_pin"] else 0.0
            aux_targets[:, 1] = np.where(persp_white, margin_white, 1.0 - margin_white)

        # Push all T+1 (state, target) pairs into replay buffer.
        self.replay.push_many(states_np, targets, aux_targets)

        td_abs_sum = float(np.sum(np.abs(targets - values)))
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
        use_aux = self.aux_heads_n > 0
        for _ in range(self.updates_per_game):
            if use_aux:
                states_np, targets_np, aux_np = self.replay.sample_aux(self.minibatch_size)
            else:
                states_np, targets_np = self.replay.sample(self.minibatch_size)
            if states_np is None:
                return
            states_t = torch.from_numpy(states_np).float().to(self.device)
            targets_t = torch.from_numpy(targets_np).float().to(self.device)

            self._set_lr(self._current_lr())
            self.optimizer.zero_grad()
            if use_aux:
                logits, aux_logits = self.board_evaluator.forward_aux_logits(states_t)
                loss = F.binary_cross_entropy_with_logits(logits.squeeze(-1), targets_t)
                aux_t = torch.from_numpy(aux_np).float().to(self.device)
                loss = loss + self.aux_loss_weight * F.binary_cross_entropy_with_logits(aux_logits, aux_t)
            else:
                logits = self.board_evaluator.forward_logits(states_t).squeeze(-1)
                loss = F.binary_cross_entropy_with_logits(logits, targets_t)
            loss.backward()
            if self.max_grad_norm > 0:
                torch.nn.utils.clip_grad_norm_(self.board_evaluator.parameters(), self.max_grad_norm)
            self.optimizer.step()
            self.optimizer_steps += 1
            self._update_ema()

    def _update_ema(self):
        """Blend the current parameters into the EMA shadow (no-op if EMA is off)."""
        if self.ema_params is None:
            return
        with torch.no_grad():
            for n, p in self.board_evaluator.named_parameters():
                self.ema_params[n].mul_(self.ema_decay).add_(p.detach(), alpha=1.0 - self.ema_decay)

    def _ema_save_path(self):
        root, ext = os.path.splitext(self.model_save_path)
        return root + "_ema" + ext

    def _save_ema_checkpoint(self):
        """Swap the EMA weights into the evaluator, checkpoint them, then restore raw weights."""
        backup = {n: p.detach().clone() for n, p in self.board_evaluator.named_parameters()}
        with torch.no_grad():
            for n, p in self.board_evaluator.named_parameters():
                p.copy_(self.ema_params[n])
        save_checkpoint(self._ema_save_path(), self.board_evaluator, self.config, optimizer=None)
        with torch.no_grad():
            for n, p in self.board_evaluator.named_parameters():
                p.copy_(backup[n])

    def _save_checkpoint_with_ema(self):
        """Save the raw checkpoint (with optimizer state) and, if EMA is on, the EMA shadow."""
        save_checkpoint(self.model_save_path, self.board_evaluator, self.config, optimizer=self.optimizer)
        if self.ema_params is not None:
            self._save_ema_checkpoint()

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
        if self.seed_pool is not None and random.random() < self.selfplay_seeded_fraction:
            game.board, game.player = self.seed_pool.sample(self.config)
        opponent, opponent_color = None, 0
        if self.league_opponents and random.random() < self.selfplay_league_fraction:
            opponent = self.league_opponents[random.randrange(len(self.league_opponents))]
            opponent_color = WHITE if random.random() < 0.5 else BLACK
        log_fh = None
        if verbose_log_file:
            log_fh = open(verbose_log_file, 'w')
        game_start_time = time.perf_counter()

        states = [self.board_encoder.encode_board(game.board, game.current_player == WHITE)]
        exact_values = [self._state_exact_value(game)]
        movers = []

        self.board_evaluator.eval()
        try:
            while True:
                current_player = game.current_player
                is_white_to_move = current_player == WHITE

                dice = game.dice.roll()
                possible_moves = legal_moves(game.board, current_player, game.dice)

                move, score = None, None
                if not possible_moves:
                    game.switch_turn()
                    move = "pass"
                else:
                    if opponent is not None and current_player == opponent_color:
                        move, score = opponent.get_best_move(game.board, possible_moves,
                                                             current_player, lookahead_plies=1)
                    else:
                        move, score = self._select_move_self_play(game.board, possible_moves, current_player)
                    game.board.apply(move, current_player)
                    game.switch_turn()

                movers.append(is_white_to_move)
                states.append(self.board_encoder.encode_board(game.board, game.current_player == WHITE))
                exact_values.append(self._state_exact_value(game))

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
                    winner = game.get_winner()
                    return {
                        "states": states,
                        "movers": movers,
                        "exact_values": exact_values,
                        "terminal_winner_white": (winner == WHITE),
                        "win_by_pin": bool(game.board.captured_starting(winner)),
                        "final_borne_off_white": int(game.board.borne_off[WHITE]),
                        "final_borne_off_black": int(game.board.borne_off[BLACK]),
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
                self._save_checkpoint_with_ema()
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

        self._save_checkpoint_with_ema()
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
                    self._save_checkpoint_with_ema()
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

            self._save_checkpoint_with_ema()
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
