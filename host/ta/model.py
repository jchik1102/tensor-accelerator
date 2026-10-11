import json
from pathlib import Path
import numpy as np
import onnx
from onnx import numpy_helper
from .numeric import encode_scale, validate_layer

def import_onnx(path):
    model = onnx.load(path)
    onnx.checker.check_model(model, full_check=True)
    if [(x.domain, x.version) for x in model.opset_import] != [('', 18)]:
        raise ValueError('only default-domain opset 18 is supported')
    g = model.graph
    if len(g.input) != 1 or len(g.output) != 1:
        raise ValueError('one input/output required')
    def shape(value):
        t = value.type.tensor_type
        dims = [d.dim_value for d in t.shape.dim]
        if t.elem_type != onnx.TensorProto.FLOAT or len(dims) != 2 or dims[0] != 1 or dims[1] <= 0:
            raise ValueError('fixed [1,K] float32 tensor required')
        return dims[1]
    k = shape(g.input[0])
    output_n = shape(g.output[0])
    constants = {x.name: numpy_helper.to_array(x) for x in g.initializer}
    current, layers = g.input[0].name, []
    for node in g.node:
        if node.domain or len(node.output) != 1:
            raise ValueError('unsupported domain/output')
        attrs = {a.name: onnx.helper.get_attribute_value(a) for a in node.attribute}
        if node.op_type == 'Gemm':
            if len(node.input) != 3 or node.input[0] != current:
                raise ValueError('only linear constant Gemm supported')
            if set(attrs) - {'alpha', 'beta', 'transA', 'transB'} or any(
                attrs.get(key, default) != wanted for key, default, wanted in
                [('alpha', 1., 1.), ('beta', 1., 1.), ('transA', 0, 0), ('transB', 0, 1)]):
                raise ValueError('unsupported Gemm attributes')
            if node.input[1] not in constants or node.input[2] not in constants:
                raise ValueError('constant weights/bias required')
            w, b = constants[node.input[1]], constants[node.input[2]]
            if w.dtype != np.float32 or b.dtype != np.float32 or w.ndim != 2 or w.shape[1] != k or b.shape != (w.shape[0],):
                raise ValueError('Gemm shape/type mismatch')
            if not 1 <= k <= 1024 or not 1 <= w.shape[0] <= 128 or not np.isfinite(w).all() or not np.isfinite(b).all():
                raise ValueError('unsupported dimensions or nonfinite constants')
            layers.append({'weights': w.copy(), 'bias': b.copy(), 'relu': False})
            k = w.shape[0]
        elif node.op_type == 'Relu':
            if not layers or layers[-1]['relu'] or list(node.input) != [current] or attrs:
                raise ValueError('unsupported Relu')
            layers[-1]['relu'] = True
        else:
            raise ValueError(f'unsupported operator {node.op_type}')
        current = node.output[0]
    if not 1 <= len(layers) <= 8 or current != g.output[0].name or k != output_n:
        raise ValueError('invalid chain/output')
    if sum(x['weights'].size for x in layers) > 65536 or sum(x['weights'].shape[0] for x in layers) > 1024:
        raise ValueError('model exceeds memory')
    if layers[0]['weights'].shape[1] + sum(x['weights'].shape[0] for x in layers) > 8192:
        raise ValueError('activation memory capacity')
    return layers

def quantize(layers, calibration):
    scale, values, result = 1 / 127, calibration.astype(np.float64), []
    for layer in layers:
        weights, bias = layer['weights'].astype(np.float64), layer['bias'].astype(np.float64)
        values = values @ weights.T + bias
        if layer['relu']:
            values = np.maximum(values, 0)
        output_scale = max(float(np.max(np.abs(values))) / 127, 1e-12)
        weight_scale = np.max(np.abs(weights), axis=1) / 127
        weight_scale = np.where(weight_scale == 0, 1., weight_scale)
        qw = np.clip(np.rint(weights / weight_scale[:, None]), -127, 127).astype(np.int8)
        qb = np.rint(bias / (scale * weight_scale)).astype(np.int64)
        pairs = [encode_scale(float(scale * ws / output_scale)) for ws in weight_scale]
        entry = {'weights': qw.tolist(), 'bias': qb.tolist(), 'multipliers': [p[0] for p in pairs],
                 'shifts': [p[1] for p in pairs], 'relu': layer['relu'],
                 'input_scale': scale, 'output_scale': output_scale, 'weight_scales': weight_scale.tolist()}
        validate_layer(qw, qb, entry['multipliers'], entry['shifts'])
        result.append(entry)
        scale = output_scale
    return {'format': 'TA01', 'layers': result}

def load(path):
    artifact = json.loads(Path(path).read_text())
    if artifact.get('format') != 'TA01' or not 1 <= len(artifact.get('layers', [])) <= 8:
        raise ValueError('invalid TA01 artifact')
    previous = None
    weights = channels = 0
    activations = len(artifact['layers'][0]['weights'][0])
    for layer in artifact['layers']:
        if type(layer.get('relu')) is not bool:
            raise ValueError('ReLU flag must be boolean')
        validate_layer(layer['weights'], layer['bias'], layer['multipliers'], layer['shifts'])
        k, n = len(layer['weights'][0]), len(layer['weights'])
        for scale in (layer['input_scale'], layer['output_scale'], *layer['weight_scales']):
            if not isinstance(scale, (int,float)) or not np.isfinite(scale) or scale<=0:
                raise ValueError('finite positive model scales required')
        if len(layer['weight_scales'])!=n:
            raise ValueError('weight scale shape')
        if previous is not None and previous != k:
            raise ValueError('layer dimension mismatch')
        previous = n
        weights += k*n
        channels += n
        activations += n
    if weights > 65536 or channels > 1024 or activations > 8192:
        raise ValueError('capacity exceeded')
    return artifact

def run_batch(artifact, inputs):
    
    values, intermediates = np.asarray(inputs, dtype=np.int64), []
    for layer in artifact['layers']:
        acc = values @ np.asarray(layer['weights'], dtype=np.int64).T + np.asarray(layer['bias'], dtype=np.int64)
        if layer['relu']:
            acc = np.maximum(acc, 0)
        product = acc * np.asarray(layer['multipliers'], dtype=np.int64)
        magnitude = np.abs(product)
        shifts = np.asarray(layer['shifts'], dtype=np.int64)
        divisors = np.left_shift(np.int64(1), shifts)
        quotient, remainder = magnitude // divisors, magnitude % divisors
        quotient += ((shifts > 0) & ((remainder > divisors//2) | ((remainder == divisors//2) & ((quotient & 1) == 1))))
        values = np.clip(np.where(product < 0, -quotient, quotient), -128, 127)
        intermediates.append(values.copy())
    return values, intermediates
