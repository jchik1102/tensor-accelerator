"""cocotb tests for asic/ta_asic_tile.sv: the 8x8 systolic array and the
requantizer, end to end (run by tb/cocotb/test_cocotb.py).

Each test streams an N x K by K x N INT8 matrix product through the array as
skewed waves (row r gets A[r][w-r], column c gets B[w-c][c], the order ta_core
uses), then for every output lane loads acc = C[r][c] + bias and requantizes it,
checking both against a Python matrix product and host.ta.numeric.requantize.
This is a cocotb port of asic/ta_asic_tile_tb.sv.
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from host.ta.numeric import requantize  # noqa: E402

N = 8


def pack(values):
    """Lane i of an N x 8-bit bus carries values[i] (two's complement)."""
    word = 0
    for i, v in enumerate(values):
        word |= (v & 0xFF) << (8 * i)
    return word


async def cycle(dut):
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)


async def setup(dut):
    Clock(dut.clk, 10, unit="ns").start()
    for name in ("clear", "advance", "load", "start", "relu", "left_in", "top_in", "lane", "bias", "multiplier", "shift"):
        getattr(dut, name).value = 0
    dut.reset.value = 1
    await FallingEdge(dut.clk)
    await cycle(dut)
    dut.reset.value = 0


async def matmul(dut, a, b):
    """Clear the accumulators and stream one product; returns after the last add."""
    k = len(b)
    dut.clear.value = 1
    await cycle(dut)
    dut.clear.value = 0
    for w in range(k + 2 * N - 2):
        dut.advance.value = 1
        dut.left_in.value = pack([a[r][w - r] if 0 <= w - r < k else 0 for r in range(N)])
        dut.top_in.value = pack([b[w - c][c] if 0 <= w - c < k else 0 for c in range(N)])
        await cycle(dut)
    dut.advance.value = 0
    dut.left_in.value = 0
    dut.top_in.value = 0
    for _ in range(3):          # input register, product register, last accumulate
        await cycle(dut)


async def output_lane(dut, lane, bias, multiplier, shift, relu):
    """acc = sums[lane] + bias, then requantize; returns (acc, result)."""
    dut.load.value, dut.lane.value, dut.bias.value = 1, lane, bias & 0xFFFFFFFF
    await cycle(dut)
    dut.load.value = 0
    await cycle(dut)
    acc = dut.acc_out.value.to_signed()
    dut.start.value, dut.multiplier.value, dut.shift.value, dut.relu.value = 1, multiplier, shift, int(relu)
    await cycle(dut)
    dut.start.value = 0
    for _ in range(20):
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        if dut.done.value == 1:
            return acc, dut.result.value.to_signed()
    raise AssertionError(f"lane {lane}: no done")


async def run_products(dut, rng, products, max_k):
    lanes = 0
    for t in range(products):
        k = rng.randint(1, max_k)
        a = [[rng.randint(-128, 127) for _ in range(k)] for _ in range(N)]
        b = [[rng.randint(-128, 127) for _ in range(N)] for _ in range(k)]
        await matmul(dut, a, b)
        for lane in range(N * N):
            r, c = divmod(lane, N)
            total = sum(a[r][i] * b[i][c] for i in range(k))
            limit = (1 << 31) - 1 - k * 16384
            bias = rng.randint(-limit, limit)
            multiplier, shift, relu = rng.randint(1, (1 << 31) - 1), rng.randint(0, 62), rng.random() < 0.5
            acc, result = await output_lane(dut, lane, bias, multiplier, shift, relu)
            assert acc == total + bias, f"product {t} lane {lane}: acc {acc} != {total + bias}"
            want = requantize(total + bias, multiplier, shift, relu)
            assert result == want, f"product {t} lane {lane}: result {result} != {want}"
            lanes += 1
    return lanes


@cocotb.test()
async def extreme_operands(dut):
    """All -128 x -128 and 127 x -128 products at K = 64: the largest accumulator magnitudes."""
    await setup(dut)
    for av, bv in ((-128, -128), (127, -128)):
        a = [[av] * 64 for _ in range(N)]
        b = [[bv] * N for _ in range(64)]
        await matmul(dut, a, b)
        for lane in (0, 9, 63):
            acc, _ = await output_lane(dut, lane, 0, 1, 0, False)
            assert acc == 64 * av * bv, f"lane {lane}: {acc}"
    dut._log.info("TILE_EXTREMES_PASS")


@cocotb.test()
async def random_products(dut):
    """Random sizes K = 1..64 with random bias, multiplier, shift and ReLU on every lane."""
    await setup(dut)
    lanes = await run_products(dut, random.Random(20261016), products=8, max_k=64)
    dut._log.info("TILE_RANDOM_PASS products=8 lanes=%d", lanes)


@cocotb.test()
async def clear_between_products(dut):
    """Back-to-back products must not leak accumulators: clear resets every PE."""
    await setup(dut)
    rng = random.Random(7)
    lanes = await run_products(dut, rng, products=3, max_k=4)
    dut._log.info("TILE_CLEAR_PASS lanes=%d", lanes)
