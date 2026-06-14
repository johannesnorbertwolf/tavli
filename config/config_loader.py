import yaml

class ConfigLoader:
    def __init__(self, config_file):
        self.config_file = config_file
        with open(config_file, 'r') as file:
            self.config = yaml.safe_load(file)

    def get_board_size(self):
        return self.config.get("board_size", 24)

    def get_pieces_per_player(self):
        return self.config.get("pieces_per_player", 15)

    def get_home_size(self):
        return self.config.get("home_size", 6)

    def get_die_sides(self):
        return self.config.get("die_sides", 6)

    def get_hidden_size(self):
        return self.config.get("hidden_size", 128)

    def get_alpha(self):
        return self.config.get("alpha", 0.001)

    def get_discount_factor(self):
        return self.config.get("discount_factor", 0.9)

    def get_epsilon_start(self):
        return self.config.get("epsilon_start", 1.0)

    def get_epsilon_end(self):
        return self.config.get("epsilon_end", 0.01)

    def get_epsilon_decay(self):
        return self.config.get("epsilon_decay", 0.995)

    def get_epsilon_decay_games(self):
        return self.config.get("epsilon_decay_games", 0)

    def get_exploration_temperature(self):
        return self.config.get("exploration_temperature", 1.0)

    def get_num_epochs(self):
        return self.config.get("num_epochs", 10)

    def get_games_per_epoch(self):
        return self.config.get("games_per_epoch", 100)

    def get_model_save_every_epochs(self):
        return int(self.config.get("model_save_every_epochs", 0))

    def get_max_grad_norm(self):
        return float(self.config.get("max_grad_norm", 0.0))

    def get_hidden_sizes(self):
        return list(self.config.get("hidden_sizes", [512, 256, 128]))

    def get_lambda_start(self):
        return self.config.get("lambda_start", 0.9)

    def get_lambda_end(self):
        return self.config.get("lambda_end", 0.5)

    def get_alpha_decay(self):
        return self.config.get("alpha_decay", 1.0)

    def get_alpha_decay_every(self):
        return self.config.get("alpha_decay_every", 0)

    def get_alpha_min(self):
        return self.config.get("alpha_min", 0.0)

    def get_training_seed(self):
        return self.config.get("training_seed")

    def get_eval_every_epochs(self):
        return self.config.get("eval_every_epochs", 10)

    def get_eval_games_per_color(self):
        return self.config.get("eval_games_per_color", 10)

    def get_lambda_decay_games(self):
        return self.config.get("lambda_decay_games", 0)

    def get_training_state_path(self):
        return self.config.get("training_state_path", "training_state.json")

    def get_model_save_path(self):
        return self.config.get("model_save_path", "trained_model.pth")

    def get_state_save_every_games(self):
        return self.config.get("state_save_every_games", 100)

    def get_eval_against_random(self):
        return self.config.get("eval_against_random", False)

    def get_eval_against_gold(self):
        return self.config.get("eval_against_gold", True)

    def get_eval_candidate_lookahead_plies(self):
        return int(self.config.get("eval_candidate_lookahead_plies", 1))

    def get_eval_gold_lookahead_plies(self):
        return int(self.config.get("eval_gold_lookahead_plies", 1))

    def get_num_self_play_workers(self):
        return int(self.config.get("num_self_play_workers", 1))

    def get_gold_model_path(self):
        return self.config.get("gold_model_path", "models/gold_v1.pth")

    def get_play_time_budget_s(self) -> float:
        return float(self.config.get("play_time_budget_s", 13.0))

    def get_beam_threshold(self) -> float:
        return float(self.config.get("beam_threshold", 0.08))

    def get_search_relative_cutoff(self) -> float:
        return float(self.config.get("search_relative_cutoff", 0.08))

    def get_search_max_branch(self) -> int:
        return int(self.config.get("search_max_branch", 5))

    def get_search_max_depth(self) -> int:
        return int(self.config.get("search_max_depth", 3))

    def get_eval_seed(self):
        return self.config.get("eval_seed")

    def get_learning_rate(self):
        return float(self.config.get("learning_rate", 0.0003))

    def get_lr_warmup_steps(self):
        return int(self.config.get("lr_warmup_steps", 1000))

    def get_replay_buffer_capacity(self):
        return int(self.config.get("replay_buffer_capacity", 50000))

    def get_minibatch_size(self):
        return int(self.config.get("minibatch_size", 128))

    def get_updates_per_game(self):
        return int(self.config.get("updates_per_game", 5))

    def get_min_buffer_to_train(self):
        return int(self.config.get("min_buffer_to_train", 2000))

    def get_selfplay_2ply_margin(self):
        return float(self.config.get("selfplay_2ply_margin", 0.0))

    def get_selfplay_2ply_max_moves(self):
        return int(self.config.get("selfplay_2ply_max_moves", 4))

    def get_selfplay_seeded_fraction(self):
        return float(self.config.get("selfplay_seeded_fraction", 0.0))

    def get_selfplay_league_fraction(self):
        return float(self.config.get("selfplay_league_fraction", 0.0))

    def get_selfplay_league_opponents(self):
        return list(self.config.get("selfplay_league_opponents", []) or [])

    def get_aux_heads(self):
        return int(self.config.get("aux_heads", 0))

    def get_aux_loss_weight(self):
        return float(self.config.get("aux_loss_weight", 0.3))

    def get_ema_decay(self):
        return float(self.config.get("ema_decay", 0.0))

    def get_selfplay_seed_pool_path(self):
        return self.config.get("selfplay_seed_pool_path", "models/seed_pool.npz")

    def get_use_bearoff_db(self):
        return bool(self.config.get("use_bearoff_db", True))

    def get_bearoff_db_path(self):
        return self.config.get("bearoff_db_path", "models/bearoff_db.npz")

    def get_play_eval_lookahead_plies(self):
        return int(self.config.get("play", {}).get("eval_lookahead_plies", 4))

    def get_play_drill_correct_floor(self):
        return float(self.config.get("play", {}).get("drill_correct_floor", 0.01))

    def get_play_drill_correct_relative(self):
        return float(self.config.get("play", {}).get("drill_correct_relative", 0.03))
