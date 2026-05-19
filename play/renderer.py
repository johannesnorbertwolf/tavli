from typing import List, Optional, Tuple

from domain.move import Move


FOOTER_LINE = "[1-N] play   u undo   h history   e eval   save <n>   q quit"


def format_board_with_moves(board, current_player, dice_values, moves_with_scores) -> str:
    """Two-column board + ranked-move list. Returns a string (one line per row)."""
    board_lines = str(board).splitlines()
    info_lines = ["", f"{current_player}'s turn", f"Rolled: {dice_values}", "Possible moves:"]
    left_lines = board_lines + info_lines
    column_height = len(left_lines)

    moves_lines = []
    for i, (move, score) in enumerate(moves_with_scores, start=1):
        if score is None:
            moves_lines.append(f"{i}: {move}")
        else:
            moves_lines.append(f"{i}: {move} ({score*100:.2f}%)")

    move_columns = []
    for start in range(0, len(moves_lines), column_height):
        chunk = moves_lines[start:start + column_height]
        if len(chunk) < column_height:
            chunk = chunk + [""] * (column_height - len(chunk))
        move_columns.append(chunk)

    left_width = max((len(line) for line in left_lines), default=0) + 4
    move_col_content_width = max([len(line) for line in moves_lines], default=0)
    move_col_width = max(move_col_content_width, 24) + 4

    out_lines = []
    for row in range(column_height):
        line = f"{left_lines[row]:<{left_width}}"
        for col in move_columns:
            line += f"{col[row]:<{move_col_width}}"
        out_lines.append(line.rstrip())
    return "\n".join(out_lines)


def print_board_with_moves(board, current_player, dice_values, moves_with_scores) -> None:
    """Backwards-compat shim that prints what format_board_with_moves returns."""
    print(format_board_with_moves(board, current_player, dice_values, moves_with_scores))


def format_header(session) -> str:
    ply = session.ply_count() + 1
    player = "White" if session.current_player().is_white() else "Black"
    dice = session.current_dice()
    depth_suffix = f" — eval depth {session.eval_depth}"
    if dice is None:
        return f"Ply {ply} — {player} to move{depth_suffix}"
    return f"Ply {ply} — {player} to move — dice {dice[0]} {dice[1]}{depth_suffix}"


def format_footer() -> str:
    return FOOTER_LINE


def format_ply_block(session, ranked_moves: List[Tuple[Move, float]]) -> str:
    """Header + board+moves block + footer."""
    dice = session.current_dice()
    parts = [
        format_header(session),
        format_board_with_moves(session.game.board, session.current_player(), dice, ranked_moves),
        format_footer(),
    ]
    return "\n".join(parts)


def format_ai_played(session, move: Move, score: Optional[float]) -> str:
    player = "White" if session.current_player().is_white() else "Black"
    dice = session.current_dice()
    score_str = f" ({score*100:.2f}%)" if score is not None else ""
    return (
        f"Ply {session.ply_count() + 1} — {player} (AI) — dice {dice[0]} {dice[1]}\n"
        f"{session.game.board}\n"
        f"AI played: {move}{score_str}"
    )


def format_history(session) -> str:
    lines = session.history_lines()
    if not lines:
        return "(no history yet)"
    return "\n".join(lines)
