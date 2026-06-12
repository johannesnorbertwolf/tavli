import torch
import torch.nn as nn
import torch.nn.functional as F
from typing import List

class BoardEvaluator(nn.Module):
    def __init__(self, input_size: int, hidden_sizes: List[int] = None, aux_heads: int = 0):
        super(BoardEvaluator, self).__init__()
        if hidden_sizes is None:
            hidden_sizes = [512, 256, 128]
        self.hidden_sizes = list(hidden_sizes)
        self.aux_heads = int(aux_heads)

        sizes = [input_size] + self.hidden_sizes + [1]
        self.layers = nn.ModuleList([
            nn.Linear(sizes[i], sizes[i + 1]) for i in range(len(sizes) - 1)
        ])
        # Auxiliary prediction head (#106): training-only side targets that share
        # the trunk. Kept out of self.layers so legacy checkpoint migration and
        # the Core ML export (which traces forward) are untouched.
        if self.aux_heads > 0:
            self.aux_head = nn.Linear(self.hidden_sizes[-1], self.aux_heads)

    def _trunk(self, x):
        for layer in self.layers[:-1]:
            x = F.relu(layer(x))
        return x

    def forward_logits(self, x):
        return self.layers[-1](self._trunk(x))

    def forward_aux_logits(self, x):
        """(main_logit, aux_logits) sharing one trunk pass. Requires aux_heads > 0."""
        h = self._trunk(x)
        return self.layers[-1](h), self.aux_head(h)

    def forward(self, x):
        return torch.sigmoid(self.forward_logits(x))
