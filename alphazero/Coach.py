from alphazero.SelfPlayAgent import SelfPlayAgent, get_game_results
from alphazero.utils import get_iter_file, dotdict
from alphazero.Arena import Arena
from alphazero.GenericPlayers import RandomPlayer, NNPlayer, MCTSPlayer
from alphazero.pytorch_classification.utils import Bar, AverageMeter

from glob import glob
from torch import multiprocessing as mp
from torch.utils.data import TensorDataset, ConcatDataset, DataLoader
from tensorboardX import SummaryWriter
from queue import Empty

import numpy as np
import torch
import time
import os
import atexit


DEFAULT_ARGS = dotdict({
    'run_name': 'boardgame',
    'cuda': torch.cuda.is_available(),
    'workers': mp.cpu_count() - 1,
    'startIter': 0,
    'numIters': 1000,
    'process_batch_size': 64,
    'train_batch_size': 512,
    'arena_batch_size': 32,
    'train_steps_per_iteration': 256,
    # should preferably be a multiple of process_batch_size and workers
    'gamesPerIteration': 64*mp.cpu_count(),
    'numItersForTrainExamplesHistory': 10,
    'max_moves': 128,
    'num_stacked_observations': 8,
    'numWarmupIters': 2,  # Iterations where games are played randomly, 0 for none
    'skipSelfPlayIters': 0,
    'symmetricSamples': True,
    'numMCTSSims': 75,
    'numFastSims': 15,
    'numWarmupSims': 50,
    'probFastSim': 0.75,
    'mctsResetThreshold': None,
    'tempThreshold': 32,
    'temp': 1,
    'compareWithBaseline': True,
    'baselineTester': RandomPlayer,
    'arenaCompareBaseline': 16,
    'arenaCompare': 128,
    'arenaTemp': 0.1,
    'arenaMCTS': True,
    'arenaBatched': True,
    'baselineCompareFreq': 1,
    'compareWithPast': True,
    'pastCompareFreq': 1,
    'model_gating': True,
    'max_gating_iters': 3,
    'min_next_model_winrate': 0.52,
    'sample_save_interval': 30,
    'expertValueWeight': dotdict({
        'start': 0,
        'end': 0,
        'iterations': 35
    }),
    'load_model': True,
    'cpuct': 2,
    'checkpoint': 'checkpoint',
    'data': 'data',

    'lr': 0.005,
    'num_channels': 64,
    'depth': 8,
    'value_head_channels': 1,
    'policy_head_channels': 2,
    'value_dense_layers': [64],
    'policy_dense_layers': [256, 256]
})


def get_args(args=None, **kwargs):
    new_args = DEFAULT_ARGS
    if args:
        new_args.update(args)
    for key, value in kwargs.items():
        setattr(new_args, key, value)
    return new_args


class SampleSaver(mp.Process):
    def __init__(self, iteration: int, output_queue: mp.Queue, stop_event: mp.Event, game, args: dotdict):
        super().__init__()
        self.output_queue = output_queue
        self.stop_event = stop_event
        self.game = game
        self.save_interval = args.sample_save_interval
        self.num_samples = 0

        folder = args.data + '/' + args.run_name
        self.filename = folder + '/' + get_iter_file(iteration).replace('.pkl', '')
        if not os.path.exists(folder): os.makedirs(folder)

        self.file_objs = [open(f'{self.filename}-{name}.pkl', 'ab') for name in ('data', 'policy', 'value')]
        atexit.register(self.__del__)

    def __del__(self):
        [f.close() for f in self.file_objs]

    def run(self) -> None:
        while not self.stop_event.is_set():
            num_samples = self.output_queue.qsize()

            if num_samples:
                data_tensor = torch.zeros([num_samples, *self.game.getObservationSize()])
                policy_tensor = torch.zeros([num_samples, self.game.getActionSize()])
                value_tensor = torch.zeros([num_samples, 1])
                for i in range(num_samples):
                    data, policy, value = self.output_queue.get()
                    data_tensor[i] = torch.from_numpy(data.astype(np.float32))
                    policy_tensor[i] = torch.tensor(policy)
                    value_tensor[i, 0] = value

                torch.save(data_tensor, self.file_objs[0])
                torch.save(policy_tensor, self.file_objs[1])
                torch.save(value_tensor, self.file_objs[2])

                del data_tensor
                del policy_tensor
                del value_tensor

            time.sleep(self.save_interval)

        self.__del__()


