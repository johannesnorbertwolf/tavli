# game/ — Game Runner

## game.py

`Game` ties together the board, dice, and turn state into a single object that the training loop and interactive play use to run a game.

**Construction**: `Game(config, starting_player=BLACK)` creates a `Board.initial(config)`, a `Dice` with the configured number of die sides, and sets `self.player` to `starting_player`. Black starts by default (convention for self-play; either color can be specified for eval).

**Properties and methods**:
- `current_player` → the color whose turn it is (`WHITE` or `BLACK`)
- `switch_turn()` → flips `self.player` to `-self.player`
- `dice.roll()` → rolls both dice in-place (callers read `game.dice.die1.value`, `game.dice.die2.value` after rolling, or pass the `Dice` object to `legal_moves`)
- `is_over()` → `board.has_won(WHITE) or board.has_won(BLACK)`
- `get_winner()` → `WHITE`, `BLACK`, or `None` if not over
- `check_winner(color)` → alias for `board.has_won(color)`

**Display**: `__str__` renders the current player, last dice roll, and the board state as a multi-line string. `print_with_scored_possible_moves(possible_moves, move_scores)` adds a sorted move list with AI evaluation scores — used by the interactive play command.

`Game` does not manage the move application or turn sequence itself; callers (training loop, play script) call `board.apply(move, color)` and `switch_turn()` explicitly. This keeps game flow visible and avoids hidden state transitions.
