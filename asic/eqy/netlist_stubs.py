"""Write empty Verilog modules for the physical-only cells in an OpenLane netlist.

    python3 asic/eqy/netlist_stubs.py <netlist.v> <liberty.lib> <stubs.v>

Fill, tap and decap cells are placed by OpenLane but have no logic, and some
are not in the liberty file the equivalence check reads cell functions from.
Every cell type the netlist uses that the liberty file does not define gets
an empty module here, but only if each of its instances connects no ports;
any other missing cell stops the script, so a real logic cell can never be
stubbed out by accident.
"""
import re
import sys
from pathlib import Path


def main():
    netlist, liberty, out = map(Path, sys.argv[1:4])
    defined = set(re.findall(r'^\s*cell\s*\(\s*"?([\w$]+)"?\s*\)', liberty.read_text(), re.M))
    text = netlist.read_text()
    # "<type> <instance> ( ... );" at the start of a statement
    instances = re.findall(r'^\s*(sky130_\w+)\s+(\\?\S+)\s*\((.*?)\);', text, re.M | re.S)
    missing = {}
    for cell, _name, ports in instances:
        if cell in defined:
            continue
        missing.setdefault(cell, 0)
        missing[cell] += 1
        if ports.strip():
            raise SystemExit(f"{cell} is not in {liberty.name} but has port connections: not a physical-only cell")
    out.write_text("".join(f"(* blackbox *) module {cell}(); endmodule\n" for cell in sorted(missing)))
    print("stubbed physical-only cells: " + ", ".join(f"{c} ({n})" for c, n in sorted(missing.items())))


if __name__ == "__main__":
    main()
