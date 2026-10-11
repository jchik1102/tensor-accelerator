from pathlib import Path
import copy
import json
import numpy as np
import onnx
import pytest
from host.ta.model import import_onnx,load,run_batch
from host.ta.numeric import matrix
from host.ta.runtime import preprocess,predict

ROOT=Path(__file__).resolve().parents[1]

def test_trained_artifact_and_scalar_layers():
    artifact=load(ROOT/'artifacts/model/model.json')
    samples=np.load(ROOT/'artifacts/model/samples.npz')
    actual,layers=run_batch(artifact,samples['inputs'][:3])
    for sample in range(3):
        value=[samples['inputs'][sample].tolist()]
        for i,layer in enumerate(artifact['layers']):
            value,_=matrix(value,layer['weights'],layer['bias'],layer['multipliers'],layer['shifts'],layer['relu'])
            assert value[0]==layers[i][sample].tolist()

@pytest.mark.parametrize('mutation',['opset','transB','operator','dynamic','chain','bias_shape','nonfinite'])
def test_reject_unsupported_onnx(tmp_path,mutation):
    model=onnx.load(ROOT/'artifacts/model/model.onnx')
    if mutation=='opset':model.opset_import[0].version=17
    elif mutation=='transB':model.graph.node[0].attribute[0].i=0
    elif mutation=='operator':model.graph.node[1].op_type='Sigmoid'
    elif mutation=='dynamic':model.graph.input[0].type.tensor_type.shape.dim[0].dim_param='batch'
    elif mutation=='chain':model.graph.node[2].input[0]='input'
    elif mutation=='bias_shape':
        model.graph.initializer[1].dims.insert(0,1)
    elif mutation=='nonfinite':
        w=onnx.numpy_helper.to_array(model.graph.initializer[0]).copy();w[0,0]=float('nan')
        model.graph.initializer[0].CopyFrom(onnx.numpy_helper.from_array(w,model.graph.initializer[0].name))
    path=tmp_path/'bad.onnx';onnx.save(model,path)
    with pytest.raises((ValueError,onnx.checker.ValidationError,onnx.shape_inference.InferenceError)):import_onnx(path)

def test_preprocess_and_software_result():
    pixels=[0]*784;pixels[0]=255;pixels[1]=128
    values,preview=preprocess(pixels,28,28)
    assert max(values)==127 and len(preview)==784
    assert np.asarray(preview).reshape(28,28)[:3].sum()==0
    artifact=load(ROOT/'artifacts/model/model.json')
    result=predict(artifact,values)
    assert result['exact_match'] and not result['physical_fpga'] and result['layers_checked']==3
    with pytest.raises(ValueError):preprocess([256],1,1)
    with pytest.raises(ValueError):preprocess([0],0,1)
    with pytest.raises(ValueError,match='Draw a digit'):preprocess([0]*784,28,28)
    with pytest.raises(ValueError):predict(artifact,values,'fpga')
