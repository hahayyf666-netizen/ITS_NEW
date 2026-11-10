#!/usr/bin/env python
"""D2 gap attribution: turn the vcover detail report into RTL-level gap rows.

Every uncovered item in a `vcover report -details` file is printed with a
`***0***` hit count.  This script walks those rows, resolves each one back to
its RTL source line, and groups the result by design unit and source line so a
testbench owner can see exactly which RTL statements/branches never ran.
"""

import csv
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

BASE = Path(__file__).resolve().parent
SRC_ROOTS = [Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\its_push")]

SECTION = re.compile(r"^=+\s*(Branch|Statement|Condition|Expression|Toggle|FSM\w*) Details\s*=+$")
FILE_LINE = re.compile(r"^\s+File (.+\.sv)\s*$")
ROW_ZERO = re.compile(r"^\s+(\d+)\s+(.*?)\s*\*\*\*0\*\*\*\s*(.*)$")
# condition / expression sections: "Line  208 Item  1  <expr>" followed by
# "Row   1:    ***0***  <term>  <non-masking conditions>"
EXPR_HEADER = re.compile(r"^\s*Line\s+(\d+)\s+Item\s+\d+\s+(.*)$")
EXPR_ROW_ZERO = re.compile(r"^\s*Row\s+\d+:\s+\*\*\*0\*\*\*\s+(\S+)\s*(.*)$")
INST_LINE = re.compile(r"^=+ Instance: (\S+)")
UNIT_LINE = re.compile(r"^=+ Design Unit: work\.(\S+)")


def norm(path: str) -> Path:
    p = Path(path.strip().replace("/", "\\"))
    for root in SRC_ROOTS:
        if p.exists():
            return p
    return p


def main():
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else BASE / "missing_normal2.txt"
    out_json = Path(sys.argv[2]) if len(sys.argv) > 2 else BASE / "GAPS.json"
    out_csv = Path(sys.argv[3]) if len(sys.argv) > 3 else BASE / "GAPS.csv"

    gaps = []  # dicts
    unit = inst = None
    kind = None
    cur_file = None
    expr_line = None
    expr_text = ""

    for raw in src.read_text(encoding="utf-8", errors="replace").splitlines():
        m = INST_LINE.match(raw)
        if m:
            inst = m.group(1)
            continue
        m = UNIT_LINE.match(raw)
        if m:
            unit = m.group(1)
            continue
        m = SECTION.match(raw)
        if m:
            kind = m.group(1)
            expr_line = None
            continue
        m = FILE_LINE.match(raw)
        if m:
            cur_file = norm(m.group(1))
            continue
        if kind in ("Condition", "Expression"):
            m = EXPR_HEADER.match(raw)
            if m:
                expr_line = int(m.group(1))
                expr_text = m.group(2).strip()
                continue
            m = EXPR_ROW_ZERO.match(raw)
            if m and expr_line and unit and cur_file:
                gaps.append({
                    "design_unit": unit,
                    "coverage_type": kind,
                    "file": cur_file.name,
                    "line": expr_line,
                    "item": m.group(1).strip(),
                    "source": expr_text,
                    "instance": inst,
                })
            continue
        m = ROW_ZERO.match(raw)
        if m and kind and unit and cur_file:
            gaps.append({
                "design_unit": unit,
                "coverage_type": kind,
                "file": cur_file.name,
                "line": int(m.group(1)),
                "item": m.group(2).strip(),
                "source": m.group(3).strip(),
                "instance": inst,
            })

    # total number of instances each design unit is elaborated as, so a gap can
    # be classified as global (never covered anywhere) vs instance-specific
    inst_totals = defaultdict(set)
    summary = BASE / "run" / "coverage_summary.txt"
    if summary.exists():
        u = None
        for raw in summary.read_text(encoding="utf-8", errors="replace").splitlines():
            if raw.startswith("=== Instance:"):
                cur = raw.split(":", 1)[1].strip()
            elif raw.startswith("=== Design Unit:"):
                u = raw.split(":", 1)[1].strip().split(".")[-1]
                inst_totals[u].add(cur)

    # de-duplicate: same design unit + type + line + item across many instances
    keys = defaultdict(set)
    for g in gaps:
        keys[(g["design_unit"], g["coverage_type"], g["line"], g["item"])].add(g["instance"])

    rows = []
    for (unit, kind, line, item), insts in keys.items():
        total = len(inst_totals.get(unit, ())) or len(insts)
        rows.append({
            "design_unit": unit,
            "coverage_type": kind,
            "line": line,
            "item": item,
            "instances_missed": len(insts),
            "instances_total": total,
            "global_gap": len(insts) >= total,
            "example_instance": sorted(insts)[0],
        })
    rows.sort(key=lambda r: (r["design_unit"], r["coverage_type"], r["line"]))

    # attach RTL source text
    cache = {}
    for r in rows:
        f = next((p for p in [BASE / "x"] if False), None)
        for root in SRC_ROOTS:
            f = root / "02_rtl" / "rtl" / f'{r["design_unit"]}.sv'
            if f.exists():
                break
        if f and f.exists():
            if f not in cache:
                cache[f] = f.read_text(encoding="utf-8", errors="replace").splitlines()
            lines = cache[f]
            r["source_text"] = lines[r["line"] - 1].strip() if 0 < r["line"] <= len(lines) else ""
        else:
            r["source_text"] = ""

    out_json.write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    with open(out_csv, "w", newline="", encoding="utf-8-sig") as fh:
        w = csv.DictWriter(fh, fieldnames=["design_unit", "coverage_type", "line", "item",
                                           "instances_missed", "instances_total", "global_gap",
                                           "source_text", "example_instance"])
        w.writeheader()
        w.writerows(rows)

    # summary: separate true global gaps from instance-specific ones
    by_unit = defaultdict(lambda: defaultdict(int))
    glob = defaultdict(lambda: defaultdict(int))
    for r in rows:
        by_unit[r["design_unit"]][r["coverage_type"]] += 1
        if r["global_gap"]:
            glob[r["design_unit"]][r["coverage_type"]] += 1

    print(f"gap rows (deduplicated): {len(rows)}   raw uncovered items: {len(gaps)}\n")
    print(f"{'design unit':<28}{'inst':>5}{'Branch':>8}{'Stmt':>7}{'Cond':>7}{'Expr':>7}"
          f"{'| global B/S/C/E':>20}")
    print("-" * 90)
    for unit in sorted(by_unit, key=lambda u: -sum(glob[u].values())):
        d, g = by_unit[unit], glob[unit]
        n = len(inst_totals.get(unit, ()))
        print(f"{unit:<28}{n:>5}{d.get('Branch',0):>8}{d.get('Statement',0):>7}"
              f"{d.get('Condition',0):>7}{d.get('Expression',0):>7}"
              f"{'|':>8}{g.get('Branch',0):>4}/{g.get('Statement',0)}/{g.get('Condition',0)}/{g.get('Expression',0)}")
    print(f"\nwritten: {out_json.name}, {out_csv.name}")


if __name__ == "__main__":
    main()