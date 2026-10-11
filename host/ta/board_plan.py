import argparse
from pathlib import Path
from .model import load
from .runtime import reference,write_inference_plan

def convert(vector_path, output_path, expected):
    lines=vector_path.read_text().splitlines()
    code=['if {![info exists env(TA_MASTER_PATH)] || ![info exists env(TA_BOARD_IMAGE_CONFIRMED)] || $env(TA_BOARD_IMAGE_CONFIRMED) ne "TA01"} {error "Confirmed TA01 image and explicit master path required"}',
          'if {[lsearch -exact [get_service_paths master] $env(TA_MASTER_PATH)] < 0} {error "Master path unavailable"}',
          'set h [claim_service master $env(TA_MASTER_PATH) tensor_accelerator_inference]',
          'try {',
          'if {[lindex [master_read_32 $h 0 1] 0] != 0x54413031} {error "Wrong image ID; no writes performed"}',
          'if {[lindex [master_read_32 $h 4 1] 0]&1} {error "Core busy; no writes performed"}']
    pending=[];base=0;layer=channel=0
    def flush():
        nonlocal pending
        if pending:
            code.append(f'master_write_32 $h 0x{base:x} '+'{'+' '.join(f'0x{x:08x}' for x in pending)+'}')
            pending=[]
    for line in lines:
        op,*parts=line.split();a,b,c,d=[int(x,16) for x in parts]
        if op=='W':
            if pending and (a!=base+4*len(pending) or len(pending)==256):flush()
            if not pending:base=a
            pending.append(b);continue
        flush()
        if op=='Z':code.append('master_write_32 $h 8 {4}')
        elif op=='R':code.append(f'if {{([lindex [master_read_32 $h 0x{a:x} 1] 0]&0xffffffff) != 0x{b:08x}}} {{error "Register mismatch"}}')
        elif op=='P':code.extend(['set deadline [expr {[clock milliseconds]+10000}]',
            'while {1} {set status [lindex [master_read_32 $h 4 1] 0]; if {!($status&1)} {break}; if {[clock milliseconds]>$deadline} {error "Inference timeout"}; after 1}',
            'if {$status != 2} {error "Inference status failure: $status"}'])
        elif op=='T':code.append('puts "FPGA_COMPUTE_CYCLES=[master_read_32 $h 20 1]"')
        elif op=='O':
            expected_byte=expected[layer][channel]&255
            code.extend([f'set value [expr {{[lindex [master_read_32 $h 0x{a:x} 1] 0]&255}}]',
                f'if {{$value != {expected_byte}}} {{error "Layer {layer} channel {channel} mismatch"}}'])
            channel+=1
            if channel==len(expected[layer]):
                code.append(f'puts "FPGA_LAYER_MATCH {layer}"');layer+=1;channel=0
        else:raise ValueError('unsupported hardware plan command')
    flush()
    code.extend(['puts "FPGA_INFERENCE_EXACT_MATCH"','} finally {close_service master $h}'])
    output_path.write_text('\n'.join(code)+'\n')

def main():
    import numpy as np
    root=Path(__file__).resolve().parents[2]
    parser=argparse.ArgumentParser()
    parser.add_argument('--sample',type=int,default=0)
    args=parser.parse_args()
    artifact=load(root/'artifacts/model/model.json')
    samples=np.load(root/'artifacts/model/samples.npz')
    inputs=samples['inputs'][args.sample].tolist()
    dest=root/'artifacts/board'
    dest.mkdir(parents=True,exist_ok=True)
    plan=dest/'inference-plan.txt'
    write_inference_plan(artifact,inputs,plan)
    output=dest/'inference.tcl'
    convert(plan,output,reference(artifact,inputs))
    print(f'Prepared {output}; not executed. Expected digit: {samples["labels"][args.sample]}')

if __name__=='__main__':main()
