#!/usr/bin/env bash
# Copy the logs that back the README numbers from artifacts/ (git-ignored)
# into results/, with a provenance file. Run after scripts/regress.ps1 and,
# for the accuracy numbers, after `python -m host.ta.evaluate_accuracy`.
set -euo pipefail
cd "$(dirname "$0")/.."
out=results
mkdir -p "$out/sim-n4" "$out/sim-n8"
# Only the logs scripts/regress.ps1 writes for each array size; anything else
# in artifacts/ may be left over from an older run.
n4_logs="core-1.log core-42.log core-20261008.log quant-clean.log adapter-clean.log mutation-pe.log mutation-round.log core-replay-42.log"
n8_logs="core-1.log core-42.log core-20261008.log mutation-bank.log"
for n in 4 8; do
  src=artifacts/sim; logs=$n4_logs
  [[ $n == 8 ]] && { src=artifacts/sim-n8; logs=$n8_logs; }
  for f in $logs; do
    [[ -f $src/$f ]] && cp "$src/$f" "$out/sim-n$n/"
  done
  report=$(ls -d "$src"/coverage-42-*/functionalCoverageReport 2>/dev/null | sort | tail -1 || true)
  [[ -n $report ]] && cp "$report/xcrg_func_cov_report.txt" "$out/sim-n$n/coverage-42.txt"
done
[[ -f artifacts/hex-check-n8-clean/run.log ]] && cp artifacts/hex-check-n8-clean/run.log "$out/hex-check-n8.log"
[[ -f artifacts/accuracy-comparison.json ]] && cp artifacts/accuracy-comparison.json "$out/"
{
  echo "collected: $(date -Iseconds)"
  echo "commit: $(git rev-parse HEAD)$(git -c core.autocrlf=true diff --quiet HEAD -- rtl tb host fpga scripts || echo ' (+ uncommitted changes)')"
} > "$out/PROVENANCE.txt"
echo "COLLECTED into $out/"
