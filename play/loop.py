from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

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
        line = io.input("[u/undo, h/history, save <n>, q] > ")
        cmd = parser.parse_command(line)
        if isinstance(cmd, parser.Undo):
            popped = session.undo_to_my_decision(cmd.n)
            io.output(_undo_message(popped))
            return Action("advance")
        if isinstance(cmd, parser.History):
            io.output(renderer.format_history(session))
            continue
        if isinstance(cmd, parser.Save):
            _handle_save(session, io, cmd.name)
            continue
        if isinstance(cmd, parser.Quit):
            if _handle_quit(session, io):
                return Action("quit")
            continue
        if isinstance(cmd, parser.Help):
            io.output("post-game: u/undo [N], h/history, save <name>, q/quit")
            continue
        io.output("post-game accepts: u/undo, h/history, save <n>, q/quit")


# ---- command helpers ------------------------------------------------------


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
