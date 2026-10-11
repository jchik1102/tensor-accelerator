import json
import socket
import subprocess
import sys
import time
from urllib.request import urlopen, Request
from urllib.error import HTTPError, URLError
import pytest
from host.ta.runtime import ROOT

def test_example_and_blank_over_http():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    process=subprocess.Popen([sys.executable,'-m','host.ta.demo','--port',str(port)],
                             cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    base=f'http://127.0.0.1:{port}'
    try:
        deadline=time.monotonic()+10
        while True:
            try:
                with urlopen(base+'/capabilities',timeout=1) as response:cap=json.load(response)
                break
            except URLError:
                if process.poll() is not None or time.monotonic()>deadline:raise
                time.sleep(.1)
        assert cap['fpga'] is False
        with urlopen(base+'/sample') as response:sample=json.load(response)
        def post(pixels):
            request=Request(base+'/predict',json.dumps(dict(pixels=pixels,width=28,height=28,
                backend='software')).encode(),{'Content-Type':'application/json','Origin':base})
            return urlopen(request,timeout=10)
        with post(sample['pixels']) as response:result=json.load(response)
        assert result['prediction']==sample['label']==7
        assert result['layers_checked']==3 and result['exact_match']
        assert not result['physical_fpga'] and not result['hex_display_updated']
        assert len(result['preview'])==784
        with pytest.raises(HTTPError) as exc:post([0]*784)
        assert exc.value.code==400
        assert 'Draw a digit' in json.load(exc.value)['error']
    finally:
        process.terminate();process.wait(timeout=10)
