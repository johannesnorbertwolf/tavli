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
    def get_learning_rate(self):
        return self.config.get("learning_rate", 0.001)

    def get_discount_factor(self):
        return self.config.get("discount_factor", 0.9)

    def get_batch_size(self):
        return self.config.get("batch_size", 128)

    def get_epsilon_start(self):
        return self.config.get("epsilon_start", 1.0)

    def get_epsilon_end(self):
        return self.config.get("epsilon_end", 0.01)

    def get_epsilon_decay(self):
        return self.config.get("epsilon_decay", 0.995)

    def get_replay_buffer_size(self):
        return self.config.get("replay_buffer_size", 1000)

    def get_evaluation_frequency(self):
        return self.config.get("evaluation_frequency", 100)

    def get_evaluation_games(self):
        return self.config.get("evaluation_games", 100)