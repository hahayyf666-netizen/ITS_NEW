"""Fail-closed audit of the RTL sparse-TU event trace."""
from __future__ import annotations

import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TRACE = ROOT / "05_audit" / "current" / "17" / "step12b_rtl_event_trace_normal.csv"


def main() -> int:
    rows = list(csv.DictReader(TRACE.open(encoding="utf-8", newline="")))
    cycles = [int(r["cycle"]) for r in rows]
    if any(b < a for a, b in zip(cycles, cycles[1:])):
        raise SystemExit("RTL trace cycle rollback")
    starts = [r for r in rows if r["event"] == "vector_start"]
    groups = [r for r in rows if r["event"] == "kernel_group"]
    writes = [r for r in rows if r["event"] == "result_write"]
    fires = [r for r in rows if r["event"] == "output_fire"]
    if len(starts) != 128 or len(groups) != 128 * 16 or len(writes) != 1024 or len(fires) != 1024:
        raise SystemExit(f"RTL trace counts wrong starts={len(starts)} groups={len(groups)} writes={len(writes)} fires={len(fires)}")
    for phase in ("1", "2"):
        p = [int(r["cycle"]) for r in starts if r["phase"] == phase]
        if len(p) != 64 or any(b - a != 16 for a, b in zip(p, p[1:])):
            raise SystemExit(f"phase {phase} vector II is not 16")
    per_vector: dict[tuple[str, str], list[int]] = {}
    for r in groups:
        key = (r["phase"], r["vector"])
        per_vector.setdefault(key, []).append(int(r["group"]))
    if any(vals != list(range(16)) for vals in per_vector.values()):
        raise SystemExit("kernel group sequence is not 0..15")
    group_cycle = {(r["phase"], r["vector"], r["group"]): int(r["cycle"]) for r in groups}
    for r in writes:
        key = (r["phase"], r["vector"], r["group"])
        if int(r["cycle"]) != group_cycle.get(key, -1):
            raise SystemExit("result_write is not same-cycle with horizontal kernel_group")
    indices = [int(r["index"]) for r in fires]
    if indices != list(range(1024)):
        raise SystemExit("output fire index/order mismatch")
    print(f"STEP12B_RTL_TRACE_PASS rows={len(rows)} starts=128 groups={len(groups)} writes=1024 fires=1024")
    return 0


if __name__ == "__main__":
    sys.exit(main())
