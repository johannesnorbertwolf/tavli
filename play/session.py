from dataclasses import dataclass
from enum import Enum
from typing import List, Optional, Tuple

from config.config_loader import ConfigLoader
from domain.constants import WHITE, BLACK
from domain.move import HalfMove, Move
from domain.move_generation import legal_moves
from game.game import Game


class DiceMode(Enum):
    AUTO = "auto"
    MANUAL = "manual"


@dataclass(frozen=True)
class Snapshot:
    next_player: int          # WHITE / BLACK (domain.constants); who plays AFTER this snapshot
    move_played: Optional[Move]
    dice_for_this_ply: Optional[Tuple[int, int]]
    was_pass: bool
    last_move_summary: str
    undo_token: Optional[list] = None  # board.apply() token; runtime-only, not serialized


class PlaySession:
    def __init__(
        self,
        config: ConfigLoader,
        agent,
        ai_checkpoint_path: str,
        dice_mode: DiceMode,
        human_color: int,
        eval_depth: int,
        starting_player: int = WHITE,
    ):
        self.config = config
        self.agent = agent
        self.ai_checkpoint_path = ai_checkpoint_path
        self.dice_mode = dice_mode
        self.human_color = human_color
        self.eval_depth = eval_depth
        self.starting_player = starting_player

        self.game = Game(config, starting_player=starting_player)
        initial = Snapshot(
            next_player=starting_player,
            move_played=None,
            dice_for_this_ply=None,
            was_pass=False,
            last_move_summary="(start)",
        )
        self.history: List[Snapshot] = [initial]
        self._pending_dice: Optional[Tuple[int, int]] = None
        self.last_save_name: Optional[str] = None
        self.dirty_since_save: bool = False

    @classmethod
    def new_game(cls, config, agent, ai_checkpoint_path, dice_mode, human_color, eval_depth):
        return cls(config, agent, ai_checkpoint_path, dice_mode, human_color, eval_depth)

    @classmethod
    def from_save(cls, config, save_file, agent) -> "PlaySession":
        """Reconstruct a session by replaying the saved history from the initial position."""
        starting_player = WHITE if save_file.starting_player == "white" else BLACK
        human_color = WHITE if save_file.human_color == "w" else BLACK
        dice_mode = DiceMode(save_file.dice_mode)
        session = cls(
            config=config,
            agent=agent,
            ai_checkpoint_path=save_file.ai_checkpoint_path,
            dice_mode=dice_mode,
            human_color=human_color,
            eval_depth=save_file.eval_depth,
            starting_player=starting_player,
        )
        for entry in save_file.history:
            d1, d2 = entry["dice"]
            session.set_dice(d1, d2)
            if entry.get("was_pass"):
                session.commit_pass()
            else:
                move = Move(tuple(HalfMove(int(fp), int(tp)) for fp, tp in entry["move"]))
                session.commit_move(move)
        session.dirty_since_save = False
        return session

    # ---- queries -----------------------------------------------------

    def current_player(self) -> int:
        return self.history[-1].next_player

    def current_dice(self) -> Optional[Tuple[int, int]]:
        return self._pending_dice

    def has_dice(self) -> bool:
        return self._pending_dice is not None

    def is_terminal(self) -> bool:
        return self.game.is_over()

    def winner(self) -> Optional[int]:
        return self.game.get_winner()

    def ply_count(self) -> int:
        return len(self.history) - 1

    # ---- dice --------------------------------------------------------

    def roll_dice(self) -> Tuple[int, int]:
        die1, die2 = self.game.dice.roll()
        values = (die1.value, die2.value)
        self._pending_dice = values
        return values

    def set_dice(self, d1: int, d2: int) -> Tuple[int, int]:
        self.game.dice.set(d1, d2)
        self._pending_dice = (d1, d2)
        return (d1, d2)

    # ---- moves -------------------------------------------------------

    def possible_moves(self) -> List[Move]:
        if self._pending_dice is None:
            raise RuntimeError("dice not set for current ply")
        return legal_moves(self.game.board, self.current_player(), self.game.dice)

    def ranked_moves(self, depth: Optional[int] = None) -> List[Tuple[Move, float]]:
        moves = self.possible_moves()
        if not moves:
            return []
        eff_depth = depth if depth is not None else self.eval_depth
        scores = self.agent.evaluate_moves(
            self.game.board, moves, self.current_player(), lookahead_plies=eff_depth
        )
        return sorted(zip(moves, scores), key=lambda x: x[1], reverse=True)

    # ---- commit / pass -----------------------------------------------

    def _format_summary(
        self, color: int, dice: Tuple[int, int], move: Optional[Move], was_pass: bool
    ) -> str:
        idx = self.ply_count() + 1
        letter = "W" if color == WHITE else "B"
        if was_pass:
            return f"{idx}.  {letter}  d={dice[0]} {dice[1]}  (pass)"
        move_str = ", ".join(str(hm) for hm in move.halves)
        return f"{idx}.  {letter}  d={dice[0]} {dice[1]}  {move_str}"

    def commit_move(self, move: Move) -> None:
        if self._pending_dice is None:
            raise RuntimeError("dice not set for current ply")
        mover = self.current_player()
        token = self.game.board.apply(move, mover)
        summary = self._format_summary(mover, self._pending_dice, move, False)
        self.game.switch_turn()
        self.history.append(Snapshot(
            next_player=self.game.current_player,
            move_played=move,
            dice_for_this_ply=self._pending_dice,
            was_pass=False,
            last_move_summary=summary,
            undo_token=token,
        ))
        self._pending_dice = None
        self.dirty_since_save = True

    def commit_pass(self) -> None:
        if self._pending_dice is None:
            raise RuntimeError("dice not set for forced pass")
        mover = self.current_player()
        summary = self._format_summary(mover, self._pending_dice, None, True)
        self.game.switch_turn()
        self.history.append(Snapshot(
            next_player=self.game.current_player,
            move_played=None,
            dice_for_this_ply=self._pending_dice,
            was_pass=True,
            last_move_summary=summary,
        ))
        self._pending_dice = None
        self.dirty_since_save = True

    # ---- undo --------------------------------------------------------

    def undo(self, n: int = 1) -> int:
        if n < 1:
            return 0
        popped = 0
        snap: Optional[Snapshot] = None
        while popped < n and len(self.history) > 1:
            snap = self.history.pop()
            if snap.undo_token is not None:
                self.game.board.undo(snap.undo_token)
            self.game.player = self.history[-1].next_player
            popped += 1
        if popped == 0:
            return 0
        if self.dice_mode is DiceMode.AUTO and snap is not None and snap.dice_for_this_ply is not None:
            d1, d2 = snap.dice_for_this_ply
            self._pending_dice = (d1, d2)
            self.game.dice.die1.value = d1
            self.game.dice.die2.value = d2
        else:
            self._pending_dice = None
        self.dirty_since_save = True
        return popped

    def undo_to_my_decision(self, n: int = 1) -> int:
        """Pop plies back to the human's previous decision point. Returns plies popped.

        Each step rewinds past the most recent decision the human made — typically
        popping both the AI's last ply and the human's preceding ply. No-op if the
        human hasn't made a move yet (e.g. at game start, or AI opening).
        """
        if n < 1:
            return 0
        total = 0
        for _ in range(n):
            target = self._find_prior_human_decision_index()
            if target is None:
                break
            plies_to_pop = (len(self.history) - 1) - target
            if plies_to_pop <= 0:
                break
            total += self.undo(plies_to_pop)
        return total

    def _find_prior_human_decision_index(self) -> Optional[int]:
        """Index i (i < len(history)-1) of the latest snapshot whose next_player is
        the human. Landing on history[i] means it's the human's turn to decide again."""
        for i in range(len(self.history) - 2, -1, -1):
            if self.history[i].next_player == self.human_color:
                return i
        return None

    # ---- history display --------------------------------------------

    def history_lines(self) -> List[str]:
        return [s.last_move_summary for s in self.history[1:]]
