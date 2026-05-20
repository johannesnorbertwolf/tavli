from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from domain.half_move import HalfMove
from domain.move import Move
from play import parser, persistence, renderer
from play.session import DiceMode, PlaySession


AgentLoader = Callable[[str], object]


class IO:
    def input(self, prompt: str) -> str:
        raise NotImplementedError

    def output(self, msg: str) -> None:
        raise NotImplementedError


class StdIO(IO):
    def input(self, prompt: str) -> str:
        return input(prompt)

    def output(self, msg: str) -> None:
        print(msg)


@dataclass
class Action:
    kind: str  # "quit", "continue", "advance", "dice_set"
    session: Optional[PlaySession] = None


_HELP_TEXT = (
    "Commands:\n"
    "  1..N         play the ranked move\n"
    "  u, undo [N]  step back one (or N) plies\n"
    "  h, history   list plies played\n"
    "  e, eval [N]  re-rank at lookahead depth N (sticky session default)\n"
    "  save <name>  persist to saved_games/<name>.json\n"
    "  load <name>  resume from saved_games/<name>.json (auto-saves current if dirty)\n"
    "  ?, help      this help\n"
    "  q, quit      exit (asks about unsaved progress)"
)


def run(session: PlaySession, io: IO, agent_loader: Optional[AgentLoader] = None) -> PlaySession:
    """Drive the interactive REPL. Returns the (possibly reloaded) final session."""
    while True:
        if session.is_terminal():
            act = _post_game(session, io)
            if act.kind == "quit":
                return session
            continue

        if not session.has_dice():
            if session.dice_mode is DiceMode.AUTO:
                session.roll_dice()
            else:
                act = _dice_prompt(session, io, agent_loader)
                if act.kind == "quit":
                    return session
                if act.session is not None:
                    session = act.session
                if act.kind != "dice_set":
                    continue

        moves = session.possible_moves()
        if not moves:
            act = _no_moves(session, io)
            if act.kind == "quit":
                return session
            continue

        if session.current_player() == session.human_color:
            act = _human_turn(session, io, agent_loader)
            if act.kind == "quit":
                return session
            if act.session is not None:
                session = act.session
        else:
            _ai_turn(session, io)


# ---- per-state handlers ---------------------------------------------------


def _human_turn(session: PlaySession, io: IO, agent_loader: Optional[AgentLoader]) -> Action:
    forced_depth: Optional[int] = None
    while True:
        ranked = session.ranked_moves(depth=forced_depth)
        forced_depth = None
        io.output(renderer.format_ply_block(session, ranked))
        cmd = parser.parse_command(io.input("> "))

        if isinstance(cmd, parser.PlayMove):
            if 1 <= cmd.rank <= len(ranked):
                session.commit_move(ranked[cmd.rank - 1][0])
                return Action("advance")
            io.output(f"invalid rank; must be 1..{len(ranked)}")
            continue

        if isinstance(cmd, parser.Eval):
            if cmd.depth is not None:
                session.eval_depth = cmd.depth
            forced_depth = session.eval_depth
            io.output(f"(re-ranking at depth {forced_depth}…)")
            continue

        if isinstance(cmd, parser.Undo):
            popped = session.undo_to_my_decision(cmd.n)
            io.output(_undo_message(popped))
            return Action("advance")

        if isinstance(cmd, parser.History):
            io.output(renderer.format_history(session))
            continue

        if isinstance(cmd, parser.Help):
            io.output(_HELP_TEXT)
            continue

        if isinstance(cmd, parser.Save):
            _handle_save(session, io, cmd.name)
            continue

        if isinstance(cmd, parser.Load):
            new_session = _handle_load(session, io, cmd.name, agent_loader)
            if new_session is not None:
                return Action("advance", new_session)
            continue

        if isinstance(cmd, parser.Quit):
            if _handle_quit(session, io):
                return Action("quit")
            continue

        # Unparseable
        io.output(f"unrecognised input: {cmd.reason}. Type 'help' for commands.")


