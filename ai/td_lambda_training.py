import torch
from ai.agent import Agent, RandomAgent
from ai.board_evaluator import BoardEvaluator
from ai.board_encoder import BoardEncoder
from ai.checkpoint_io import save_checkpoint, ENCODER_VERSION_LEGACY, HIDDEN_SIZES_LEGACY, _migrate_state_dict
from domain.color import Color
from game.game import Game
from tqdm import tqdm
from domain.possible_moves import PossibleMoves
import numpy as np
import random
import time
import json
import os

class TdLambdaTraining:
    def __init__(self, board_evaluator: BoardEvaluator, board_encoder: BoardEncoder, config):
        self.board_evaluator = board_evaluator
        self.board_encoder = board_encoder
        self.config = config
        self.agent = Agent(self.board_evaluator, self.board_encoder)

        # TD(Lambda) parameters
        self.alpha = self.config.get_alpha()
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
        self.alpha_decay = self.config.get_alpha_decay()
        self.alpha_decay_every = self.config.get_alpha_decay_every()
        self.alpha_min = self.config.get_alpha_min()
        self.lambda_decay_games = max(0, int(self.config.get_lambda_decay_games()))
        self.training_state_path = self.config.get_training_state_path()
        self.state_save_every_games = max(0, int(self.config.get_state_save_every_games()))
        self.global_game_num = 0
        self.max_grad_norm = self.config.get_max_grad_norm()
        self.model_save_every_epochs = max(0, int(self.config.get_model_save_every_epochs()))

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
        self.td_leaf_enabled = self.config.get_td_leaf_enabled()
        self.td_leaf_lookahead_plies = self.config.get_td_leaf_lookahead_plies()

        self.model_save_path = "trained_model.pth"

        self._try_load_gold_agent()
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

        if self.alpha_decay_every and self.alpha_decay_every > 0:
            if (game_num + 1) % self.alpha_decay_every == 0:
                self.alpha = max(self.alpha_min, self.alpha * self.alpha_decay)

    def _update_lambda(self):
        if self.lambda_decay_games <= 0:
            self.lambda_ = self.lambda_start
            return
        progress = min(self.global_game_num, self.lambda_decay_games) / self.lambda_decay_games
        self.lambda_ = self.lambda_end + (self.lambda_start - self.lambda_end) * np.exp(-1.0 * progress * 10.0)

    def _save_training_state(self):
        state = {
            "global_game_num": int(self.global_game_num),
            "lambda": float(self.lambda_),
            "epsilon": float(self.epsilon),
            "alpha": float(self.alpha),
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
            self.alpha = float(state.get("alpha", self.alpha))
            print(
                f"Loaded training state from {self.training_state_path}: "
                f"games={self.global_game_num}, lambda={self.lambda_:.4f}, "
                f"epsilon={self.epsilon:.4f}, alpha={self.alpha:.6f}"
            )
        except Exception as exc:
            print(f"Could not load training state from {self.training_state_path}: {exc}. Starting fresh.")

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

    def _apply_trajectory(self, traj):
        """Run TD(λ) updates from a worker trajectory ending at a real terminal."""
        states = traj["states"]
        movers = traj["movers"]
        terminal_winner_white = bool(traj["terminal_winner_white"])
        plies = traj["plies"]
        td_leaf_targets = traj.get("td_leaf_targets")
        T = len(movers)

        if T == 0:
            return {"plies": 0, "td_abs_sum": 0.0, "td_count": 0, "game_seconds": traj.get("game_seconds", 0.0)}

        eligibility_traces = {p: torch.zeros_like(p.data) for p in self.board_evaluator.parameters()}
        td_abs_sum = 0.0
        td_count = 0

        self.board_evaluator.eval()
        value_tensor = self.board_evaluator(self._to_model_tensor(states[0]))
        self.board_evaluator.train()
        value = value_tensor.item()

        for i in range(T):
            is_terminal = (i == T - 1)
            encoded_next = states[i + 1]
            mover_is_white = movers[i]

            if is_terminal:
                mover_won = (terminal_winner_white == mover_is_white)
                reward_from_mover = 1.0 if mover_won else 0.0
                next_value_from_mover = 0.0
            else:
                td_leaf_target = td_leaf_targets[i] if td_leaf_targets is not None else None
                if td_leaf_target is None:
                    self.board_evaluator.eval()
                    next_value_tensor = self.board_evaluator(self._to_model_tensor(encoded_next))
                    self.board_evaluator.train()
                    next_value = next_value_tensor.item()
                else:
                    next_value = float(td_leaf_target)
                reward_from_mover = 0.0
                next_value_from_mover = 1.0 - next_value

            td_error = reward_from_mover + self.gamma * next_value_from_mover - value
            td_abs_sum += abs(td_error)
            td_count += 1

            self.board_evaluator.zero_grad()
            value_tensor.backward()

            with torch.no_grad():
                for param in self.board_evaluator.parameters():
                    if param.grad is not None:
                        eligibility_traces[param] = self.gamma * self.lambda_ * eligibility_traces[param] + param.grad

                if self.max_grad_norm > 0:
                    total_norm = sum(t.norm() ** 2 for t in eligibility_traces.values()) ** 0.5
                    scale = self.max_grad_norm / max(total_norm, self.max_grad_norm)
                    for param in eligibility_traces:
                        eligibility_traces[param] = eligibility_traces[param] * scale

                for param in self.board_evaluator.parameters():
                    if param.grad is not None:
                        param.data += self.alpha * td_error * eligibility_traces[param]

            if is_terminal:
                # Ground opponent's terminal state to actual outcome
                self.board_evaluator.zero_grad()
                self.board_evaluator.eval()
                value_tensor_next = self.board_evaluator(self._to_model_tensor(encoded_next))
                self.board_evaluator.train()
                value_next = value_tensor_next.item()
                opponent_target = 1.0 - reward_from_mover
                td_error_next = opponent_target - value_next
                td_abs_sum += abs(td_error_next)
                td_count += 1
                value_tensor_next.backward()
                with torch.no_grad():
                    for param in self.board_evaluator.parameters():
                        if param.grad is not None:
                            param.data += self.alpha * td_error_next * param.grad
            else:
                self.board_evaluator.eval()
                value_tensor = self.board_evaluator(self._to_model_tensor(encoded_next))
                self.board_evaluator.train()
                value = value_tensor.item()

        return {"plies": plies, "td_abs_sum": td_abs_sum, "td_count": td_count, "game_seconds": traj.get("game_seconds", 0.0)}

    def _get_worker_fn(self):
        from ai.self_play_worker import worker_main
        return worker_main

    def _send_weights_to_worker(self, weight_q):
        weights = {k: v.detach().cpu().numpy().copy() for k, v in self.board_evaluator.state_dict().items()}
        weight_q.put((weights, float(self.epsilon), float(self.exploration_temperature)))

    def train_one_game(self, verbose_log_file=None):
        """Self-play one full game to a real terminal."""
        game = Game(self.config)
        log_fh = None
        if verbose_log_file:
            log_fh = open(verbose_log_file, 'w')
        game_start_time = time.perf_counter()
        plies = 0
        td_abs_sum = 0.0
        td_count = 0

        eligibility_traces = {param: torch.zeros_like(param.data) for param in self.board_evaluator.parameters()}

        encoded_board = self.board_encoder.encode_board(game.board, game.current_player == Color.WHITE)
        self.board_evaluator.eval()
        value_tensor = self.board_evaluator(self._to_model_tensor(encoded_board))
        self.board_evaluator.train()
        value = value_tensor.item()

        while True:
            plies += 1
            current_player = game.current_player

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

            is_real_terminal = game.is_over()
            encoded_board_next = self.board_encoder.encode_board(game.board, game.current_player == Color.WHITE)

            if is_real_terminal:
                winner = game.get_winner()
                reward = 1 if winner == Color.WHITE else 0
                reward_from_mover_perspective = reward if current_player == Color.WHITE else 1 - reward
                next_value_from_mover_perspective = 0.0
            else:
                if self.td_leaf_enabled:
                    self.board_evaluator.eval()
                    next_value = self.agent.value_with_lookahead(
                        game.board, game.current_player, depth=self.td_leaf_lookahead_plies
                    )
                    self.board_evaluator.train()
                else:
                    self.board_evaluator.eval()
                    next_value_tensor = self.board_evaluator(self._to_model_tensor(encoded_board_next))
                    self.board_evaluator.train()
                    next_value = next_value_tensor.item()
                reward_from_mover_perspective = 0.0
                next_value_from_mover_perspective = 1.0 - next_value

            td_error = reward_from_mover_perspective + self.gamma * next_value_from_mover_perspective - value
            td_abs_sum += abs(td_error)
            td_count += 1

            self.board_evaluator.zero_grad()
            value_tensor.backward()

            with torch.no_grad():
                for param in self.board_evaluator.parameters():
                    if param.grad is not None:
                        eligibility_traces[param] = self.gamma * self.lambda_ * eligibility_traces[param] + param.grad

                if self.max_grad_norm > 0:
                    total_norm = sum(t.norm() ** 2 for t in eligibility_traces.values()) ** 0.5
                    scale = self.max_grad_norm / max(total_norm, self.max_grad_norm)
                    for param in eligibility_traces:
                        eligibility_traces[param] = eligibility_traces[param] * scale

                for param in self.board_evaluator.parameters():
                    if param.grad is not None:
                        param.data += self.alpha * td_error * eligibility_traces[param]

            if is_real_terminal:
                # Ground opponent's terminal state to actual outcome
                self.board_evaluator.zero_grad()
                self.board_evaluator.eval()
                value_tensor_next = self.board_evaluator(self._to_model_tensor(encoded_board_next))
                self.board_evaluator.train()
                value_next = value_tensor_next.item()

                opponent_color = game.current_player
                target_opponent = reward if opponent_color == Color.WHITE else 1 - reward
                td_error_next = target_opponent - value_next
                td_abs_sum += abs(td_error_next)
                td_count += 1
                value_tensor_next.backward()

                with torch.no_grad():
                    for param in self.board_evaluator.parameters():
                        if param.grad is not None:
                            param.data += self.alpha * td_error_next * param.grad

                if log_fh:
                    log_fh.write(f"Game over. Winner is {game.get_winner()}.\n")
                    log_fh.close()
                break
            else:
                if log_fh:
                    log_fh.write(f"Player: {current_player}\n")
                    log_fh.write(f"Dice: {dice}\n")
                    log_fh.write(f"Board:\n{game.board}\n")
                    log_fh.write(f"Move chosen: {move}\n")
                    if score is not None:
                        log_fh.write(f"Board score: {score}\n")
                    log_fh.write(f"Lambda value: {self.lambda_}.\n")
                    log_fh.write(f"Epsilon value: {self.epsilon}.\n")
                    log_fh.write(f"TD Error: {td_error}\n")
                    log_fh.write("-" * 20 + "\n")

                self.board_evaluator.eval()
                value_tensor = self.board_evaluator(self._to_model_tensor(encoded_board_next))
                self.board_evaluator.train()
                value = value_tensor.item()
                encoded_board = encoded_board_next

        return {
            "game_seconds": time.perf_counter() - game_start_time,
            "plies": plies,
            "td_abs_sum": td_abs_sum,
            "td_count": td_count,
        }


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
            print(f"Epoch {epoch + 1} mean |TD error|: {epoch_td_mae:.6f}")
            self._save_training_state()

            if self.model_save_every_epochs > 0 and (epoch + 1) % self.model_save_every_epochs == 0:
                save_checkpoint(self.model_save_path, self.board_evaluator, self.config)
                print(f"Model checkpoint saved at epoch {epoch + 1}")

            if (epoch + 1) % self.eval_every_epochs == 0:
                if self.eval_against_random:
                    white_rate, black_rate, avg_rate = self._evaluate_against_random(self.eval_games_per_color)
                    print(
                        f"Eval vs random @ epoch {epoch + 1}: "
                        f"white {white_rate*100:.1f}%, black {black_rate*100:.1f}%, avg {avg_rate*100:.1f}% "
                        f"({self.eval_games_per_color} games/color)"
                    )
                if self.eval_against_gold:
                    gold_eval = self._evaluate_against_gold(self.eval_games_per_color)
                    if gold_eval is None:
                        print(
                            f"Eval vs gold @ epoch {epoch + 1}: skipped "
                            f"(missing or unloadable gold model: {self.gold_model_path})"
                        )
                        self._append_gold_eval_log(
                            epoch_num=epoch + 1,
                            games_per_color=self.eval_games_per_color,
                            white_rate=0.0,
                            black_rate=0.0,
                            avg_rate=0.0,
                            status="skipped",
                        )
                    else:
                        white_rate, black_rate, avg_rate = gold_eval
                        print(
                            f"Eval vs gold @ epoch {epoch + 1}: "
                            f"white {white_rate*100:.1f}%, black {black_rate*100:.1f}%, avg {avg_rate*100:.1f}% "
                            f"({self.eval_games_per_color} games/color)"
                        )
                        self._append_gold_eval_log(
                            epoch_num=epoch + 1,
                            games_per_color=self.eval_games_per_color,
                            white_rate=white_rate,
                            black_rate=black_rate,
                            avg_rate=avg_rate,
                        )

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

        save_checkpoint(self.model_save_path, self.board_evaluator, self.config)
        self._save_training_state()
        print(f"Model saved to {self.model_save_path}")

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
                print(f"Epoch {epoch + 1} mean |TD error|: {epoch_td_mae:.6f}")
                self._save_training_state()

                if self.model_save_every_epochs > 0 and (epoch + 1) % self.model_save_every_epochs == 0:
                    save_checkpoint(self.model_save_path, self.board_evaluator, self.config)
                    print(f"Model checkpoint saved at epoch {epoch + 1}")

                if (epoch + 1) % self.eval_every_epochs == 0:
                    if self.eval_against_random:
                        white_rate, black_rate, avg_rate = self._evaluate_against_random(self.eval_games_per_color)
                        print(
                            f"Eval vs random @ epoch {epoch + 1}: "
                            f"white {white_rate*100:.1f}%, black {black_rate*100:.1f}%, avg {avg_rate*100:.1f}% "
                            f"({self.eval_games_per_color} games/color)"
                        )
                    if self.eval_against_gold:
                        gold_eval = self._evaluate_against_gold(self.eval_games_per_color)
                        if gold_eval is None:
                            print(
                                f"Eval vs gold @ epoch {epoch + 1}: skipped "
                                f"(missing or unloadable gold model: {self.gold_model_path})"
                            )
                            self._append_gold_eval_log(
                                epoch_num=epoch + 1,
                                games_per_color=self.eval_games_per_color,
                                white_rate=0.0, black_rate=0.0, avg_rate=0.0,
                                status="skipped",
                            )
                        else:
                            white_rate, black_rate, avg_rate = gold_eval
                            print(
                                f"Eval vs gold @ epoch {epoch + 1}: "
                                f"white {white_rate*100:.1f}%, black {black_rate*100:.1f}%, avg {avg_rate*100:.1f}% "
                                f"({self.eval_games_per_color} games/color)"
                            )
                            self._append_gold_eval_log(
                                epoch_num=epoch + 1,
                                games_per_color=self.eval_games_per_color,
                                white_rate=white_rate, black_rate=black_rate, avg_rate=avg_rate,
                            )

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

            save_checkpoint(self.model_save_path, self.board_evaluator, self.config)
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
