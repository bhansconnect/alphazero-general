# cython: language_level=3

import pyximport; pyximport.install()

from alphazero.Game import GameState
from hnefatafl.engine import Board, Move, PieceType, variants
from typing import List, Tuple, Any

import numpy as np


MAX_REPEATS = 3  # N-fold repetition loss


def _get_board():
    return Board(GAME_VARIANT, max_repeats=MAX_REPEATS, _store_past_states=False)


GAME_VARIANT = variants.hnefatafl
b = _get_board()
ACTION_SIZE = b.width * b.height * (b.width + b.height - 2)

NUM_PLAYERS = 2
PLAYERS = list(range(NUM_PLAYERS))

NUM_STACKED_OBSERVATIONS = 0
NUM_BASE_CHANNELS = 5
NUM_CHANNELS = NUM_BASE_CHANNELS * (NUM_STACKED_OBSERVATIONS + 1)
OBS_SIZE = (NUM_CHANNELS, b.width, b.height)
del b

DRAW_MOVE_COUNT = 200
# Used for checking pairs of moves from same player
# Changing this breaks repeat check
_ONE_MOVE = 2
_TWO_MOVES = _ONE_MOVE * 2


def _board_from_numpy(np_board: np.ndarray) -> Board:
    return Board(custom_board='\n'.join([''.join([str(i) for i in row]) for row in np_board]))


def _board_to_numpy(board: Board) -> np.ndarray:
    return np.array([[int(tile) for tile in row] for row in board])


def get_move(board: Board, action: int) -> Move:
    size = (board.width + board.height - 2)
    move_type = action % size
    a = action // size
    start_x = a % board.width
    start_y = a // board.width

    if move_type < board.height - 1:
        new_x = start_x
        new_y = move_type
        if move_type >= start_y: new_y += 1
    else:
        new_x = move_type - board.height + 1
        if new_x >= start_x: new_x += 1
        new_y = start_y

    return Move(board, int(start_x), int(start_y), int(new_x), int(new_y), _check_in_bounds=False)


def get_action(board: Board, move: Move) -> int:
    new_x = move.new_tile.x
    new_y = move.new_tile.y

    if move.is_vertical:
        move_type = new_y if new_y < move.tile.y else new_y - 1
    else:
        move_type = board.height + new_x - 1
        if new_x >= move.tile.x: move_type -= 1

    return (board.width + board.height - 2) * (move.tile.x + move.tile.y * board.width) + move_type


def _get_observation(board: Board, player_turn: int, const_max_player: int, const_max_turns: int, past_obs: int = 1):
    obs = []

    def add_obs(b, turn_num):
        game_board = _board_to_numpy(b)
        black = np.where(game_board == PieceType.black.value, 1., 0.)
        white = np.where((game_board == PieceType.white.value) | (game_board == PieceType.king.value), 1., 0.)
        king = np.where(game_board == PieceType.king.value, 1., 0.)
        turn_colour = np.full_like(
            game_board,
            player_turn / (const_max_player - 1) if const_max_player > 1 else 0
        )
        turn_number = np.full_like(game_board, turn_num / const_max_turns if const_max_turns else 0, dtype=np.float32)
        obs.extend([black, white, king, turn_colour, turn_number])

    def add_empty():
        obs.extend([[[0]*board.width]*board.height]*NUM_BASE_CHANNELS)

    if board._store_past_states:
        past = board._past_states.copy()
        past.append((board, None))
        past_len = len(past)
        for i in range(past_obs):
            if past_len < i + 1:
                add_empty()
            else:
                add_obs(past[i][0], past_len-i-1)
    else:
        add_obs(board, board.num_turns)

    return np.array(obs, dtype=np.float32)


