import torch
import torch.nn as nn
import torch.nn.functional as F


class BoardEvaluator(nn.Module):
    def __init__(self, config):
        super(BoardEvaluator, self).__init__()
        number_of_positions = config.get_board_size() + 2
        neurons_per_position = 4 + config.get_pieces_per_player()
        input_size = 1 + number_of_positions * neurons_per_position

        # Define layer sizes
        hidden_size1 = 1024
        hidden_size2 = 1024  # Keep this the same as hidden_size1 for the residual connection
        hidden_size3 = 512

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
        out = F.relu(self.fc1(x))
        out = self.dropout(out)

        # Second layer with residual connection
        residual = out
        out = F.relu(self.fc2(out))
        out = self.dropout(out)
        out += residual  # Residual connection

        # Third layer
        out = F.relu(self.fc3(out))
        out = self.dropout(out)

        # Output layer
        out = torch.sigmoid(self.fc4(out))

        return out