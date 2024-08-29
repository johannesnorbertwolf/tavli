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
#
# # Initialize the neural network with random weights
# input_size = 128  # Example input size, adjust based on your actual board encoding
# hidden_size = 64  # Example hidden layer size
# model = BoardEvaluator(input_size, hidden_size)
#
# # Example: Apply the neural network to multiple board encodings
#
# # Create some random board encodings as an example (batch_size x input_size)
# batch_size = 10
# board_encodings = torch.rand(batch_size, input_size)
#
# # Pass the encodings through the network
# outputs = model(board_encodings)
#
# # Find the index of the board encoding with the maximum output
# max_index = torch.argmax(outputs)
#
# # Get the board encoding with the maximum output
# best_encoding = board_encodings[max_index]
#
# print("Board encoding with the highest score:")
# print(best_encoding)
# print("Highest score:", outputs[max_index].item())