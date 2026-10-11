import argparse
import json
import time
from http.server import BaseHTTPRequestHandler,HTTPServer
from pathlib import Path
import numpy as np
from .model import load
from .runtime import preprocess,predict
from .board_session import BoardSession
from .preprocessing import VERSION

ROOT=Path(__file__).resolve().parents[2]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--port',type=int,default=8765)
    parser.add_argument('--fpga-master',help='Explicit master path verified with the TA01 transfer test')
    parser.add_argument('--fpga-clock-mhz',type=int,choices=(50,60,65,75,100),default=50,
                        help='Clock in the loaded SOF; used only to convert measured cycles to time')
    args=parser.parse_args()
    artifact=load(ROOT/'artifacts/model/model.json')
    if artifact.get('preprocessing') != VERSION:
        raise ValueError('Model preprocessing version does not match the drawing server')
    board=BoardSession(artifact,args.fpga_master) if args.fpga_master else None
    class Handler(BaseHTTPRequestHandler):
        def send(self,status,body,kind='application/json'):
            data=json.dumps(body).encode() if kind=='application/json' else body
            self.send_response(status);self.send_header('Content-Type',kind)
            self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
        def do_GET(self):
            if self.path=='/':self.send(200,(ROOT/'demo/index.html').read_bytes(),'text/html; charset=utf-8')
            elif self.path=='/capabilities':self.send(200,{'fpga':bool(args.fpga_master)})
            elif self.path=='/sample':
                samples=np.load(ROOT/'artifacts/model/samples.npz')
                self.send(200,{'pixels':samples['raw_pixels'][0].reshape(-1).tolist(),'label':int(samples['labels'][0])})
            else:self.send(404,{'error':'Not found'})
        def do_POST(self):
            if self.path!='/predict':return self.send(404,{'error':'Not found'})
            try:
                length=int(self.headers.get('Content-Length','0'))
                if not 1<=length<=1100000:raise ValueError('invalid request size')
                
                origin=self.headers.get('Origin')
                if origin and origin not in {f'http://localhost:{args.port}',f'http://127.0.0.1:{args.port}'}:
                    return self.send(403,{'error':'Invalid origin'})
                body=json.loads(self.rfile.read(length))
                started=time.perf_counter()
                inputs,preview=preprocess(body['pixels'],body['width'],body['height'])
                result=predict(artifact,inputs,body.get('backend','software'),board=board);result['preview']=preview
                result['elapsed_seconds']=round(time.perf_counter()-started,3)
                result['compute_clock_mhz']=args.fpga_clock_mhz if result['physical_fpga'] else 50
                if result['physical_fpga']:
                    
                    with (board.directory/'measurements.jsonl').open('a') as log:
                        log.write(json.dumps({k:v for k,v in result.items() if k!='preview'})+'\n')
                self.send(200,result)
            except (ValueError,KeyError,TypeError) as exc:
                if board:
                    try:board.clear_display()
                    except Exception:pass
                self.send(400,{'error':str(exc)})
            except Exception as exc:
                if board:
                    try:board.clear_display()
                    except Exception:pass
                self.send(500,{'error':str(exc)})
    server=HTTPServer(('127.0.0.1',args.port),Handler)
    print(f'Drawing demo http://localhost:{args.port} — FPGA enabled: {bool(args.fpga_master)}',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:
        server.server_close()
        if board:board.close()

if __name__=='__main__':main()
