import math
from numbers import Integral

I32_MAX = (1 << 31) - 1

def exact_integer(value):
    if isinstance(value, bool) or not isinstance(value, Integral):
        raise ValueError('integer encoding required; implicit casts are unsupported')
    return int(value)

def requantize(value, multiplier, shift, relu=False):
    value, multiplier, shift = map(exact_integer, (value, multiplier, shift))
    if not -(1 << 31) <= value <= I32_MAX:
        raise ValueError('INT32 overflow')
    if not 1 <= multiplier <= I32_MAX or not 0 <= shift <= 62:
        raise ValueError('invalid requantization parameters')
    product = max(0, value) * multiplier if relu else value * multiplier
    assert -(1 << 63) <= product < (1 << 63)
    magnitude = abs(product)
    quotient, remainder = divmod(magnitude, 1 << shift)
    if shift and (2 * remainder > (1 << shift) or
                  (2 * remainder == (1 << shift) and quotient % 2)):
        quotient += 1
    rounded = -quotient if product < 0 else quotient
    return min(127, max(-128, rounded))

def encode_scale(ratio):
    if not math.isfinite(ratio) or ratio <= 0:
        raise ValueError('scale must be finite and positive')
    for shift in range(62, -1, -1):
        multiplier = round(ratio * (1 << shift))
        if 1 <= multiplier <= I32_MAX:
            return multiplier, shift
    raise ValueError('scale is not representable')

def validate_layer(weights, bias, multipliers, shifts):
    n = len(weights)
    if not 1 <= n <= 128 or not 1 <= len(weights[0]) <= 1024:
        raise ValueError('unsupported layer shape')
    k = len(weights[0])
    if not len(bias) == len(multipliers) == len(shifts) == n:
        raise ValueError('channel parameter shape')
    for row, b, mult, shift in zip(weights, bias, multipliers, shifts):
        if len(row) != k or any(not -128 <= exact_integer(w) <= 127 for w in row):
            raise ValueError('invalid INT8 weights')
        if abs(exact_integer(b)) > I32_MAX - k * 16384:
            raise ValueError('unsafe bias/accumulator bound')
        requantize(0, mult, shift)

def matrix(inputs, weights, bias, multipliers, shifts, relu=False):
    validate_layer(weights, bias, multipliers, shifts)
    k = len(weights[0])
    if not 1 <= len(inputs) <= 32:
        raise ValueError('unsupported M')
    outputs, accumulators = [], []
    for row in inputs:
        if len(row) != k or any(not -128 <= exact_integer(a) <= 127 for a in row):
            raise ValueError('invalid inputs')
        out, acc = [], []
        for j, wr in enumerate(weights):
            total = 0
            for a, w in zip(row, wr):
                total += int(a) * int(w)
                if not -(1 << 31) <= total <= I32_MAX:
                    raise ValueError('partial accumulator overflow')
            total += int(bias[j])
            acc.append(total)
            out.append(requantize(total, multipliers[j], shifts[j], relu))
        outputs.append(out)
        accumulators.append(acc)
    return outputs, accumulators
