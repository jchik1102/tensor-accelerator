import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import nn
from torchvision.datasets import MNIST
from .model import import_onnx, quantize, run_batch
from .numeric import matrix
from .preprocessing import normalize, VERSION
from torchvision.transforms import functional as TF

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--epochs', type=int, default=10)
    parser.add_argument('--output', default='artifacts/model')
    parser.add_argument('--augment', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    dest = root / args.output
    dest.mkdir(parents=True, exist_ok=True)
    torch.manual_seed(20261008)
    torch.set_num_threads(4)
    torch.use_deterministic_algorithms(True)
    dataset = MNIST(root / 'data', train=True, download=True)
    test = MNIST(root / 'data', train=False, download=True)
    print('Normalizing training and test inputs with '+VERSION, flush=True)
    x = torch.from_numpy(np.stack([normalize(a) for a in dataset.data.numpy()])).reshape(-1,784).float()/255
    y = dataset.targets
    xt = torch.from_numpy(np.stack([normalize(a) for a in test.data.numpy()])).reshape(-1,784).float()/255
    model = nn.Sequential(nn.Linear(784, 64), nn.ReLU(), nn.Linear(64, 32), nn.ReLU(), nn.Linear(32, 10))
    optimizer = torch.optim.Adam(model.parameters(), lr=0.001)
    best, history = -1., []
    for epoch in range(args.epochs):
        model.train()
        order = torch.randperm(55000)
        for ids in order.split(256):
            optimizer.zero_grad()
            batch = x[ids]
            if args.augment:
                batch = batch.reshape(-1,1,28,28)
                
                batch = TF.affine(batch, angle=float(torch.empty(1).uniform_(-12,12)),
                    translate=torch.randint(-2,3,(2,)).tolist(),
                    scale=float(torch.empty(1).uniform_(.9,1.1)),
                    shear=[float(torch.empty(1).uniform_(-8,8)),0.],
                    interpolation=TF.InterpolationMode.BILINEAR)
                thick = nn.functional.max_pool2d(batch,3,1,1)
                thin = -nn.functional.max_pool2d(-batch,3,1,1)
                choice = torch.rand(len(batch),1,1,1)
                batch = torch.where(choice<.15, .5*batch+.5*thick,
                    torch.where(choice>.85, .5*batch+.5*thin,batch)).reshape(-1,784)
            loss = nn.functional.cross_entropy(model(batch), y[ids])
            loss.backward()
            optimizer.step()
        model.eval()
        with torch.no_grad():
            accuracy = (model(x[55000:]).argmax(1) == y[55000:]).float().mean().item()
        history.append({'epoch': epoch+1, 'validation_accuracy': accuracy})
        print(json.dumps(history[-1]), flush=True)
        if accuracy > best:
            best = accuracy
            torch.save(model.state_dict(), dest / 'weights.pt')
    model.load_state_dict(torch.load(dest / 'weights.pt', weights_only=True))
    model.eval()
    
    nodes, initializers, current = [], [], 'input'
    for index, mod in enumerate([model[0], model[2], model[4]]):
        weight, bias = mod.weight.detach().numpy(), mod.bias.detach().numpy()
        initializers.extend([onnx.numpy_helper.from_array(weight, f'w{index}'), onnx.numpy_helper.from_array(bias, f'b{index}')])
        out = f'gemm{index}'
        nodes.append(onnx.helper.make_node('Gemm', [current, f'w{index}', f'b{index}'], [out], transB=1))
        if index < 2:
            current = f'relu{index}'
            nodes.append(onnx.helper.make_node('Relu', [out], [current]))
        else:
            current = out
    graph = onnx.helper.make_graph(nodes, 'mnist_fc', [onnx.helper.make_tensor_value_info('input', onnx.TensorProto.FLOAT, [1,784])],
        [onnx.helper.make_tensor_value_info(current, onnx.TensorProto.FLOAT, [1,10])], initializers)
    exported = onnx.helper.make_model(graph, opset_imports=[onnx.helper.make_opsetid('',18)], ir_version=10)
    onnx.save(exported, dest / 'model.onnx')
    layers = import_onnx(dest / 'model.onnx')
    artifact = quantize(layers, x[:1024].numpy())
    artifact['preprocessing'] = VERSION
    (dest / 'model.json').write_text(json.dumps(artifact, separators=(',', ':')))
    input_int = np.rint(xt.numpy() * 127).astype(np.int8)
    with torch.no_grad():
        float_scores = model(xt).numpy()
    scores, intermediates = run_batch(artifact, input_int)
    scalar_checked = 8
    for sample in range(scalar_checked):
        value = [input_int[sample].tolist()]
        for index, layer in enumerate(artifact['layers']):
            value, _ = matrix(value, layer['weights'], layer['bias'], layer['multipliers'], layer['shifts'], layer['relu'])
            assert value[0] == intermediates[index][sample].tolist()
    session = ort.InferenceSession(str(dest / 'model.onnx'), providers=['CPUExecutionProvider'])
    ort_error = max(float(np.max(np.abs(session.run(None, {'input': xt[i:i+1].numpy()})[0][0] - float_scores[i]))) for i in range(16))
    assert ort_error < 1e-4
    float_accuracy = float(np.mean(float_scores.argmax(1) == test.targets.numpy()))
    int_accuracy = float(np.mean(scores.argmax(1) == test.targets.numpy()))
    np.savez(dest / 'samples.npz', inputs=input_int[:16], labels=test.targets.numpy()[:16], scores=scores[:16], raw_pixels=test.data.numpy()[:16])
    report = {'seed':20261008, 'epochs':args.epochs, 'training_examples':55000,'validation_examples':5000,
        'calibration_examples':1024,'test_examples':10000,'history':history,'best_validation_accuracy':best,
        'float_accuracy':float_accuracy,'integer_accuracy':int_accuracy,'accuracy_loss':float_accuracy-int_accuracy,
        'scalar_checked_samples':scalar_checked,'ort_max_abs_error_16_samples':ort_error,
        'targets_pass':float_accuracy >= .96 and float_accuracy-int_accuracy <= .01,
        'onnx_sha256':hashlib.sha256((dest/'model.onnx').read_bytes()).hexdigest(),
        'artifact_sha256':hashlib.sha256((dest/'model.json').read_bytes()).hexdigest(),
        'preprocessing':VERSION,'augmentation':args.augment,
        'backend':'CPU software; no FPGA inference measured'}
    (dest / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)
    if not report['targets_pass']:
        raise SystemExit('Model acceptance targets failed')

if __name__ == '__main__':
    main()
