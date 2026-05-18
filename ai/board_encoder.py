import numpy as np

from domain.board import Board
from domain.constants import WHITE, BLACK
from config.config_loader import ConfigLoader

# Encoder versions kept for backward compatibility.
LEGACY_V1 = "legacy_unary_v1"   # gold_v1..v4: 2 color bits + 2 captured + N count
UNARY_V2 = "unary_v2"           # gold_v5: 1 color bit + 2 captured + N count
UNARY_V3 = "unary_v3"           # current: unary_v2 raw + 18 smart features

SMART_FEATURE_COUNT = 18


class BoardEncoder:
    def __init__(self, config: ConfigLoader, version: str = LEGACY_V1):
        self.version = version
        self.board_size = config.get_board_size()
        self.pieces_per_player = config.get_pieces_per_player()
        self.home_size = config.get_home_size()

        if version == LEGACY_V1:
            self.point_size = 4 + self.pieces_per_player
        else:
            self.point_size = 3 + self.pieces_per_player

        self._num_points = self.board_size + 2  # 0 and N+1 are bear-off slots
        self._raw_size = self._num_points * self.point_size
        self._smart_size = SMART_FEATURE_COUNT if version == UNARY_V3 else 0

    @property
    def input_size(self) -> int:
        return self._raw_size + self._smart_size

    def encode_board(self, board: Board, is_whites_turn: bool) -> np.ndarray:
        if self.version == LEGACY_V1:
            return self._encode_legacy(board, is_whites_turn)
        return self._encode_modern(board, is_whites_turn)

    def _encode_legacy(self, board: Board, is_whites_turn: bool) -> np.ndarray:
        out = np.zeros(self._raw_size, dtype=np.float32)
        ps = self.point_size
        our = WHITE if is_whites_turn else BLACK
        their = BLACK if is_whites_turn else WHITE
        n = self._num_points

        for slot in range(n):
            pi = slot if is_whites_turn else (n - 1 - slot)
            if board.n[pi] == 0:
                continue
            base = slot * ps
            is_ours = board.color[pi] == our
            # legacy color bits: [1, 0] = ours, [1, 1] = theirs
            out[base] = 1.0
            if not is_ours:
                out[base + 1] = 1.0
            if board.pinned[pi] and board.color[pi] == our:
                out[base + 2] = 1.0
            if board.pinned[pi] and board.color[pi] == their:
                out[base + 3] = 1.0
            count = board.n[pi]
            if count:
                out[base + 4 : base + 4 + count] = 1.0
        return out

    def _encode_modern(self, board: Board, is_whites_turn: bool) -> np.ndarray:
        is_v3 = self.version == UNARY_V3
        out = np.zeros(self.input_size, dtype=np.float32)
        ps = self.point_size
        bs = self.board_size
        ppp = self.pieces_per_player
        n = self._num_points
        our = WHITE if is_whites_turn else BLACK
        their = BLACK if is_whites_turn else WHITE

        # In flipped (current-player) coordinates:
        #   slot 0       = opponent's bear-off
        #   slot n - 1   = our bear-off
        #   our home     = slots [bs - home_size + 1 .. bs]   = [19..24]
        #   opp home     = slots [1 .. home_size]             = [1..6]
        our_home_lo = bs - self.home_size + 1
        our_home_hi = bs
        opp_home_lo = 1
        opp_home_hi = self.home_size
        last_slot = n - 1

        our_pip = 0; their_pip = 0
        our_blots = 0; their_blots = 0
        our_held = 0; their_held = 0
        our_pinned = 0; their_pinned = 0
        our_in_our_home = 0; their_in_their_home = 0
        our_in_their_home = 0; their_in_our_home = 0
        our_borne = 0; their_borne = 0
        our_run = 0; our_max_prime = 0
        their_run = 0; their_max_prime = 0

        for slot in range(n):
            pi = slot if is_whites_turn else (n - 1 - slot)

            if board.n[pi] == 0:
                if is_v3:
                    if our_run > our_max_prime:
                        our_max_prime = our_run
                    if their_run > their_max_prime:
                        their_max_prime = their_run
                    our_run = 0
                    their_run = 0
                continue

            base = slot * ps
            ni = board.n[pi]
            ci = board.color[pi]
            pi_pinned = board.pinned[pi]
            is_ours = ci == our
            count = ni
            captured_by_our = pi_pinned and ci == our
            captured_by_their = pi_pinned and ci == their

            # Per-point raw encoding (unary_v2 layout):
            #   [color_bit, captured_by_us, captured_by_them, unary_count...]
            if not is_ours:
                out[base] = 1.0
            if captured_by_our:
                out[base + 1] = 1.0
            if captured_by_their:
                out[base + 2] = 1.0
            if count:
                out[base + 3 : base + 3 + count] = 1.0

            if not is_v3:
                continue

            if captured_by_our:
                our_count = count
                their_count = 1
            elif captured_by_their:
                our_count = 1
                their_count = count
            elif is_ours:
                our_count = count
                their_count = 0
            else:
                our_count = 0
                their_count = count

            # Bear-off slots: contribute only to borne-off counters; no pip / blot /
            # prime / home accounting since these aren't on-board positions.
            if slot == 0:
                their_borne += their_count
                our_borne += our_count
                if our_run > our_max_prime:
                    our_max_prime = our_run
                if their_run > their_max_prime:
                    their_max_prime = their_run
                our_run = 0
                their_run = 0
                continue
            if slot == last_slot:
                our_borne += our_count
                their_borne += their_count
                if our_run > our_max_prime:
                    our_max_prime = our_run
                if their_run > their_max_prime:
                    their_max_prime = their_run
                our_run = 0
                their_run = 0
                continue

            # Pip counts: our distance to bear-off is (last_slot - slot); theirs is slot.
            our_pip += our_count * (last_slot - slot)
            their_pip += their_count * slot

            # Blots: a single piece of one color with no opposing piece pinning it.
            if is_ours and not captured_by_their and count == 1:
                our_blots += 1
            elif (not is_ours) and not captured_by_our and count == 1:
                their_blots += 1

            # Held points (≥2 of dominant color) and prime runs.
            if is_ours and count >= 2:
                our_held += 1
                our_run += 1
                if their_run > their_max_prime:
                    their_max_prime = their_run
                their_run = 0
            elif (not is_ours) and count >= 2:
                their_held += 1
                their_run += 1
                if our_run > our_max_prime:
                    our_max_prime = our_run
                our_run = 0
            else:
                if our_run > our_max_prime:
                    our_max_prime = our_run
                if their_run > their_max_prime:
                    their_max_prime = their_run
                our_run = 0
                their_run = 0

            # Pinning: in Plakoto a pinned point holds exactly one trapped piece.
            if captured_by_our:
                their_pinned += 1
            if captured_by_their:
                our_pinned += 1

            # Home-region counts.
            if our_home_lo <= slot <= our_home_hi:
                our_in_our_home += our_count
                their_in_our_home += their_count
            elif opp_home_lo <= slot <= opp_home_hi:
                their_in_their_home += their_count
                our_in_their_home += our_count

        if is_v3:
            if our_run > our_max_prime:
                our_max_prime = our_run
            if their_run > their_max_prime:
                their_max_prime = their_run

            inv_pip = 1.0 / (ppp * bs)
            inv_ppp = 1.0 / ppp
            inv_home = 1.0 / self.home_size

            smart = out[self._raw_size:]
            smart[0] = our_pip * inv_pip
            smart[1] = their_pip * inv_pip
            smart[2] = our_blots * inv_ppp
            smart[3] = their_blots * inv_ppp
            smart[4] = our_held * inv_ppp
            smart[5] = their_held * inv_ppp
            smart[6] = our_pinned * inv_ppp
            smart[7] = their_pinned * inv_ppp
            smart[8] = our_in_our_home * inv_ppp
            smart[9] = their_in_their_home * inv_ppp
            smart[10] = our_in_their_home * inv_ppp
            smart[11] = their_in_our_home * inv_ppp
            smart[12] = our_borne * inv_ppp
            smart[13] = their_borne * inv_ppp
            smart[14] = our_max_prime * inv_home
            smart[15] = their_max_prime * inv_home
            smart[16] = (our_pip - their_pip) * inv_pip
            smart[17] = (our_borne - their_borne) * inv_ppp

        return out
