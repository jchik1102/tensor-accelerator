"""Tabulate the OpenLane runs whose metrics are saved under results/asic/.

Usage (repository root): python3 asic/compare_runs.py
Writes results/asic/runs.txt from results/asic/<final>/metrics.json and
results/asic/explore/<tag>/metrics.json, for the compute tile and the single
PE, with each run's settings that differ from the first run of that design.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNS = [("p20", "explore/p20"), ("d20", "d20"), ("n20", "explore/n20"), ("h20", "explore/h20")]
# Single processing element (asic/pe/config.json), 10 ns clock.
PE_RUNS = [("pe10", "explore/pe10"), ("pe10d", "pe10d")]
METRICS = [("area_um2", "design__instance__area"), ("setup_ws_ns", "timing__setup__ws"),
           ("setup_vio", "timing__setup_vio__count"), ("hold_ws_ns", "timing__hold__ws"),
           ("drc_magic", "magic__drc_error__count"), ("drc_klayout", "klayout__drc_error__count"),
           ("lvs", "design__lvs_error__count"), ("antenna_nets", "route__antenna_violation__count"),
           ("max_slew", "design__max_slew_violation__count"), ("max_cap", "design__max_cap_violation__count"),
           ("max_fanout", "design__max_fanout_violation__count")]
SETTINGS = ["CLOCK_PERIOD", "SYNTH_STRATEGY", "RUN_POST_GRT_DESIGN_REPAIR", "RUN_HEURISTIC_DIODE_INSERTION",
            "HEURISTIC_ANTENNA_THRESHOLD", "GRT_ANTENNA_ITERS", "DESIGN_REPAIR_MAX_SLEW_PCT",
            "DESIGN_REPAIR_MAX_CAP_PCT", "GRT_DESIGN_REPAIR_MAX_SLEW_PCT", "GRT_DESIGN_REPAIR_MAX_CAP_PCT"]


def table(runs, lines):
    lines.append("run   " + " ".join(f"{name:>12}" for name, _ in METRICS))
    configs = {}
    for tag, folder in runs:
        metrics = json.loads((ROOT / "results/asic" / folder / "metrics.json").read_text())
        configs[tag] = json.loads((ROOT / "results/asic" / folder / "resolved.json").read_text())
        values = []
        for _, key in METRICS:
            v = metrics[key]
            values.append(f"{v:12.3f}" if isinstance(v, float) and not float(v).is_integer() else f"{int(v):12d}")
        lines.append(f"{tag:5} " + " ".join(values))
    first = configs[runs[0][0]]
    for tag, _ in runs:
        changed = [f"{k}={configs[tag].get(k)}" for k in SETTINGS if configs[tag].get(k) != first.get(k)]
        lines.append(f"{tag}: " + (", ".join(changed) if changed else "baseline settings"))


def main():
    lines = ["ta_asic_tile (8x8 array, requantizer, output stage), 20 ns"]
    table(RUNS, lines)
    lines += ["", "ta_pe (one processing element), 10 ns"]
    table(PE_RUNS, lines)
    (ROOT / "results/asic/runs.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
