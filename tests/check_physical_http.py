import json
from pathlib import Path
from urllib.request import Request,urlopen
from urllib.error import HTTPError
from torchvision.datasets import MNIST

root=Path('/mnt/c/projects/tensor-accelerator')
dest=root/'artifacts/physical-check'
dest.mkdir(parents=True,exist_ok=True)
dataset=MNIST(root/'data',train=False,download=False)
results=[]
for label in range(10):
    index=int((dataset.targets==label).nonzero()[0])
    body=dict(pixels=dataset.data[index].reshape(-1).tolist(),width=28,height=28,backend='fpga')
    request=Request('http://localhost:8766/predict',json.dumps(body).encode(),{'Content-Type':'application/json'})
    with urlopen(request,timeout=60) as response:result=json.load(response)
    assert result['physical_fpga'] and result['exact_match'] and result['layers_checked']==3
    assert result['hex_display_updated'] and result['compute_cycles']==17337
    result.pop('preview')
    result.update(test_index=index,expected_label=label)
    results.append(result)
    print(f"PHYSICAL_SAMPLE_PASS label={label} prediction={result['prediction']} elapsed={result['elapsed_seconds']}",flush=True)
body=dict(pixels=[0]*784,width=28,height=28,backend='fpga')
try:
    urlopen(Request('http://localhost:8766/predict',json.dumps(body).encode(),{'Content-Type':'application/json'}),timeout=10)
    raise AssertionError('Blank input accepted')
except HTTPError as exc:
    assert exc.code==400 and 'Draw a digit' in json.load(exc)['error']
print('BLANK_REQUEST_REJECTED',flush=True)
(dest/'sample-results.json').write_text(json.dumps(results,indent=2))