def _dice_prompt(session: PlaySession, io: IO, agent_loader: Optional[AgentLoader]) -> Action:
    while True:
        player = "White" if session.current_player().is_white() else "Black"
        line = io.input(f"{player} to move. Enter dice (e.g. '5 2' or '53'): ")
        try:
            d1, d2 = parser.parse_dice(line, die_sides=session.config.get_die_sides())
            session.set_dice(d1, d2)
            return Action("dice_set")
        except parser.InvalidDiceInput:
            pass

        cmd = parser.parse_command(line)
        if isinstance(cmd, parser.Undo):
            popped = session.undo_to_my_decision(cmd.n)
            io.output(_undo_message(popped))
            return Action("advance")
        if isinstance(cmd, parser.History):
            io.output(renderer.format_history(session))
            continue
        if isinstance(cmd, parser.Help):
            io.output(_HELP_TEXT)
            continue
        if isinstance(cmd, parser.Save):
            _handle_save(session, io, cmd.name)
            continue
        if isinstance(cmd, parser.Load):
            new_session = _handle_load(session, io, cmd.name, agent_loader)
            if new_session is not None:
                return Action("advance", new_session)
            continue
        if isinstance(cmd, parser.Quit):
            if _handle_quit(session, io):
                return Action("quit")
            continue
        io.output("unparseable; enter dice (e.g. '5 2') or a command.")


def _no_moves(session: PlaySession, io: IO) -> Action:
    io.output(renderer.format_header(session))
    io.output(str(session.game.board))
    player = "White" if session.current_player().is_white() else "Black"
    if session.current_player() != session.human_color:
        io.output(f"{player} (AI) has no valid moves; passing.")
        session.commit_pass()
        return Action("advance")
    io.output(f"{player} has no valid moves.")
    line = io.input("[enter] pass   u undo : ").strip()
    if line.lower().startswith("u"):
        rest = line[1:].strip()
        n = 1
        if rest:
            try:
                n = max(1, int(rest))
            except ValueError:
                n = 1
        session.undo_to_my_decision(n)
        return Action("advance")
    session.commit_pass()
    return Action("advance")


def _ai_turn(session: PlaySession, io: IO) -> None:
    move, score = session.agent.get_best_move(
        session.game.board,
        session.possible_moves(),
        session.current_player(),
        lookahead_plies=2,
    )
    io.output(renderer.format_ai_played(session, move, score))
    session.commit_move(move)


def _post_game(session: PlaySession, io: IO) -> Action:
    winner = session.winner()
    label = "White" if winner is not None and winner.is_white() else "Black"
    io.output(str(session.game.board))
    io.output(f"Game over. {label} wins.")
    while True:
        line = io.input("[u/undo, h/history, review [N], drill [N], save <n>, q] > ")
        cmd = parser.parse_command(line)
        if isinstance(cmd, parser.Undo):
            popped = session.undo_to_my_decision(cmd.n)
            io.output(_undo_message(popped))
            return Action("advance")
        if isinstance(cmd, parser.History):
            io.output(renderer.format_history(session))
            continue
        if isinstance(cmd, parser.Review):
            _handle_review(session, io, cmd.threshold)
            continue
        if isinstance(cmd, parser.Drill):
            _handle_drill(session, io, cmd.threshold)
            continue
        if isinstance(cmd, parser.Save):
            _handle_save(session, io, cmd.name)
            continue
        if isinstance(cmd, parser.Quit):
            if _handle_quit(session, io):
                return Action("quit")
            continue
        if isinstance(cmd, parser.Help):
            io.output("post-game: u/undo [N], h/history, review [N], drill [N], save <name>, q/quit")
            continue
        io.output("post-game accepts: u/undo, h/history, review [N], drill [N], save <n>, q/quit")


# ---- command helpers ------------------------------------------------------


def _reconstruct_move(move: Move, board) -> Move:
    """Re-build a Move so its HalfMoves reference the given board's own Point objects."""
    return Move([
        HalfMove(
            board.points[hm.from_point.position],
            board.points[hm.to_point.position],
            hm.color,
        )
        for hm in move.half_moves
    ])


def _make_replay_session(session: PlaySession) -> PlaySession:
    return PlaySession(
        config=session.config,
        agent=session.agent,
        ai_checkpoint_path=session.ai_checkpoint_path,
        dice_mode=session.dice_mode,
        human_color=session.human_color,
        eval_depth=session.eval_depth,
        starting_player=session.starting_player,
    )


