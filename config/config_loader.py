import yaml

class ConfigLoader:
    def __init__(self, config_file):
        with open(config_file, 'r') as file:
            self.config = yaml.safe_load(file)

    def get_board_size(self):
        return self.config.get("board_size", 24)

    def get_pieces_per_player(self):
        return self.config.get("pieces_per_player", 15)

    def get_die_sides(self):
        return self.config.get("die_sides", 6)

    def get_hidden_size(self):
        return self.config.get("hidden_size", 128)

    # New methods for training parameters
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

    def get_replay_buffer_size(self):
        return self.config.get("replay_buffer_size", 0)

    def get_replay_batch_size(self):
        return self.config.get("replay_batch_size", 32)

    def get_replay_updates_per_game(self):
        return self.config.get("replay_updates_per_game", 0)

    # TD(Lambda) parameters
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
