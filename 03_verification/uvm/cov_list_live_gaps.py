#!/usr/bin/env python
"""Itemise the UVM statement/branch gaps outside the never-called block.

Lines 841-1085 of unified_its_wrapper.sv are six functions that nothing calls;
gaps there are dead code and need no stimulus.  Everything else needs a reason,
one line at a time.
"""
from __future__ import annotations

import csv
import sys
from collections import defaultdict
from pathlib import Path

BASE = Path(__file__).resolve().parent
RTL = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace"
           r"\its_push\02_rtl\rtl\unified_its_wrapper.sv")
DEAD_LO, DEAD_HI = 841, 1085


def load(path: Path) -> list[dict]:
    with open(path, encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))


def main() -> int:
    src = RTL.read_text(encoding="utf-8", errors="replace").splitlines()
    uvm = load(BASE / "UVM_GAPS.csv")

    for kind in ("Statement", "Branch", "Condition", "Expression"):
        rows = [r for r in uvm if r["coverage_type"] == kind]
        dead = [r for r in rows if DEAD_LO <= int(r["line"]) <= DEAD_HI]
        live = [r for r in rows if not (DEAD_LO <= int(r["line"]) <= DEAD_HI)]
        print(f"\n=== {kind}: {len(rows)} total, {len(dead)} in dead block "
              f"L{DEAD_LO}-{DEAD_HI}, {len(live)} elsewhere ===")
        if kind in ("Statement", "Branch"):
            for r in sorted(live, key=lambda x: int(x["line"])):
                ln = int(r["line"])
                text = src[ln - 1].strip() if 0 < ln <= len(src) else ""
                print(f"  {ln:>5}  {text[:96]}")

    # group the live gaps by contiguous line clusters for a compact story
    live_stmt = sorted({int(r["line"]) for r in uvm
                        if r["coverage_type"] == "Statement"
                        and not (DEAD_LO <= int(r["line"]) <= DEAD_HI)})
    print("\n=== live statement gap clusters ===")
    cluster: list[int] = []
    for ln in live_stmt:
        if cluster and ln - cluster[-1] <= 6:
            cluster.append(ln)
        else:
            if cluster:
                print(f"  {cluster[0]}-{cluster[-1]}  ({len(cluster)} lines)")
            cluster = [ln]
    if cluster:
        print(f"  {cluster[0]}-{cluster[-1]}  ({len(cluster)} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())