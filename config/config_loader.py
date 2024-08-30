import yaml


class ConfigLoader:
    def __init__(self, config_file):
        with open(config_file, 'r') as file:
            self.config = yaml.safe_load(file)

    def get_board_size(self):
        return self.config.get("board_size", 24)  # Default to 24

    def get_pieces_per_player(self):
        return self.config.get("pieces_per_player", 15)  # Default to 15

    def get_die_sides(self):
        return self.config.get("die_sides", 6)  # Default to 6

    def get_hidden_size(self):
        return self.config.get("hidden_size", 128)
