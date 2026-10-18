#!/usr/bin/env bash
# Equivalence of RTL and OpenLane netlists with EQY (make asic-eqy):
#   pe    rtl/ta_pe.sv against asic/pe/runs/pe10d/final/nl/ta_pe.nl.v
#   tile  asic/ta_asic_tile.sv (with the array, PE and requantizer RTL) against
#         asic/runs/<RUN_TAG>/final/nl/ta_asic_tile.nl.v
# The netlists are the routed ones from the runs the README reports (no power
# pins). Cell functions come from the sky130_fd_sc_hd liberty file; fill, tap
# and decap cells get empty modules (asic/eqy/netlist_stubs.py). The tile's
# gold is elaborated with Synlig in the OpenLane image, with the same FSM
# recoding the flow applied (asic/eqy/gold_synlig.ys). Logs in
# results/asic/eqy/; prints EQY_PE and EQY_TILE lines.
set -uo pipefail
cd "$(dirname "$0")/../.."
export PATH=$HOME/oss-cad-suite/bin:$PATH
RUN_TAG=${1:-d20}
PDK=${PDK_ROOT:-$HOME/.volare}/volare/sky130/versions/0fe599b2afb6708d281543108caf8310912f54af/sky130A
LIB=$PDK/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
OUT=results/asic/eqy
mkdir -p "$OUT" build/eqy/tile_gold

summary() {  # $1 = label, $2 = eqy output
  local proved total failed
  proved=$(grep -c "Successfully proved equivalence of partition\|Proved equivalence of partition" "$2")
  total=$(ls -d "$(dirname "$2")"/*/strategies/*/ 2>/dev/null | wc -l)
  failed=$(grep -oE "Failed to prove equivalence of partition [^ ]+" "$2" | sed 's/.*partition //' | tr '\n' ' ')
  if grep -q "DONE (PASS" "$2"; then echo "EQY_$1 PASS partitions=$total"
  else echo "EQY_$1 FAIL proved=$proved of $total; not proved: $failed"; fi
}

# Single PE
w=build/eqy/pe; rm -rf "$w"; mkdir -p "$w"
cp rtl/ta_pe.sv "$w"/
cp asic/pe/runs/pe10d/final/nl/ta_pe.nl.v "$w/netlist.v"
python3 asic/eqy/netlist_stubs.py "$w/netlist.v" "$LIB" "$w/stubs.v" > "$OUT/pe_stubs.txt"
sed "s|LIB|$LIB|; s|NETLIST|netlist.v|" asic/eqy/pe.eqy > "$w/pe.eqy"
(cd "$w" && eqy -f -j 16 pe.eqy > eqy.out 2>&1)
cp "$w/eqy.out" "$OUT/pe.log"
summary PE "$w/eqy.out" | tee "$OUT/summary.txt"

# Tile: gold through Synlig (OpenLane 2.3.10 image), then EQY
docker run --rm -v /mnt/c/projects:/mnt/c/projects -w "$PWD" ghcr.io/efabless/openlane2:2.3.10 \
  bash -c 'yosys -q -l build/eqy/tile_gold/gold_synlig.log asic/eqy/gold_synlig.ys' > /dev/null 2>&1
grep -A6 "Recoding FSM" build/eqy/tile_gold/gold_synlig.log > "$OUT/tile_gold_fsm.txt"
w=build/eqy/tile; rm -rf "$w"; mkdir -p "$w"
cp build/eqy/tile_gold/gold_synlig.il "$w"/
cp "asic/runs/$RUN_TAG/final/nl/ta_asic_tile.nl.v" "$w/netlist.v"
python3 asic/eqy/netlist_stubs.py "$w/netlist.v" "$LIB" "$w/stubs.v" > "$OUT/tile_stubs.txt"
sed "s|LIB|$LIB|; s|NETLIST|netlist.v|" asic/eqy/tile.eqy > "$w/tile.eqy"
# The 30-minute per-partition limit is in tile.eqy; the outer limit stops a
# solver that does not exit after its timeout.
(cd "$w" && timeout 7200 eqy -f -j 24 tile.eqy > eqy.out 2>&1)
cp "$w/eqy.out" "$OUT/tile.log"
summary TILE "$w/eqy.out" | tee -a "$OUT/summary.txt"
