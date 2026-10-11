import subprocess
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONSOLE = '/mnt/c/intelFPGA_lite/24.1std/quartus/sopc_builder/bin/system-console.exe'

def winpath(path):
    value = str(Path(path).resolve())
    if not value.startswith('/mnt/c/'):
        raise ValueError('The board backend requires the documented WSL project path')
    return 'C:/' + value[7:]

def tcl_literal(value):
    if any(c in value for c in '{}\\\r\n'):
        raise ValueError('Invalid Tcl configuration value')
    return '{' + value + '}'

def model_layout(artifact):
    
    blocks, descriptors, outputs = [], [], []
    inputs = len(artifact['layers'][0]['weights'][0])
    wb = pb = src = 0
    dst = inputs
    def add(address, values):
        values = [int(x) & 0xffffffff for x in values]
        for start in range(0, len(values), 256):
            blocks.append((address + 4 * start, values[start:start + 256]))
    for layer in artifact['layers']:
        n, k = len(layer['weights']), len(layer['weights'][0])
        add(0x20000 + 4 * wb, [x for row in layer['weights'] for x in row])
        add(0x1000 + 12 * pb, [x for p in zip(layer['bias'], layer['multipliers'], layer['shifts']) for x in p])
        descriptors.extend([1, k, n, src, dst, wb, pb, int(layer['relu'])])
        outputs.append((0x10000 + 4 * dst, n))
        wb += k * n
        pb += n
        src, dst = dst, dst + n
    add(0x100, descriptors)
    add(12, [len(outputs)])
    return inputs, blocks, descriptors, outputs

