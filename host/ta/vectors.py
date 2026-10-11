import json
import random
from pathlib import Path
import numpy as np
from .numeric import matrix, requantize
from .model import load

ROOT = Path(__file__).resolve().parents[2]

class Writer:
    def __init__(self, path):
        self.file = path.open('w')
    def cmd(self, op, a=0, b=0, c=0, d=0):
        self.file.write(f'{op} {a & 0xffffffff:08x} {b & 0xffffffff:08x} {c & 0xffffffff:08x} {d & 0xffffffff:08x}\n')
    def write(self, addr, value, error=0): self.cmd('W', addr, int(value), error)
    def read(self, addr, value, error=0): self.cmd('R', addr, int(value), error)
    def desc(self, index, values):
        for i, value in enumerate(values): self.write(0x100+32*index+4*i, value)
    def bytes(self, base, values):
        for i, value in enumerate(values): self.write(base+4*i, value)
    def params(self, base, bias, mult, shifts):
        for j, params in enumerate(zip(bias, mult, shifts)):
            for i, value in enumerate(params): self.write(0x1000+12*(base+j)+4*i, value)

def main():
    dest = ROOT / 'artifacts/vectors'
    dest.mkdir(parents=True, exist_ok=True)
    rng = random.Random(20261008)
    w = Writer(dest / 'core.txt')
    w.cmd('Z'); w.read(0, 0x54413031); w.read(4, 0)
    w.read(3,0,1); w.read(16,1); w.write(8,2)
    w.write(0,7,1); w.read(16,1); w.write(8,2)
    w.read(0x90000,0,1); w.write(8,2)
    cases = [(1,1,1),(2,3,3),(4,4,4),(5,7,6),(7,9,5),(3,16,9),(1,1024,3),(8,5,8),(32,1,128)]
    cases += [(r,17,16-r) for r in range(1,16)]
    for case, (m,k,n) in enumerate(cases):
        inputs = [[rng.randint(-128,127) for _ in range(k)] for _ in range(m)]
        weights = [[rng.randint(-128,127) for _ in range(k)] for _ in range(n)]
        inputs[0][0] = -128; weights[0][0] = 127
        bias = [rng.randint(-400,400) for _ in range(n)]
        mult, shifts = [rng.randint(1,32767) for _ in range(n)], [rng.randint(15,23) for _ in range(n)]
        relu = bool(case % 2)
        output, acc = matrix(inputs, weights, bias, mult, shifts, relu)
        w.cmd('C',m,k,n,int(relu)); w.write(8,2)
        w.bytes(0x10000, sum(inputs,[])); w.bytes(0x20000, sum(weights,[]));w.params(0,bias,mult,shifts)
        w.desc(0,[m,k,n,0,4096,0,0,int(relu)]); w.write(12,1);w.write(8,1)
        if case==3:
            w.write(8,1,1); w.write(0x10000,42,1); w.read(0x10000,0,1)
            w.cmd('P',4,6); w.read(16,2)
        else: w.cmd('P',4,2)
        w.cmd('T')
        for j, (o,a) in enumerate(zip(sum(output,[]),sum(acc,[]))):
            w.read(0x10000+4*(4096+j),o);w.read(0x60000+4*j,a)
    
    for ao in range(8):
        for wo in range(8):
            m,k,n=2+(ao%3),9+wo,3+(wo%7)
            src,dst,wb,pb=ao,4096+wo,wo,ao
            aa=[[rng.randint(-128,127) for _ in range(k)] for _ in range(m)]
            bb=[[rng.randint(-128,127) for _ in range(k)] for _ in range(n)]
            bias=[rng.randint(-20,20) for _ in range(n)]
            out,acc=matrix(aa,bb,bias,[1]*n,[8]*n,False)
            w.write(8,2);w.bytes(0x10000+src*4,sum(aa,[]));w.bytes(0x20000+wb*4,sum(bb,[]))
            w.params(pb,bias,[1]*n,[8]*n);w.desc(0,[m,k,n,src,dst,wb,pb,0]);w.write(8,1);w.cmd('P',4,2)
            for j,(o,a) in enumerate(zip(sum(out,[]),sum(acc,[]))):
                w.read(0x10000+4*(dst+j),o);w.read(0x60000+4*j,a)

    for m,k,n,src,dst,wb,pb in [(1,7,1,8185,0,65529,1023),(32,1,128,0,4096,65408,896)]:
        aa=[[-128]*k for _ in range(m)];bb=[[127]*k for _ in range(n)]
        out,acc=matrix(aa,bb,[0]*n,[1]*n,[8]*n,False)
        w.write(8,2);w.bytes(0x10000+src*4,sum(aa,[]));w.bytes(0x20000+wb*4,sum(bb,[]));w.params(pb,[0]*n,[1]*n,[8]*n)
        w.desc(0,[m,k,n,src,dst,wb,pb,0]);w.write(8,1);w.cmd('P',4,2)
        for j,(o,a) in enumerate(zip(sum(out,[]),sum(acc,[]))):
            w.read(0x10000+4*(dst+j),o);w.read(0x60000+4*j,a)
    
    for index,value in [(0,0),(1,1025),(2,129),(3,8192),(4,0),(5,65536),(6,1024),(7,2)]:
        w.write(8,2);w.desc(0,[1,1,1,0,4096,0,0,0]);w.write(0x100+4*index,value)
        w.write(8,1);w.cmd('P',4,4);w.read(16,3)
    for index,value in [(0,0x7fffffff),(0,0x80000000),(1,0),(1,0x80000000),(2,63)]:
        w.write(8,2);w.desc(0,[1,1,1,0,4096,0,0,0]);w.params(0,[0],[1],[0]);w.write(0x1000+4*index,value)
        w.write(8,1);w.cmd('P',4,4);w.read(16,4)
    
    w.write(8,2);w.params(0,[0],[1],[0]);w.desc(0,[1,1024,1,0,4096,0,0,0]);w.write(8,1)
    w.cmd('D',30);w.write(8,4);w.read(4,0);w.read(12,0);w.read(0x100,0)
    w.cmd('D',100);w.read(4,0)
    w.desc(0,[1,1,1,0,4096,0,0,0]);w.bytes(0x10000,[-3]);w.bytes(0x20000,[1]);w.params(0,[0],[1],[1]);w.write(12,1)
    w.write(8,1);w.cmd('P',4,2);w.read(0x14000,-2);w.read(0x60000,-3)
    w.write(8,1,1);w.read(16,3);w.cmd('Z');w.read(4,0)
    
    for state in [4,6,8,15,17]:
        w.desc(0,[1,1,1,0,4096,0,0,0]);w.bytes(0x10000,[-3]);w.bytes(0x20000,[1]);w.params(0,[0],[1],[1]);w.write(12,1)
        w.write(8,1);w.cmd('H',state);w.read(4,0);w.read(12,0);w.cmd('D',30);w.read(4,0)
    
    model = load(ROOT / 'artifacts/model/model.json')
    samples = np.load(ROOT / 'artifacts/model/samples.npz')
    wb=pb=0;src=0;dst=784
    offsets=[]
    for index, layer in enumerate(model['layers']):
        k,n=len(layer['weights'][0]),len(layer['weights'])
        w.bytes(0x20000+4*wb,sum(layer['weights'],[]));w.params(pb,layer['bias'],layer['multipliers'],layer['shifts'])
        w.desc(index,[1,k,n,src,dst,wb,pb,int(layer['relu'])]);offsets.append(dst)
        wb+=k*n;pb+=n;src=dst;dst+=n
    w.write(12,3)
    for sample in range(8):
        value = [samples['inputs'][sample].tolist()]
        w.write(8,2);w.bytes(0x10000,value[0]);w.write(8,1);w.cmd('P',4,2);w.cmd('T')
        for index,layer in enumerate(model['layers']):
            value,acc=matrix(value,layer['weights'],layer['bias'],layer['multipliers'],layer['shifts'],layer['relu'])
            for j, v in enumerate(value[0]):w.read(0x10000+4*(offsets[index]+j),v)
        for j,a in enumerate(acc[0]):w.read(0x60000+4*j,a)
    w.file.close()
    with (dest/'quant.txt').open('w') as f:
        count=0
        values=[-(1<<31),-2147467263,-1000,-257,-255,-129,-128,-127,-7,-5,-3,-1,0,1,3,5,7,127,128,255,257,1000,(1<<31)-1]
        for value in values:
            for mult in [1,3,127,65537,2147483647]:
                for shift in [0,1,2,7,15,31,32,61,62]:
                    for relu in [False,True]:
                        result=requantize(value,mult,shift,relu)
                        f.write(f'{value & 0xffffffff:08x} {mult:08x} {shift:08x} {int(relu):08x} {result & 255:02x}\n');count+=1
    (dest/'manifest.json').write_text(json.dumps({'seed':20261008,'matrix_cases':cases,'bank_rotation_cases':64,'boundary_cases':2,'trained_samples':8,'requantization_cases':count},indent=2))

if __name__=='__main__':main()
