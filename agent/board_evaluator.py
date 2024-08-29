import torch
import torch.nn as nn

# Define the Neural Network class
class BoardEvaluator(nn.Module):
    def __init__(self, input_size, hidden_size):
        super(BoardEvaluator, self).__init__()
        # Define layers
        self.fc1 = nn.Linear(input_size, hidden_size)  # Input to hidden layer
        self.relu = nn.ReLU()  # Activation function for hidden layer
        self.fc2 = nn.Linear(hidden_size, 1)  # Hidden to output layer
        self.sigmoid = nn.Sigmoid()  # Sigmoid activation for output layer

    def forward(self, x):
        out = self.fc1(x)
        out = self.relu(out)
        out = self.fc2(out)
        out = self.sigmoid(out)
        return out
