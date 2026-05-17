import torch
import torch.nn as nn
import torch.nn.functional as F
from typing import List

class BoardEvaluator(nn.Module):
    def __init__(self, input_size: int, hidden_sizes: List[int] = None):
        super(BoardEvaluator, self).__init__()
        if hidden_sizes is None:
            hidden_sizes = [512, 256, 128]
        self.hidden_sizes = list(hidden_sizes)

        sizes = [input_size] + self.hidden_sizes + [1]
        self.layers = nn.ModuleList([
            nn.Linear(sizes[i], sizes[i + 1]) for i in range(len(sizes) - 1)
        ])

    def forward_logits(self, x):
        for layer in self.layers[:-1]:
            x = F.relu(layer(x))
        return self.layers[-1](x)

    def forward(self, x):
        return torch.sigmoid(self.forward_logits(x))
