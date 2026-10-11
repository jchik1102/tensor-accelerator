import re
import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path
import numpy as np
from .numeric import matrix
from .model import run_batch
from .vectors import Writer
from .preprocessing import normalize

ROOT=Path(__file__).resolve().parents[2]

def preprocess(pixels, width, height):
    if type(width) is not int or type(height) is not int or not 1<=width<=512 or not 1<=height<=512:
        raise ValueError('invalid image dimensions')
    if len(pixels)!=width*height or any(type(x) is not int or not 0<=x<=255 for x in pixels):
        raise ValueError('pixels must be grayscale integers in [0,255]')
    gray=normalize(np.asarray(pixels,dtype=np.uint8).reshape(height,width))
    if not gray.any():
        raise ValueError('Draw a digit before running inference')
    quantized=np.rint(gray.astype(np.float64)*127/255).astype(np.int8)
    return quantized.reshape(-1).tolist(),gray.reshape(-1).tolist()

def reference(artifact, inputs):
    value=[inputs];layers=[]
    for layer in artifact['layers']:
        value,_=matrix(value,layer['weights'],layer['bias'],layer['multipliers'],layer['shifts'],layer['relu'])
        layers.append(value[0])
    return layers

def write_inference_plan(artifact, inputs, path):
    w=Writer(path);w.cmd('Z');w.read(0,0x54413031)
    wb=pb=src=0;dst=len(inputs);offsets=[]
    for index,layer in enumerate(artifact['layers']):
        k,n=len(layer['weights'][0]),len(layer['weights'])
        w.bytes(0x20000+4*wb,sum(layer['weights'],[]));w.params(pb,layer['bias'],layer['multipliers'],layer['shifts'])
        w.desc(index,[1,k,n,src,dst,wb,pb,int(layer['relu'])]);offsets.append((dst,n))
        wb+=k*n;pb+=n;src=dst;dst+=n
    w.bytes(0x10000,inputs);w.write(12,len(artifact['layers']));w.write(8,1);w.cmd('P',4,2);w.cmd('T')
    for offset,n in offsets:
        for j in range(n):w.cmd('O',0x10000+4*(offset+j))
    w.file.close()
    return offsets

def windows_path(path):
    text=str(path.resolve())
    if text.startswith('/mnt/c/'):
        return 'C:/'+text[7:]
    raise RuntimeError('Native XSim backend requires the documented WSL project path')

def predict(artifact, inputs, backend='software', board=None):
    started=time.perf_counter()
    expected=reference(artifact,inputs)
    reference_ms=round((time.perf_counter()-started)*1000,3)
    cycles=None
    timings={}
    if backend=='software':
        _,batch_layers=run_batch(artifact,[inputs])
        actual=[x[0].tolist() for x in batch_layers]
        label='CPU software (independent scalar check)'
    elif backend=='rtl':
        run=ROOT/'artifacts/demo-sim'/uuid.uuid4().hex
        run.mkdir(parents=True)
        vector,log=run/'input.txt',run/'xsim.log'
        offsets=write_inference_plan(artifact,inputs,vector)

        shell=os.environ.get('TA_POWERSHELL') or shutil.which('pwsh.exe') or '/mnt/c/Users/jonat/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
        process=subprocess.run([shell,'-NoProfile','-File',windows_path(ROOT/'scripts/run-demo-sim.ps1'),
            '-Vectors',windows_path(vector),'-Log',windows_path(log)],timeout=180,capture_output=True)
        (run/'launcher.log').write_bytes(process.stdout+process.stderr)
        if process.returncode:
            print(f'RTL launch failed; see {log}',flush=True)
            raise RuntimeError('RTL simulator failed. See the server log for details.')
        text=log.read_text(encoding='utf-8-sig')
        if 'CORE_PASS' not in text or 'Fatal:' in text:raise RuntimeError('RTL run failed; inspect '+str(log))
        readback={int(a,16):int(v,16) for a,v in re.findall(r'READBACK ([0-9a-fA-F]+) ([0-9a-fA-F]+)',text)}
        actual=[]
        for offset,n in offsets:
            values=[]
            for j in range(n):
                v=readback[0x10000+4*(offset+j)] & 255
                values.append(v-256 if v>=128 else v)
            actual.append(values)
        cycles=int(re.search(r'COMPUTE_CYCLES (\d+)',text)[1])
        label='Native XSim RTL simulation'
    elif backend=='fpga':
        if board is None:raise ValueError('Start the server with --fpga-master and the verified master path')
        actual,cycles,timings=board.infer(inputs)
        label='Physical DE10-Lite FPGA'
    else:raise ValueError('Choose software, rtl or fpga')
    if actual!=expected:
        if backend=='fpga':board.invalidate('Independent integer check failed')
        raise RuntimeError('Independent integer check failed')
    timings['reference_ms']=reference_ms
    prediction=int(np.argmax(actual[-1]))
    if backend=='fpga':
        board.display(prediction)
    return {'prediction':prediction,'scores':actual[-1], 'backend':label,
            'hex_display_updated':backend=='fpga',
            'exact_match':True,'layers_checked':len(actual),'compute_cycles':cycles,
            'elapsed_seconds':round(time.perf_counter()-started,3), 'physical_fpga':backend=='fpga',
            'timings':timings}
