# cython: language_level=3

from alphazero.Game import GameState
from alphazero.GenericPlayers import BasePlayer
from alphazero.SelfPlayAgent import SelfPlayAgent, get_game_results
from alphazero.pytorch_classification.utils import Bar, AverageMeter
from alphazero.utils import dotdict

from typing import Callable, List, Tuple
from queue import Empty
from time import time

import torch.multiprocessing as mp
import torch
import random


class _PlayerWrapper:
    def __init__(self, player, index):
        self.player = player
        self.index = index
        self.wins = 0
        self.winrate = 0

    def __call__(self, *args, **kwargs):
        return self.player(*args, **kwargs)

    def update(self, *args, **kwargs):
        self.player.update(*args, **kwargs)

    def reset(self):
        self.player.reset()

    def reset_wins(self):
        self.wins = 0
        self.winrate = 0

    def add_win(self):
        self.wins += 1

    def update_winrate(self, draws, num_games):
        if not num_games:
            self.winrate = 0
        else:
            self.winrate = (self.wins + 0.5 * draws) / num_games


class Arena:
    """
    An Arena class where any game's agents can be pit against each other.
    """

    def __init__(
            self,
            players: List[BasePlayer],
            game_cls,
            use_batched_mcts=True,
            display: Callable = None,
            args: dotdict = None
    ):
        """
        Input:
            player 1,2: two functions that takes board as input, return action
            game: Game object
            display: a function that takes board as input and prints it (e.g.
                     display in othello/OthelloGame). Is necessary for verbose
                     mode.

        see othello/OthelloPlayers.py for an example. See pit.py for pitting
        human players/other baselines with each other.
        """
        num_players = len(game_cls.get_players())
        if len(players) != num_players:
            raise ValueError('Argument `players` must have the same amount of players as the game supports. '
                             f'Got {len(players)} player agents, while the game requires {num_players}')

        self.__players = None
        self.players = players
        self.game_cls = game_cls
        self.use_batched_mcts = use_batched_mcts
        self.display = display
        self.args = args.copy()
        self.draws = 0
        self.winrates = []

    @property
    def players(self):
        return self.__players

    @players.setter
    def players(self, value):
        self.__players = value
        self.__init_players()

    def __init_players(self):
        new_players = []
        for i, player in enumerate(self.__players):
            if not isinstance(player, _PlayerWrapper):
                player = _PlayerWrapper(player, i)
            new_players.append(player)
        self.__players = new_players

    def __reset_counts(self):
        self.draws = 0
        self.winrates = []
        [player.reset_wins() for player in self.players]

    def __update_winrates(self, num_games):
        [player.update_winrate(self.draws, num_games) for player in self.players]
        self.winrates = [player.winrate for player in sorted(self.players, key=lambda p: p.index)]

    def play_game(self, verbose=False, _player_to_index: dict = None) -> Tuple[GameState, int]:
        """
        Executes one episode of a game.

        Returns:
            state: the last state in the game
            result: the value of the game result (based on last state)
        """
        if verbose: assert self.display

        # Reset the state of the players if needed
        [p.reset() for p in self.players]

        state = self.game_cls()
        turns = 0

        while True:
            if verbose:
                print("Turn ", str(turns), "Player ", str(state.current_player()))
                self.display(state)

            index = state.current_player() if not _player_to_index else _player_to_index[state.current_player()]
            action = self.players[index](state, turns)

            # valids = state.valid_moves()
            # assert valids[action] > 0, ' '.join(map(str, [action, index, state.current_player(), turns, valids]))

            [p.update(state, action) for p in self.players]
            state.play_action(action)
            game_over, value = state.win_state()
            turns += 1

            if game_over:
                if verbose:
                    print("Game over: Turn ", str(turns), "Result ", str(value))
                    self.display(state)

                return state, value

    def play_games(self, num, verbose=False) -> Tuple[List[int], int, List[int]]:
        """
        Plays num games in which the order of the players
        is randomized for each game. The order is simply switched
        if there are only two players.

        Returns:
            wins: number of wins for each player in self.players
            draws: number of draws that occurred in total
            winrates: the win rates for each player in self.players
        """
        eps_time = AverageMeter()
        bar = Bar('Arena.play_games', max=num)
        end = time()
        self.__reset_counts()

        players = self.game_cls.get_players().copy()

        def get_player_order() -> dict:
            if len(players) == 2:
                players.reverse()
            else:
                random.shuffle(players)
            return {p: i for i, p in enumerate(players)}

        if self.use_batched_mcts:
            self.args.gamesPerIteration = num
            agents = []
            policy_tensors = []
            value_tensors = []
            batch_ready = []
            batch_queues = []
            stop_agents = mp.Event()
            ready_queue = mp.Queue()
            result_queue = mp.Queue()
            completed = mp.Value('i', 0)
            games_played = mp.Value('i', 0)

            self.args.expertValueWeight.current = self.args.expertValueWeight.start
            # if self.args.workers >= mp.cpu_count():
            #    self.args.workers = mp.cpu_count() - 1

            for i in range(self.args.workers):
                player_to_index = get_player_order()
                input_tensors = [[] for _ in player_to_index]
                batch_queues.append(mp.Queue())

                policy_tensors.append(torch.zeros(
                    [self.args.arena_batch_size, self.game_cls.action_size()]
                ))
                policy_tensors[i].pin_memory()
                policy_tensors[i].share_memory_()

                value_tensors.append(torch.zeros([self.args.arena_batch_size, 1]))
                value_tensors[i].pin_memory()
                value_tensors[i].share_memory_()

                batch_ready.append(mp.Event())

                agents.append(
                    SelfPlayAgent(i, self.game_cls, ready_queue, batch_ready[i],
                                  input_tensors, policy_tensors[i], value_tensors[i], batch_queues[i],
                                  result_queue, completed, games_played, stop_agents, self.args,
                                  _is_arena=True, _player_order=player_to_index.copy()))
                agents[i].daemon = True
                agents[i].start()

            sample_time = AverageMeter()
            end = time()

            n = 0
            while completed.value != self.args.workers:
                try:
                    id = ready_queue.get(timeout=1)

                    policy = []
                    value = []
                    data = batch_queues[id].get()
                    for player in range(len(self.players)):
                        batch = data[player]
                        if isinstance(batch, torch.Tensor):
                            p, v = self.players[player](batch)
                            policy.append(p)
                            value.append(v)

                    policy_tensors[id].copy_(torch.cat(policy))
                    value_tensors[id].copy_(torch.cat(value))
                    batch_ready[id].set()
                except Empty:
                    pass

                size = games_played.value
                if size > n:
                    sample_time.update((time() - end) / (size - n), size - n)
                    n = size
                    end = time()

                wins, draws = get_game_results(
                    result_queue,
                    self.game_cls,
                    _get_index=lambda p, i: agents[i].player_to_index[p]
                )
                for i, w in enumerate(wins):
                    self.players[i].wins += w
                self.draws += draws
                self.__update_winrates(sum([player.wins for player in self.players]) + self.draws)

                bar.suffix = '({eps}/{maxeps}) Winrates: {wr} | Eps Time: {et:.3f}s | Total: {total:} | ETA: {eta:}' \
                    .format(
                        eps=size, maxeps=num, et=sample_time.avg, total=bar.elapsed_td, eta=bar.eta_td,
                        wr=[round(w, 2) for w in self.winrates]
                    )
                bar.goto(size)

            stop_agents.set()
            bar.update()
            bar.finish()

            for agent in agents:
                agent.join()
                del policy_tensors[0]
                del value_tensors[0]
                del batch_ready[0]

        else:
            for eps in range(1, num + 1):
                # Get a new lookup for self.players, randomized or reversed from original
                player_to_index = get_player_order()

                # Play a single game with the current player order
                _, value = self.play_game(verbose, player_to_index)

                # Bookkeeping + plot progress
                if value != 0:
                    self.players[player_to_index[value]].add_win()
                else:
                    self.draws += 1

                self.__update_winrates(eps)
                eps_time.update(time() - end)
                end = time()
                bar.suffix = '({eps}/{maxeps}) Winrates: {wr} | Eps Time: {et:.3f}s | Total: {total:} | ETA: {eta:}' \
                    .format(
                        eps=eps, maxeps=num, et=eps_time.avg, total=bar.elapsed_td, eta=bar.eta_td,
                        wr=[round(w, 2) for w in self.winrates]
                    )
                bar.next()

            bar.update()
            bar.finish()

        wins = [player.wins for player in sorted(self.players, key=lambda p: p.index)]

        return wins, self.draws, self.winrates