def _collect_blunders(session: PlaySession, threshold: float) -> list:
    """Replay the game and return a list of blunder dicts for human plies.

    A ply is flagged when (best_score - played_score) / best_score >= threshold
    (relative gap), guarding against best_score == 0.  Returns dicts with keys:
    ply_num, snap, board_str, ranked, played_move, played_score, best_move,
    best_score, gap.
    """
    if len(session.history) <= 1:
        return []

    replay = _make_replay_session(session)
    blunders = []

    for snap in session.history[1:]:
        is_human = replay.current_player() == session.human_color
        replay.set_dice(*snap.dice_for_this_ply)

        if snap.was_pass or not is_human or snap.move_played is None:
            if snap.was_pass:
                replay.commit_pass()
            else:
                replay.commit_move(_reconstruct_move(snap.move_played, replay.game.board))
            continue

        moves = replay.possible_moves()
        if len(moves) <= 1:
            replay.commit_move(_reconstruct_move(snap.move_played, replay.game.board))
            continue

        ranked = replay.ranked_moves()
        best_move, best_score = ranked[0]

        played_key = str(snap.move_played)
        played_score = next(
            (score for move, score in ranked if str(move) == played_key),
            None,
        )

        if played_score is not None and best_score > 0:
            relative_gap = (best_score - played_score) / best_score
            if relative_gap >= threshold:
                blunders.append({
                    "ply_num": replay.ply_count() + 1,
                    "snap": snap,
                    "board_str": str(replay.game.board),
                    "ranked": ranked,
                    "played_move": snap.move_played,
                    "played_score": played_score,
                    "best_move": best_move,
                    "best_score": best_score,
                    "gap": best_score - played_score,
                    "player_is_white": replay.current_player().is_white(),
                })

        replay.commit_move(_reconstruct_move(snap.move_played, replay.game.board))

    return blunders


def _match_move(user_froms: list, ranked: list, dice: tuple, is_white: bool) -> list:
    """Match user-entered source positions to legal moves.

    For exactly 2 positions with 2 dice, uses ordered die-assignment:
    user_froms[0] uses dice[0], user_froms[1] uses dice[1].  This eliminates
    the disambiguation dialog in the common case.  Falls back to sorted-source
    matching for single-position inputs (merged / single-die) and doubles.
    """
    if not user_froms:
        return []

    sign = 1 if is_white else -1

    if len(user_froms) == 2 and len(dice) == 2:
        d1, d2 = dice
        to0 = user_froms[0] + sign * d1
        to1 = user_froms[1] + sign * d2
        key = f"({user_froms[0]}->{to0},{user_froms[1]}->{to1})"
        ordered = [(m, s) for m, s in ranked if str(m) == key]
        if ordered:
            return ordered
        # Ordered assignment not legal: fall through to source-matching

    target = sorted(user_froms)
    return [
        (move, score) for move, score in ranked
        if sorted(hm.from_point.position for hm in move.half_moves) == target
    ]


def _handle_review(session: PlaySession, io: IO, threshold: float) -> None:
    if len(session.history) <= 1:
        io.output("no plies to review")
        return

    io.output(f"Post-game review — flagging moves >{threshold*100:.0f}% relative gap\n")
    blunders = _collect_blunders(session, threshold)

    for b in blunders:
        io.output(renderer.format_blunder_block(
            b["ply_num"], b["snap"].dice_for_this_ply, b["board_str"],
            b["played_move"], b["played_score"],
            b["best_move"], b["best_score"],
        ))

    if not blunders:
        io.output(f"No blunders found above {threshold*100:.0f}% threshold — well played!")
    else:
        io.output(f"\n{len(blunders)} blunder(s) found.")


def _handle_drill(session: PlaySession, io: IO, threshold: float) -> None:
    blunders = _collect_blunders(session, threshold)
    if not blunders:
        io.output("No blunders to drill — well played!")
        return

    correct_floor = session.config.get_play_drill_correct_floor()
    correct_relative = session.config.get_play_drill_correct_relative()
    io.output(
        f"Drill: {len(blunders)} blunder(s) found.  "
        "Enter source point(s) space-separated (e.g. '15 16'), or: solution, skip, back"
    )

    i = 0
    while 0 <= i < len(blunders):
        b = blunders[i]
        io.output(renderer.format_drill_position(i + 1, len(blunders), b))
        advance = _drill_inner(b, io, correct_floor, correct_relative)
        if advance == "back":
            if i == 0:
                io.output("Already at the first blunder.")
            else:
                i -= 1
        else:
            i += 1

    io.output("Drill complete.")


