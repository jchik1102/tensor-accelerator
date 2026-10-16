#!/usr/bin/env bash
# Simulate asic/ta_asic_tile.sv against the Python reference with Icarus Verilog.
#   bash asic/run-tile-sim.sh rtl                 the RTL
#   bash asic/run-tile-sim.sh gl NETLIST.v        a sky130 gate-level netlist
# Needs iverilog (OSS CAD Suite) and, for gl, the sky130A PDK (PDK_ROOT,
# default ~/.volare). Prints TILE_PASS/TILE_FAIL; exits 1 unless TILE_PASS.
set -euo pipefail
[[ -d $HOME/oss-cad-suite/bin ]] && export PATH=$HOME/oss-cad-suite/bin:$PATH
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=${1:?rtl or gl}
VENV=${VENV:-$HOME/.venvs/tensor-accelerator}
SEED=${SEED:-1}; TESTS=${TESTS:-24}
WORK=$ROOT/artifacts/asic/sim-$MODE
mkdir -p "$WORK"
(cd "$ROOT" && PYTHONPATH=. "$VENV/bin/python" asic/tile_vectors.py "$WORK" --n 8 --tests "$TESTS" --seed "$SEED")
if [[ $MODE == rtl ]]; then
  # DEFINES, e.g. -DTA_MUTATE_PE, selects one of the RTL's built-in mutations.
  iverilog -g2012 ${DEFINES:-} -o "$WORK/tb.vvp" -s ta_asic_tile_tb \
    "$ROOT"/rtl/ta_pe.sv "$ROOT"/rtl/ta_array.sv "$ROOT"/rtl/ta_requant.sv \
    "$ROOT"/asic/ta_asic_tile.sv "$ROOT"/asic/ta_asic_tile_tb.sv
else
  NETLIST=${2:?netlist}
  LIB=$(ls -d "${PDK_ROOT:-$HOME/.volare}"/volare/sky130/versions/*/sky130A/libs.ref/sky130_fd_sc_hd/verilog | head -1)
  iverilog -g2012 -DGL -DFUNCTIONAL -DUNIT_DELAY=#1 -o "$WORK/tb.vvp" -s ta_asic_tile_tb \
    "$LIB/primitives.v" "$LIB/sky130_fd_sc_hd.v" "$NETLIST" "$ROOT"/asic/ta_asic_tile_tb.sv
fi
(cd "$WORK" && vvp -n tb.vvp +TESTS="$TESTS") | tee "$WORK/sim.log"
grep -q '^TILE_PASS' "$WORK/sim.log"
