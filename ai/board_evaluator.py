import torch
import torch.nn as nn
import torch.nn.functional as F

class BoardEvaluator(nn.Module):
    def __init__(self, config):
        super(BoardEvaluator, self).__init__()
        number_of_positions = config.get_board_size() + 2
        neurons_per_position = 4 + config.get_pieces_per_player()
        input_size = number_of_positions * neurons_per_position

        # Define layer sizes - starting a bit smaller to prevent overfitting
        hidden_size1 = 512
        hidden_size2 = 256
        hidden_size3 = 128

        # Input layer
        self.fc1 = nn.Linear(input_size, hidden_size1)

        # Hidden layers
        self.fc2 = nn.Linear(hidden_size1, hidden_size2)
        self.fc3 = nn.Linear(hidden_size2, hidden_size3)

        # Output layer
        self.fc4 = nn.Linear(hidden_size3, 1)

        # Dropout
        self.dropout = nn.Dropout(0.3)

    def forward(self, x):
        # First layer
        x = self.fc1(x)
        x = F.relu(x)
        x = self.dropout(x)

        # Second layer
        x = self.fc2(x)
        x = F.relu(x)
        x = self.dropout(x)

        # Third layer
        x = self.fc3(x)
        x = F.relu(x)
        x = self.dropout(x)

        # Output layer
        # Use sigmoid to output win probability in [0, 1]
        x = torch.sigmoid(self.fc4(x))

        return x