class TaflGame(GameState):
    def __init__(self):
        super().__init__(_get_board())

    def __eq__(self, other: 'TaflGame') -> bool:
        return self.__dict__ == other.__dict__

    @staticmethod
    def _get_piece_type(player: int) -> PieceType:
        return PieceType.black if player == 1 else PieceType.white

    @staticmethod
    def _get_player_int(player: PieceType) -> int:
        return [1, -1][2 - player.value]

    def clone(self) -> 'GameState':
        g = TaflGame()
        g._board = self._board.copy()
        g._player = self._player
        return g

    @staticmethod
    def action_size() -> int:
        return ACTION_SIZE

    @staticmethod
    def observation_size() -> Tuple[int, int, int]:
        return OBS_SIZE

    def valid_moves(self):
        valids = [0] * self.action_size()
        legal_moves = self._board.all_valid_moves(self._get_piece_type(self.current_player()))

        for move in legal_moves:
            valids[get_action(self._board, move)] = 1

        return np.array(valids, dtype=np.intc)

    def play_action(self, action: int) -> None:
        move = get_move(self._board, action)
        self._board.move(move, _check_game_end=False, _check_valid=False)
        self._player *= -1

    def win_state(self) -> Tuple[bool, int]:
        # Check if maximum moves have been exceeded
        if self._board.num_turns >= DRAW_MOVE_COUNT:
            return True, 0

        winner = self._board.get_winner()
        if not winner: return False, 0

        winner = self._get_player_int(winner)
        reward = int(winner == self.current_player())
        reward -= int(winner == -1*self.current_player())

        return True, reward

    def observation(self):
        return _get_observation(
            self._board,
            0 if self.current_player() == 1 else 1,
            NUM_PLAYERS,
            DRAW_MOVE_COUNT,
            NUM_STACKED_OBSERVATIONS + 1
        )

    def symmetries(self, pi: np.ndarray) -> List[Tuple[Any, int]]:
        action_size = self.action_size()
        assert (len(pi) == action_size)
        syms = [None] * 8

        for i in range(1, 5):
            for flip in (False, True):
                state = np.rot90(np.array(self._board), i)
                if flip:
                    state = np.fliplr(state)

                num_past_states = min(
                    NUM_STACKED_OBSERVATIONS,
                    len(self._board._past_states) if self._board._store_past_states else 0
                )
                past_states = [None] * num_past_states
                for idx in range(num_past_states):
                    past = self._board._past_states[idx]
                    b = np.rot90(np.array(past[0]._board), i)
                    if flip:
                        b = np.fliplr(b)
                    past_states[idx] = (self._board.copy(store_past_states=False, state=b.tolist()), past[1])

                new_b = self._board.copy(
                    store_past_states=self._board._store_past_states,
                    state=state.tolist(),
                    past_states=past_states
                )

                new_pi = [0] * action_size
                for action, prob in enumerate(pi):
                    move = get_move(self._board, action)

                    x = move.tile.x
                    new_x = move.new_tile.x
                    y = move.tile.y
                    new_y = move.new_tile.y

                    for _ in range(i):
                        temp_x = x
                        temp_new_x = new_x
                        x = self._board.width - 1 - y
                        new_x = self._board.width - 1 - new_y
                        y = temp_x
                        new_y = temp_new_x
                    if flip:
                        x = self._board.width - 1 - x
                        new_x = self._board.width - 1 - new_x

                    move = Move(new_b, x, y, new_x, new_y)
                    new_action = get_action(new_b, move)
                    new_pi[new_action] = prob

                new_state = self.clone()
                new_state._board = new_b
                syms[(i - 1) * 2 + int(flip)] = (new_state, np.array(new_pi, dtype=np.float32))

        return syms

    def crude_value(self) -> int:
        _, result = self.win_state()
        white_pieces = len(list(filter(lambda p: p.is_white, self._board.pieces)))
        black_pieces = len(list(filter(lambda p: p.is_black, self._board.pieces)))
        return self.current_player() * (1000 * result + black_pieces - white_pieces)


if __name__ == '__main__':
    from hnefatafl.engine import *

    g = TaflGame(variants.brandubh)
    # g.board[0][0].piece = Piece(PieceType(3), 0, 0, 0)
    board = g.getInitBoard()
    for _ in range(6):
        board.move(Move(board, 3, 0, 2, 0))
        board.move(Move(board, 3, 2, 2, 2))
        board.move(Move(board, 2, 0, 3, 0))
        board.move(Move(board, 2, 2, 3, 2))
    print(g.getGameEnded(board, 0), g.getGameEnded(board, 1))
