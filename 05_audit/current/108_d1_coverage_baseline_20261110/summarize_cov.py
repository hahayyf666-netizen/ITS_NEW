#!/usr/bin/env python
"""Aggregate a ModelSim `vcover report` summary into DUT-only totals.

The per-instance summary lists every instance including testbench code.  A D1
baseline is only meaningful for the design under test, so instances whose
design unit ends in `_tb` are aggregated separately and reported apart.
"""

import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROW = re.compile(r"^\s+([A-Za-z][A-Za-z ]*?)\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)%\s*$")


def parse(path):
    rows = []  # (instance, unit, type, bins, hits, misses)
    inst = unit = None
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("=== Instance:"):
            inst = line.split(":", 1)[1].strip()
            unit = None
        elif line.startswith("=== Design Unit:"):
            unit = line.split(":", 1)[1].strip()
        elif "TOTAL ASSERTION COVERAGE" in line:
            break
        else:
            m = ROW.match(line)
            if m and inst:
                rows.append((inst, unit or "", m.group(1).strip(),
                             int(m.group(2)), int(m.group(3)), int(m.group(4))))
    return rows


def agg(rows, predicate):
    tot = defaultdict(lambda: [0, 0, 0])  # type -> bins, hits, misses
    for inst, unit, typ, bins, hits, misses in rows:
        if not predicate(unit, inst):
            continue
        t = tot[typ]
        t[0] += bins
        t[1] += hits
        t[2] += misses
    out = {}
    for typ, (bins, hits, misses) in sorted(tot.items()):
        pct = (100.0 * hits / bins) if bins else 0.0
        out[typ] = {"bins": bins, "hits": hits, "misses": misses, "coverage_pct": round(pct, 2)}
    return out


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "run" / "coverage_summary.txt"
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).parent / "run" / "COVERAGE_TOTALS.json"
    rows = parse(src)
    is_tb = lambda unit, inst: unit.split(".")[-1].endswith("_tb") or "/" not in inst.strip("/") and unit.split(".")[-1].endswith("_tb")
    dut = agg(rows, lambda u, i: not u.split(".")[-1].endswith("_tb"))
    tb = agg(rows, lambda u, i: u.split(".")[-1].endswith("_tb"))
    result = {"source": str(src), "instances": len({r[0] for r in rows}),
              "design_units": len({r[1] for r in rows}),
              "dut_only": dut, "testbench": tb}
    dst.write_text(json.dumps(result, indent=2), encoding="utf-8")

    print(f"instances={result['instances']} design_units={result['design_units']}\n")
    print(f"{'coverage type':<22}{'bins':>8}{'hits':>8}{'misses':>8}{'DUT %':>9}")
    print("-" * 55)
    for typ, v in dut.items():
        print(f"{typ:<22}{v['bins']:>8}{v['hits']:>8}{v['misses']:>8}{v['coverage_pct']:>8.2f}%")
    print(f"\nwritten: {dst}")


if __name__ == "__main__":
    main()