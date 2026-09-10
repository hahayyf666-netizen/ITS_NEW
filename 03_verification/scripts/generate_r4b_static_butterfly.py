#!/usr/bin/env python3
"""Generate the R4B event-unrolled butterfly statement include.

The source CSV is the read-only R4B_PRE connectivity audit output copied into
this complete project.  This generator does not derive a new butterfly graph:
it mechanically emits one fixed destination/source statement per audited
event, preserving the event phase, operation, source kind and IDs.
"""
from __future__ import annotations

import csv
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CSV_PATH = ROOT / "03_verification" / "output" / "r4b_pre_butterfly_audit" / "r4b_pre_butterfly_events.csv"
OUT_PATH = ROOT / "02_rtl" / "rtl" / "p2f_r4b_static_butterfly.svh"


def src_expr(obj: dict) -> str:
    kind = obj["kind"]
    idx = int(obj["id"])
    if kind == "dot":
        return f"$signed(dot_value_bank[bf_bank][{idx}])"
    if kind == "signal":
        return f"$signed(signal_reg[{idx}])"
    raise ValueError(f"unsupported source kind: {kind!r}")


def main() -> int:
    rows = list(csv.DictReader(CSV_PATH.open("r", encoding="utf-8", newline="")))
    if len(rows) != 124:
        raise SystemExit(f"expected 124 events, found {len(rows)}")

    seen_dest = set()
    lines = [
        "// R4B_EVENT_STATIC_BEGIN",
        "// Generated mechanically from r4b_pre_butterfly_events.csv.",
        "// Every audited event has a fixed phase, destination and source IDs.",
        "// bf_bank/bf_vector_id remain the only dynamic context selectors.",
        "if (bf_active) begin",
    ]
    for row in rows:
        phase = int(row["phase"])
        dest = int(row["destination"])
        if dest in seen_dest:
            raise SystemExit(f"duplicate destination {dest}")
        seen_dest.add(dest)
        even = json.loads(row["even"])
        odd = json.loads(row["odd"])
        op = row["operation"]
        if op not in {"add", "sub"}:
            raise SystemExit(f"unsupported operation {op!r}")
        symbol = "+" if op == "add" else "-"
        lines.extend(
            [
                f"    if (bf_cycle == 6'd{phase}) begin",
                f"        signal_reg[{dest}] <= {src_expr(even)} {symbol} {src_expr(odd)};",
                f"        signal_vector[{dest}] <= bf_vector_id;",
                "    end",
            ]
        )
    if len(seen_dest) != 124:
        raise SystemExit(f"expected 124 unique destinations, found {len(seen_dest)}")
    lines.extend(["end", "// R4B_EVENT_STATIC_END", ""])
    OUT_PATH.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print(f"generated {OUT_PATH}")
    print(f"events={len(rows)} destinations={len(seen_dest)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
