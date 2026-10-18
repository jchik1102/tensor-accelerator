"""cocotb tests for rtl/ta_requant.sv (run by tb/cocotb/test_cocotb.py).

The reference is host.ta.numeric.requantize, the same integer model the FPGA
flow and the UVM bench are checked against. Stimulus is directed edge cases
plus constrained-random operations; a small functional-coverage model records
which sign / ReLU / saturation / rounding-tie / shift-range bins were hit and
the random test fails unless every bin was reached.
"""
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from host.ta.numeric import requantize  # noqa: E402

I32_MIN, I32_MAX, M_MAX = -(1 << 31), (1 << 31) - 1, (1 << 31) - 1
LATENCY_LIMIT = 10


async def reset(dut):
    dut.reset.value = 1
    dut.start.value = 0
    dut.value.value = 0
    dut.multiplier.value = 0
    dut.shift.value = 0
    dut.relu.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.reset.value = 0


async def run_one(dut, value, multiplier, shift, relu):
    """Start one requantization (inputs held for one cycle) and return the result."""
    await FallingEdge(dut.clk)
    dut.value.value = value
    dut.multiplier.value = multiplier
    dut.shift.value = shift
    dut.relu.value = int(relu)
    dut.start.value = 1
    await FallingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(LATENCY_LIMIT):
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        if dut.done.value == 1:
            return dut.result.value.to_signed()
    raise AssertionError(f"no done within {LATENCY_LIMIT} cycles for {value} {multiplier} {shift} {relu}")


def classify(value, multiplier, shift, relu):
    """Coverage bins for one operation."""
    product = max(0, value) * multiplier if relu else value * multiplier
    magnitude = abs(product)
    rem = magnitude & ((1 << shift) - 1)
    tie = shift > 0 and 2 * rem == (1 << shift)
    result = requantize(value, multiplier, shift, relu)
    sat = "sat_hi" if result == 127 and (magnitude >> shift) > 127 else \
          "sat_lo" if result == -128 and product < 0 and (magnitude >> shift) >= 128 else "in_range"
    bins = {("sign", "neg" if value < 0 else "zero" if value == 0 else "pos"),
            ("relu", bool(relu)), ("saturation", sat),
            ("shift", "0" if shift == 0 else "1-15" if shift < 16 else "16-31" if shift < 32 else "32-62")}
    if tie:
        bins.add(("tie", "even" if (magnitude >> shift) % 2 == 0 else "odd"))
    if relu and value < 0:
        bins.add(("relu_clamp", True))
    return bins


ALL_BINS = {("sign", s) for s in ("neg", "zero", "pos")} | {("relu", r) for r in (False, True)} | \
    {("saturation", s) for s in ("sat_hi", "sat_lo", "in_range")} | \
    {("shift", s) for s in ("0", "1-15", "16-31", "32-62")} | \
    {("tie", "even"), ("tie", "odd"), ("relu_clamp", True)}


async def check(dut, value, multiplier, shift, relu, covered=None):
    want = requantize(value, multiplier, shift, relu)
    got = await run_one(dut, value, multiplier, shift, relu)
    assert got == want, f"requant({value}, {multiplier}, {shift}, relu={relu}) = {got}, want {want}"
    if covered is not None:
        covered.update(classify(value, multiplier, shift, relu))


@cocotb.test()
async def directed_edges(dut):
    """Integer extremes, zero, unit and maximum multipliers, shift extremes and exact ties."""
    Clock(dut.clk, 10, unit="ns").start()
    await reset(dut)
    cases = [(0, 1, 0, False), (1, 1, 0, False), (-1, 1, 0, False), (127, 1, 0, False), (128, 1, 0, False),
             (-128, 1, 0, False), (-129, 1, 0, False), (I32_MAX, M_MAX, 62, False), (I32_MIN, M_MAX, 62, False),
             (I32_MAX, M_MAX, 0, False), (I32_MIN, 1, 0, False), (I32_MIN, M_MAX, 31, True),
             (5, 1, 1, False), (7, 1, 1, False), (-5, 1, 1, False), (-7, 1, 1, False),  # ties: 2.5, 3.5
             (3, 1, 1, False), (1 << 20, 1, 21, False), (3 << 19, 1, 20, False), (-(3 << 19), 1, 20, True)]
    for case in cases:
        await check(dut, *case)
    dut._log.info("REQUANT_DIRECTED_PASS cases=%d", len(cases))


