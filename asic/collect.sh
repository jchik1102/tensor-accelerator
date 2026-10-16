#!/usr/bin/env bash
# Copy the reports behind the README's ASIC numbers from an OpenLane run
# (asic/runs/TAG) into results/asic/TAG/. The GDS and other large views stay
# in the run directory, which Git ignores.
#   bash asic/collect.sh TAG [DESIGN_DIR]   (DESIGN_DIR defaults to asic; asic/pe for the PE)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAG=${1:?run tag}
RUN=$ROOT/${2:-asic}/runs/$TAG
OUT=$ROOT/results/asic/$TAG
[[ -f $RUN/final/metrics.json ]] || { echo "no finished run at $RUN"; exit 1; }
mkdir -p "$OUT"; rm -rf "${OUT:?}"/*
step() { ls -d "$RUN"/[0-9]*-"$1"* 2>/dev/null | sort -V | tail -1; }
cp "$RUN"/final/metrics.json "$RUN"/final/metrics.csv "$RUN"/resolved.json "$OUT"/
cp "$RUN"/flow.log "$RUN"/warning.log "$RUN"/error.log "$OUT"/ 2>/dev/null || true
cp "$(step yosys-synthesis)"/reports/stat.rpt "$OUT"/synthesis-stat.rpt
cp "$(step openroad-stapostpnr)"/summary.rpt "$OUT"/sta-signoff-summary.rpt
for c in nom_tt_025C_1v80 max_ss_100C_1v60; do
  # the worst setup path only (the full report is several MB)
  awk '{print} /slack \(/ {exit}' "$(step openroad-stapostpnr)/$c/max.rpt" > "$OUT/sta-$c-worst-setup.rpt"
done
# slew/cap/fanout checks in the slow corner: the 40 worst pins of each, and the counts
awk '/^max (slew|fanout|capacitance)$/ {n=44} n > 0 {print; n--} / violation count / {print}'   "$(step openroad-stapostpnr)/max_ss_100C_1v60/checks.rpt" > "$OUT/sta-max_ss_100C_1v60-checks.rpt"
cp "$(step openroad-irdropreport)"/*.rpt "$OUT"/ 2>/dev/null || true
cp "$(step magic-drc)"/reports/drc_violations.magic.rpt "$OUT"/ 2>/dev/null || true
cp "$(step klayout-drc)"/reports/drc_violations.klayout.json "$OUT"/ 2>/dev/null || true
cp "$(step netgen-lvs)"/reports/lvs.netgen.rpt "$OUT"/ 2>/dev/null || true
cp "$(step openroad-checkantennas)"/reports/antenna_summary.rpt "$OUT"/ 2>/dev/null || true
cp "$(step misc-reportmanufacturability)"/manufacturability.rpt "$OUT"/ 2>/dev/null || true

# Layout render (routing layers only) with KLayout from the OpenLane image.
PDK=$(ls -d "${PDK_ROOT:-$HOME/.volare}"/volare/sky130/versions/*/sky130A | head -1)
docker run --rm -v "$ROOT":/w -v "$PDK":/pdk -w /w ghcr.io/efabless/openlane2:2.3.10 \
  klayout -zz -rd gds="${RUN#$ROOT/}/final/gds/$(basename "$(ls "$RUN"/final/gds/*.gds | head -1)")" -rd lyp=/pdk/libs.tech/klayout/tech/sky130A.lyp \
  -rd png="results/asic/$TAG/layout.png" -r asic/render.py