class Coach:
    def __init__(self, game, nnet, args):
        np.random.seed()
        self.game = game
        self.nnet = nnet
        self.pnet = nnet.__class__(game, args)
        self.args = args

        if self.args.load_model:
            networks = sorted(glob(self.args.checkpoint + '/' + self.args.run_name + '/*'))
            self.args.startIter = len(networks)
            if self.args.startIter == 0:
                self.nnet.save_checkpoint(
                    folder=self.args.checkpoint + '/' + self.args.run_name, filename=get_iter_file(0))
                self.args.startIter = 1

            self.nnet.load_checkpoint(
                folder=self.args.checkpoint + '/' + self.args.run_name, filename=get_iter_file(self.args.startIter - 1))

        self.current_iter = self.args.startIter
        self.gating_counter = 0
        self.warmup = False
        self.saver_stop = mp.Event()
        self.sample_saver = None
        self.agents = []
        self.input_tensors = []
        self.policy_tensors = []
        self.value_tensors = []
        self.batch_ready = []
        self.ready_queue = mp.Queue()
        self.file_queue = mp.Queue()
        self.result_queue = mp.Queue()
        self.completed = mp.Value('i', 0)
        self.games_played = mp.Value('i', 0)
        if self.args.run_name != '':
            self.writer = SummaryWriter(log_dir='runs/' + self.args.run_name)
        else:
            self.writer = SummaryWriter()
        self.args.expertValueWeight.current = self.args.expertValueWeight.start

    def learn(self):
        print('Because of batching, it can take a long time before any games finish.')
        const_i = self.current_iter

        while self.current_iter <= self.args.numIters:
            i = self.current_iter
            print(f'------ITER {i}------')
            if const_i <= self.args.numWarmupIters:
                print('Warmup: random policy and value')
                self.warmup = True
            elif self.warmup:
                self.warmup = False

            if const_i > self.args.skipSelfPlayIters:
                self.generateSelfPlayAgents(i)
                self.processSelfPlayBatches()
                self.finishSaver()
                self.processGameResults(const_i)
                self.killSelfPlayAgents()
            self.train(i)

            if not self.warmup and self.args.compareWithBaseline and (const_i - 1) % self.args.baselineCompareFreq == 0:
                if const_i == 1:
                    print(
                        'Note: Comparisons against the tester do not use monte carlo tree search.'
                    )
                self.compareToBaseline(i)

            if not self.warmup and self.args.compareWithPast and (const_i - 1) % self.args.pastCompareFreq == 0:
                self.compareToPast(i)

            z = self.args.expertValueWeight
            self.args.expertValueWeight.current = min(
                const_i, z.iterations) / z.iterations * (z.end - z.start) + z.start

            self.writer.add_scalar('win_rate/model_version', self.current_iter, const_i)
            self.current_iter += 1
            const_i += 1
            print()

        self.writer.close()

    def generateSelfPlayAgents(self, iteration):
        self.saver_stop = mp.Event()
        self.sample_saver = SampleSaver(iteration, self.file_queue, self.saver_stop, self.game, self.args)
        self.sample_saver.daemon = True
        self.sample_saver.start()

        self.ready_queue = mp.Queue()
        for i in range(self.args.workers):
            self.input_tensors.append(torch.zeros(
                [self.args.process_batch_size, *self.game.getObservationSize()]
            ))
            self.input_tensors[i].pin_memory()
            self.input_tensors[i].share_memory_()

            self.policy_tensors.append(torch.zeros(
                [self.args.process_batch_size, self.game.getActionSize()]
            ))
            self.policy_tensors[i].pin_memory()
            self.policy_tensors[i].share_memory_()

            self.value_tensors.append(torch.zeros([self.args.process_batch_size, 1]))
            self.value_tensors[i].pin_memory()
            self.value_tensors[i].share_memory_()
            self.batch_ready.append(mp.Event())

            self.agents.append(
                SelfPlayAgent(i, self.game, self.ready_queue, self.batch_ready[i],
                              self.input_tensors[i], self.policy_tensors[i], self.value_tensors[i], self.file_queue,
                              self.result_queue, self.completed, self.games_played, self.args, _is_warmup=self.warmup)
            )
            self.agents[i].daemon = True
            self.agents[i].start()

    def processSelfPlayBatches(self):
        sample_time = AverageMeter()
        bar = Bar('Generating Samples', max=self.args.gamesPerIteration)
        end = time.time()

        n = 0
        while self.completed.value != self.args.workers:
            try:
                id = self.ready_queue.get(timeout=1)
                policy, value = self.nnet.process(self.input_tensors[id])
                self.policy_tensors[id].copy_(policy)
                self.value_tensors[id].copy_(value)
                self.batch_ready[id].set()
            except Empty:
                pass

            size = self.games_played.value
            if size > n:
                sample_time.update((time.time() - end) / (size - n), size - n)
                n = size
                end = time.time()
            bar.suffix = f'({size}/{self.args.gamesPerIteration}) Sample Time: {sample_time.avg:.3f}s | Total: {bar.elapsed_td} | ETA: {bar.eta_td:}'
            bar.goto(size)
        bar.update()
        bar.finish()
        print()

    def finishSaver(self):
        self.saver_stop.set()
        self.sample_saver.join()
        print(f'Saved {self.sample_saver.num_samples} samples for training')

    def processGameResults(self, iteration):
        num_games = self.result_queue.qsize()
        wins, draws = get_game_results(self.result_queue, self.game)

        for i in range(len(wins)):
            self.writer.add_scalar(f'win_rate/player{i}', (wins[i] + 0.5 * draws) / num_games, iteration)
        self.writer.add_scalar('win_rate/draws', draws / num_games, iteration)

    def killSelfPlayAgents(self):
        for i in range(self.args.workers):
            self.agents[i].join()
            del self.input_tensors[0]
            del self.policy_tensors[0]
            del self.value_tensors[0]
            del self.batch_ready[0]
        self.agents = []
        self.sample_saver = None
        self.input_tensors = []
        self.policy_tensors = []
        self.value_tensors = []
        self.batch_ready = []
        self.ready_queue = mp.Queue()
        self.completed = mp.Value('i', 0)
        self.games_played = mp.Value('i', 0)

    def train(self, iteration):
        datasets = []
        # currentHistorySize = self.args.numItersForTrainExamplesHistory
        currentHistorySize = min(
            max(4, (iteration + 4) // 2),
            self.args.numItersForTrainExamplesHistory
        )
        for i in range(max(1, iteration - currentHistorySize), iteration + 1):
            filename = self.args.data + '/' + self.args.run_name + '/' + get_iter_file(i).replace('.pkl', '')
            data_tensor = torch.load(filename + '-data.pkl')
            policy_tensor = torch.load(filename + '-policy.pkl')
            value_tensor = torch.load(filename + '-value.pkl')
            datasets.append(TensorDataset(
                data_tensor, policy_tensor, value_tensor))

        dataset = ConcatDataset(datasets)
        dataloader = DataLoader(dataset, batch_size=self.args.train_batch_size, shuffle=True,
                                num_workers=self.args.workers, pin_memory=True)

        l_pi, l_v = self.nnet.train(
            dataloader, self.args.train_steps_per_iteration)
        self.writer.add_scalar('loss/policy', l_pi, iteration)
        self.writer.add_scalar('loss/value', l_v, iteration)
        self.writer.add_scalar('loss/total', l_pi + l_v, iteration)

        self.nnet.save_checkpoint(folder=self.args.checkpoint + '/' + self.args.run_name, filename=get_iter_file(iteration))

        del dataloader
        del dataset
        del datasets

    def compareToPast(self, iteration):
        past = max(0, iteration - self.args.pastCompareFreq)
        self.pnet.load_checkpoint(folder=self.args.checkpoint + '/' + self.args.run_name, filename=get_iter_file(past))

        print(f'PITTING AGAINST ITERATION {past}')
        if self.args.arenaBatched:
            if not self.args.arenaMCTS:
                self.args.arenaMCTS = True
                raise UserWarning('Batched arena comparison is enabled which uses MCTS, but arena MCTS is set to False.'
                                  ' Ignoring this, and continuing with batched MCTS in arena.')

            nplayer = self.nnet.process
            pplayer = self.pnet.process
        else:
            cls = MCTSPlayer if self.args.arenaMCTS else NNPlayer
            new_player = cls(self.game, self.nnet, args=self.args)
            past_player = cls(self.game, self.pnet, args=self.args)
            nplayer = new_player.play
            pplayer = past_player.play

        players = [nplayer]
        players.extend([pplayer] * (len(self.game.getPlayers()) - 1))

        arena = Arena(players, self.game, use_batched_mcts=self.args.arenaBatched, args=self.args)
        wins, draws, winrates = arena.play_games(self.args.arenaCompare)
        winrate = winrates[0]

        print(f'NEW/PAST WINS : {wins[0]} / {sum(wins[1:])} ; DRAWS : {draws}\n')
        self.writer.add_scalar('win_rate/past', winrate, iteration)

        ### Model gating ###
        if (
            self.args.model_gating
            and winrate < self.args.min_next_model_winrate
            and self.args.max_gating_iters
            and self.gating_counter < self.args.max_gating_iters
        ):
            print(f'Staying on model version {past}')
            self.nnet.load_checkpoint(folder=self.args.checkpoint + '/' + self.args.run_name, filename=get_iter_file(past))
            os.remove(os.path.join(self.args.checkpoint + '/' + self.args.run_name, get_iter_file(iteration)))
            self.current_iter = past
            self.gating_counter += 1
        else:
            self.gating_counter = 0

    def compareToBaseline(self, iteration):
        test_player = self.args.baselineTester(self.game).play

        cls = MCTSPlayer if self.args.arenaMCTS else NNPlayer
        new_player = cls(self.game, self.nnet, args=self.args)
        nnplayer = new_player.play

        print('PITTING AGAINST TESTER: ' + self.args.baselineTester.__name__)

        players = [nnplayer]
        players.extend([test_player] * (len(self.game.getPlayers()) - 1))
        arena = Arena(players, self.game, use_batched_mcts=False, args=self.args)
        wins, draws, winrates = arena.play_games(self.args.arenaCompareBaseline)
        winrate = winrates[0]

        print(f'NEW/TESTER WINS : {wins[0]} / {sum(wins[1:])} ; DRAWS : {draws}\n')
        self.writer.add_scalar('win_rate/test', winrate, iteration)
