"""Test vectors for asic/ta_asic_tile.sv (tb: asic/ta_asic_tile_tb.sv).

Each test is an N x K by K x N INT8 matrix product. The left and top operands
are written as skewed waves, the way ta_core feeds the array: at wave w, row r
receives A[r][w-r] and column c receives B[w-c][c] (0 outside the matrix).
For every output lane the expected accumulator is C[r][c] + bias, and the
expected result is host.ta.numeric.requantize of it, the same reference the
FPGA flow is checked against.

Usage (repository root): PYTHONPATH=. python asic/tile_vectors.py OUT_DIR [--n 8] [--tests 24] [--seed 1]
Writes waves.hex, tests.hex and checks.hex, and prints the counts.
"""
import argparse
import random
from pathlib import Path

from host.ta.numeric import requantize


def hexword(value, bits):
    return format(value & ((1 << bits) - 1), f'0{(bits + 3) // 4}x')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('out')
    parser.add_argument('--n', type=int, default=8)
    parser.add_argument('--tests', type=int, default=24)
    parser.add_argument('--seed', type=int, default=1)
    args = parser.parse_args()
    n, rng = args.n, random.Random(args.seed)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    waves, tests, checks = [], [], []
    for t in range(args.tests):
        # Edge cases first: K=1, all-extreme operands, then random sizes.
        k = 1 if t == 0 else 64 if t in (1, 2) else rng.randint(1, 64)
        if t == 1:
            a = [[-128] * k for _ in range(n)]
            b = [[-128] * n for _ in range(k)]
        elif t == 2:
            a = [[127] * k for _ in range(n)]
            b = [[-128] * n for _ in range(k)]
        else:
            a = [[rng.randint(-128, 127) for _ in range(k)] for _ in range(n)]
            b = [[rng.randint(-128, 127) for _ in range(n)] for _ in range(k)]
        count = k + 2 * n - 2
        tests.append(hexword(len(waves), 16) + hexword(count, 16))
        for w in range(count):
            left = [a[r][w - r] if 0 <= w - r < k else 0 for r in range(n)]
            top = [b[w - c][c] if 0 <= w - c < k else 0 for c in range(n)]
            waves.append(''.join(hexword(v, 8) for v in reversed(left)) +
                         ''.join(hexword(v, 8) for v in reversed(top)))
        limit = (1 << 31) - 1 - k * 16384
        for lane in range(n * n):
            r, c = divmod(lane, n)
            total = sum(a[r][i] * b[i][c] for i in range(k))
            if lane % 4 == 3:
                # Exact rounding ties (remainder == half), even and odd
                # quotients, both signs: round-half-to-even is only visible here.
                multiplier, shift = 1, rng.randint(1, 20)
                quotient = rng.randint(0, 1000)
                acc = rng.choice([1, -1]) * (quotient * (1 << shift) + (1 << (shift - 1)))
                bias = acc - total
                relu = False
            else:
                bias = rng.randint(-limit, limit)
                acc = total + bias
                multiplier = rng.choice([1, (1 << 31) - 1, rng.randint(1, (1 << 31) - 1)])
                shift = rng.choice([0, 62, rng.randint(0, 62), rng.randint(28, 40)])
                relu = rng.random() < 0.5
            result = requantize(acc, multiplier, shift, relu)
            checks.append(hexword(bias, 32) + hexword(multiplier, 32) + hexword(shift, 8) +
                          hexword(int(relu), 8) + hexword(acc, 32) + hexword(result, 8))
    (out / 'waves.hex').write_text('\n'.join(waves) + '\n')
    (out / 'tests.hex').write_text('\n'.join(tests) + '\n')
    (out / 'checks.hex').write_text('\n'.join(checks) + '\n')
    print(f'TILE_VECTORS n={n} tests={len(tests)} waves={len(waves)} lanes={len(checks)} seed={args.seed}')


if __name__ == '__main__':
    main()