@cocotb.test()
async def constrained_random(dut):
    """Weighted random operations until every coverage bin is hit (at least 4,000 operations)."""
    Clock(dut.clk, 10, unit="ns").start()
    await reset(dut)
    rng = random.Random(20261016)
    covered, count = set(), 0
    while count < 4000 or not ALL_BINS <= covered:
        if count > 20000:
            break
        kind = rng.random()
        shift = rng.choice([0, rng.randint(1, 15), rng.randint(16, 31), rng.randint(32, 62)])
        relu = rng.random() < 0.5
        if kind < 0.25:     # exact ties: magnitude = q * 2^s + 2^(s-1) with multiplier 1
            shift = max(shift, 1) if shift < 32 else rng.randint(1, 30)
            q = rng.randint(0, 200)
            value = rng.choice([1, -1]) * (q * (1 << shift) + (1 << (shift - 1)))
            if not I32_MIN <= value <= I32_MAX:
                continue
            multiplier = 1
        elif kind < 0.45:   # small values around the INT8 range, small shifts: saturation edges
            value, multiplier, shift = rng.randint(-400, 400), rng.randint(1, 4), rng.randint(0, 2)
        else:
            value = rng.choice([rng.randint(I32_MIN, I32_MAX), rng.randint(-1 << 16, 1 << 16), 0])
            multiplier = rng.choice([1, M_MAX, rng.randint(1, M_MAX)])
        await check(dut, value, multiplier, shift, relu, covered)
        count += 1
    missing = ALL_BINS - covered
    assert not missing, f"coverage bins not hit: {sorted(missing)}"
    dut._log.info("REQUANT_RANDOM_PASS ops=%d bins=%d/%d", count, len(ALL_BINS & covered), len(ALL_BINS))


@cocotb.test()
async def start_while_busy_is_ignored(dut):
    """A second start during an operation must not change its result or restart it."""
    Clock(dut.clk, 10, unit="ns").start()
    await reset(dut)
    await FallingEdge(dut.clk)
    dut.value.value, dut.multiplier.value, dut.shift.value, dut.relu.value = 1000, 3, 4, 0
    dut.start.value = 1
    await FallingEdge(dut.clk)
    dut.value.value, dut.multiplier.value = -999, 7   # new operands with start still high
    for _ in range(2):
        await FallingEdge(dut.clk)
    dut.start.value = 0
    for _ in range(LATENCY_LIMIT):
        await RisingEdge(dut.clk)
        await FallingEdge(dut.clk)
        if dut.done.value == 1:
            break
    assert dut.done.value == 1
    assert dut.result.value.to_signed() == requantize(1000, 3, 4), "busy start changed the result"
    dut._log.info("REQUANT_BUSY_START_PASS")


@cocotb.test()
async def reset_mid_operation(dut):
    """Reset during an operation clears it: no done pulse afterwards."""
    Clock(dut.clk, 10, unit="ns").start()
    await reset(dut)
    await FallingEdge(dut.clk)
    dut.value.value, dut.multiplier.value, dut.shift.value = 12345, 9, 3
    dut.start.value = 1
    await FallingEdge(dut.clk)
    dut.start.value = 0
    await FallingEdge(dut.clk)
    dut.reset.value = 1
    await FallingEdge(dut.clk)
    dut.reset.value = 0
    for _ in range(LATENCY_LIMIT):
        await RisingEdge(dut.clk)
        assert dut.done.value == 0, "done after reset cancelled the operation"
    await check(dut, -77, 5, 2, False)   # and the unit still works
    dut._log.info("REQUANT_RESET_PASS")
