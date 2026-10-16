"""Float and validation accuracy of the retained model (artifacts/model).

Loads artifacts/model/weights.pt into the network host.ta.train builds and
measures, without retraining:
  - validation accuracy on training images 55000..59999 (train.py's split),
  - float accuracy on the 10,000 MNIST test images,
  - INT8 accuracy of artifacts/model/model.json on the same test images, as a
    cross-check against make accuracy.
Writes results/float-accuracy.json.
Usage (repository root, the project venv): python -m host.ta.evaluate_float
"""
import hashlib
import json
from pathlib import Path
import numpy as np
import torch
from torch import nn
from torchvision.datasets import MNIST
from .model import run_batch
from .preprocessing import normalize, VERSION


def main():
    root = Path(__file__).resolve().parents[2]
    model_dir = root / 'artifacts/model'
    dataset = MNIST(root / 'data', train=True, download=True)
    test = MNIST(root / 'data', train=False, download=True)
    x = torch.from_numpy(np.stack([normalize(a) for a in dataset.data.numpy()])).reshape(-1, 784).float() / 255
    y = dataset.targets
    xt = torch.from_numpy(np.stack([normalize(a) for a in test.data.numpy()])).reshape(-1, 784).float() / 255
    model = nn.Sequential(nn.Linear(784, 64), nn.ReLU(), nn.Linear(64, 32), nn.ReLU(), nn.Linear(32, 10))
    model.load_state_dict(torch.load(model_dir / 'weights.pt', weights_only=True))
    model.eval()
    with torch.no_grad():
        validation = (model(x[55000:]).argmax(1) == y[55000:]).float().mean().item()
        float_test = (model(xt).argmax(1) == test.targets).float().mean().item()
    artifact = json.loads((model_dir / 'model.json').read_text())
    scores, _ = run_batch(artifact, np.rint(xt.numpy() * 127).astype(np.int8))
    int_test = float(np.mean(scores.argmax(1) == test.targets.numpy()))
    report = {
        'model_json_sha256': hashlib.sha256((model_dir / 'model.json').read_bytes()).hexdigest(),
        'weights_sha256': hashlib.sha256((model_dir / 'weights.pt').read_bytes()).hexdigest(),
        'preprocessing': VERSION,
        'validation_examples': 5000, 'validation_accuracy': validation,
        'test_examples': 10000, 'float_test_accuracy': float_test, 'int8_test_accuracy': int_test,
        'int8_loss': float_test - int_test,
    }
    (root / 'results/float-accuracy.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
