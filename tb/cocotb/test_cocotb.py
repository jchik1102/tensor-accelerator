"""Build and run the cocotb testbenches with Icarus Verilog.

    python -m pytest tb/cocotb -v        (make cocotb; needs iverilog on PATH)

Put the Python that has cocotb first on PATH (OSS CAD Suite bundles its own).

Each runner compiles one design and runs its cocotb test module; cocotb writes
results to tb/cocotb/test_<name>.result.xml and fails the pytest case if
any cocotb test failed.
"""
import os
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
# TA_MUTATION=TA_MUTATE_PE (or TA_MUTATE_ROUND) builds the RTL with one of its
# built-in defects, to show the tests fail on it.
MUTATION = os.environ.get("TA_MUTATION")
# COCOTB_SIM=questa runs the same tests in Questa (scripts/run-questa.ps1).
SIM = os.environ.get("COCOTB_SIM", "icarus")


def run(top, sources, module):
    runner = get_runner(SIM)
    build = HERE / "sim_build" / (top if SIM == "icarus" else f"{SIM}_{top}")
    runner.build(sources=[ROOT / s for s in sources], hdl_toplevel=top, build_dir=build,
                 build_args=["-g2012"] if SIM == "icarus" else [], defines={MUTATION: 1} if MUTATION else {}, always=True)
    # Questa finds the compiled library in its working directory, so it runs in the build directory.
    runner.test(hdl_toplevel=top, test_module=module, test_dir=HERE if SIM == "icarus" else build, build_dir=build)


def test_requant():
    run("ta_requant", ["rtl/ta_requant.sv"], "requant_tests")


def test_tile():
    run("ta_asic_tile", ["rtl/ta_pe.sv", "rtl/ta_array.sv", "rtl/ta_requant.sv", "asic/ta_asic_tile.sv"], "tile_tests")