class BoardSession:
    def __init__(self, artifact, master_path, *, directory=None, command=None,
                 startup_timeout=180, request_timeout=30):
        tcl_literal(master_path)
        self.artifact, self.master_path = artifact, master_path
        self.directory = directory or ROOT/'artifacts/demo-board'/uuid.uuid4().hex
        self.directory.mkdir(parents=True, exist_ok=True)
        self.command = command
        self.startup_timeout, self.request_timeout = startup_timeout, request_timeout
        self.process = None
        self.log = None
        self.failure = None
        self.sequence = 0
        self.display_sequence = 0
        self.setup_seconds = 0
        self.load_ms = 0
        self.lock = threading.Lock()
        self.stop_heartbeat = threading.Event()
        self.heartbeat_thread = None
        self.input_count, self.blocks, self.descriptors, self.outputs = model_layout(artifact)

    def _atomic(self, name, text):
        dest = self.directory/name
        temp = dest.with_suffix('.tmp')
        temp.write_text(text, encoding='utf-8')
        temp.replace(dest)

    def _heartbeat(self):
        while not self.stop_heartbeat.wait(1):
            try:
                (self.directory/'heartbeat').touch()
            except OSError:
                return

    def _wait(self, name, timeout):
        deadline = time.monotonic() + timeout
        dest = self.directory/name
        while not dest.exists():
            if self.process.poll() is not None:
                
                if dest.exists():
                    break
                raise RuntimeError('System Console stopped; inspect ' + str(self.directory/'console.log'))
            if time.monotonic() >= deadline:
                raise TimeoutError('System Console response deadline exceeded')
            time.sleep(.01)
        return dest.read_text(encoding='utf-8').splitlines()

    def _start(self):
        started = time.perf_counter()
        model = self.directory/'model.txt'
        model.write_text('\n'.join(' '.join(map(str, [a] + words)) for a, words in self.blocks) + '\n')
        config = '\n'.join([
            'set ta_dir ' + tcl_literal(winpath(self.directory)),
            'set ta_master ' + tcl_literal(self.master_path),
            'set ta_input_count ' + str(self.input_count),
            'set ta_descriptors {' + ' '.join(map(str, self.descriptors)) + '}',
            'set ta_outputs {' + ' '.join('{%d %d}' % x for x in self.outputs) + '}',
            'source ' + tcl_literal(winpath(ROOT/'fpga/board/session.tcl')),
        ])
        launcher = self.directory/'launch.tcl'
        launcher.write_text(config + '\n')
        (self.directory/'heartbeat').touch()
        self.heartbeat_thread = threading.Thread(target=self._heartbeat, daemon=True)
        self.heartbeat_thread.start()
        self.log = (self.directory/'console.log').open('wb')
        command = self.command or [CONSOLE, '--cli', '--script=' + winpath(launcher)]
        
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=self.log, stderr=subprocess.STDOUT)
        ready = self._wait('ready.txt', self.startup_timeout)
        if len(ready) != 1 or not ready[0].startswith('READY '):
            raise RuntimeError('System Console initialization failed: ' + ' '.join(ready))
        self.load_ms = int(ready[0].split()[1])
        self.setup_seconds = time.perf_counter() - started

    def infer(self, inputs):
        if len(inputs) != self.input_count or any(type(x) is not int or not -128 <= x <= 127 for x in inputs):
            raise ValueError('Invalid signed INT8 input')
        with self.lock:
            if self.failure:
                raise RuntimeError('FPGA session unavailable: ' + self.failure + '. Restart the server after checking the board.')
            cold = self.process is None
            try:
                if cold:
                    self._start()
                self.sequence += 1
                seq = self.sequence
                response = self.directory/f'response-{seq}.txt'
                self._atomic('request.txt', ' '.join(map(str, [seq] + inputs)) + '\n')
                lines = self._wait(response.name, self.request_timeout)
                if len(lines) != len(self.outputs) + 3 or lines[0] != f'OK {seq}' or lines[-1] != f'END {seq}':
                    raise RuntimeError('Invalid board response: ' + ' '.join(lines)[:500])
                
                fields = lines[1].split()
                if len(fields) != 6 or fields[0] != 'METRICS':
                    raise RuntimeError('Missing board measurements')
                cycles, guard_ms, input_ms, execute_ms, read_ms = map(int, fields[1:])
                actual = []
                for index, (_, count) in enumerate(self.outputs):
                    row = lines[index + 2].split()
                    if row[:2] != ['LAYER', str(index)] or len(row) != count + 2:
                        raise RuntimeError('Incomplete FPGA layer readback')
                    words = [int(x) for x in row[2:]]
                    if any(not 0 <= x <= 0xffffffff for x in words):
                        raise RuntimeError('Invalid FPGA word')
                    actual.append([(x & 255) - 256 if x & 128 else x & 255 for x in words])
                metrics = dict(cold_start=cold, setup_seconds=round(self.setup_seconds if cold else 0, 3),
                               model_load_ms=self.load_ms if cold else 0, guard_ms=guard_ms,
                               input_transfer_ms=input_ms, compute_poll_ms=execute_ms, output_transfer_ms=read_ms)
                return actual, cycles, metrics
            except Exception as exc:
                self.invalidate(str(exc))
                raise

    def display(self, digit):
        
        if type(digit) is not int or digit not in (*range(10),255):
            raise ValueError('Invalid display digit')
        with self.lock:
            if self.failure or self.process is None:
                raise RuntimeError('FPGA display session unavailable')
            try:
                self.display_sequence += 1
                ticket = self.display_sequence
                self._atomic('display.txt', f'{ticket} {self.sequence} {digit}\n')
                lines = self._wait(f'display-{ticket}.txt', self.request_timeout)
                if lines != [f'DISPLAY {ticket} {self.sequence} {digit}']:
                    raise RuntimeError('HEX0 update failed: '+' '.join(lines))
            except Exception as exc:
                self.invalidate(str(exc))
                raise

    def clear_display(self):
        if self.process is not None and not self.failure:
            self.display(255)

    def invalidate(self, reason):
        self.failure = reason
        self.close()

    def close(self):
        self.stop_heartbeat.set()
        (self.directory/'stop').touch()
        if self.process:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            if self.process.stdin:
                self.process.stdin.close()
        if self.heartbeat_thread:
            self.heartbeat_thread.join(timeout=2)
        if self.log:
            self.log.close()