def _drill_inner(b: dict, io: IO, correct_floor: float, correct_relative: float) -> str:
    """Drive interactive Q&A for one blunder. Returns 'next' or 'back'."""
    correct_threshold = max(correct_floor, b["best_score"] * correct_relative)
    while True:
        line = io.input("Your move (solution / skip / back) > ").strip().lower()

        if line in ("solution", "sol"):
            io.output(
                f"Best:      {b['best_move']}  ({b['best_score']*100:.1f}%)\n"
                f"You played: {b['played_move']}  ({b['played_score']*100:.1f}%)"
            )
            return "next"

        if line in ("skip", "s"):
            return "next"

        if line in ("back", "b"):
            return "back"

        user_froms = parser.parse_move_input(line)
        if user_froms is None:
            io.output("Enter source point(s) as numbers (e.g. '15 16'), or: solution, skip, back")
            continue

        matches = _match_move(
            user_froms, b["ranked"],
            b["snap"].dice_for_this_ply, b["player_is_white"],
        )
        if not matches:
            io.output("No legal move from those positions. Try again.")
            continue

        if len(matches) > 1:
            # Multiple legal moves with the same source positions (different die assignments)
            for idx, (mv, sc) in enumerate(matches, 1):
                io.output(f"  {idx}: {mv}  ({sc*100:.1f}%)")
            raw = io.input("Multiple options — pick [1/2/…] > ").strip()
            try:
                choice = int(raw) - 1
                if not (0 <= choice < len(matches)):
                    raise ValueError
            except ValueError:
                io.output("Invalid choice; try again.")
                continue
            move, score = matches[choice]
        else:
            move, score = matches[0]

        gap = b["best_score"] - score
        if gap <= correct_threshold:
            if gap < 0.001:
                io.output(f"Excellent! {move}  ({score*100:.1f}%) — that's the best move.")
            else:
                io.output(f"Great choice! {move}  ({score*100:.1f}%) — very close to optimal.")
            return "next"
        else:
            io.output(f"Not quite ({score*100:.1f}%) — think a little harder!")


def _handle_save(session: PlaySession, io: IO, name: str) -> None:
    path = persistence.resolve_path(name)
    if path.exists():
        confirm = io.input(f"{path} exists. Overwrite? [y/N]: ")
        if confirm.strip().lower() != "y":
            io.output("save cancelled")
            return
    written = persistence.dump(session, name)
    session.last_save_name = name
    session.dirty_since_save = False
    io.output(f"saved to {written}")


def _handle_load(
    session: PlaySession, io: IO, name: str, agent_loader: Optional[AgentLoader]
) -> Optional[PlaySession]:
    if agent_loader is None:
        io.output("load is not available in this context")
        return None

    path = persistence.resolve_path(name)
    if not path.exists():
        io.output(f"no such save: {path}")
        return None

    if session.dirty_since_save:
        if session.last_save_name is not None:
            auto_path = persistence.dump(session, session.last_save_name)
            io.output(f"auto-saved current session to {auto_path}")
        else:
            auto_path = persistence.dump(session, persistence.autosave_name())
            io.output(f"auto-saved current session to {auto_path}")

    save_file = persistence.load(path)
    try:
        agent = agent_loader(save_file.ai_checkpoint_path)
    except FileNotFoundError:
        repl = io.input(
            f"AI checkpoint '{save_file.ai_checkpoint_path}' not found. "
            "Enter replacement path (or 'c' to cancel): "
        ).strip()
        if not repl or repl.lower() == "c":
            io.output("load cancelled")
            return None
        try:
            agent = agent_loader(repl)
        except FileNotFoundError:
            io.output(f"replacement checkpoint '{repl}' also not found; load cancelled")
            return None
        save_file.ai_checkpoint_path = repl

    new_session = PlaySession.from_save(session.config, save_file, agent)
    new_session.last_save_name = name
    io.output(f"loaded session from {path}")
    return new_session


def _handle_quit(session: PlaySession, io: IO) -> bool:
    if not session.dirty_since_save:
        return True
    line = io.input(
        "Unsaved progress. [q] discard & quit / [save <n>] save & quit / [c] cancel: "
    ).strip()
    if not line or line.lower() in ("c", "cancel"):
        return False
    cmd = parser.parse_command(line)
    if isinstance(cmd, parser.Quit):
        return True
    if isinstance(cmd, parser.Save):
        _handle_save(session, io, cmd.name)
        return True
    io.output("quit cancelled")
    return False


def _undo_message(popped: int) -> str:
    if popped == 0:
        return "nothing to undo"
    if popped == 1:
        return "undone 1 ply"
    return f"undone {popped} plies"
