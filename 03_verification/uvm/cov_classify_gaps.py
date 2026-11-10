#!/usr/bin/env python
"""Classify the UVM flow's code-coverage gaps.

Two questions:

1. Which RTL routine does each uncovered statement/branch belong to?  A gap
   inside a function that is never called is dead code; a gap inside an
   always_comb is missing stimulus or a structurally unreachable path.

2. Which lines did the D1 directed suite cover that this UVM regression does
   not?  Those are the only gaps that are actually this testbench's fault.
   Everything else is either equal coverage or already explained.
"""
from __future__ import annotations

import csv
import re
import sys
from collections import defaultdict
from pathlib import Path

BASE = Path(__file__).resolve().parent
RTL = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace"
           r"\its_push\02_rtl\rtl\unified_its_wrapper.sv")
D2_CSV = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace"
              r"\closure_audit\d1\GAPS.csv")
UVM_CSV = BASE / "UVM_GAPS.csv"

FUNC_OPEN = re.compile(r"^\s*(?:automatic\s+|static\s+)*function\b")
TASK_OPEN = re.compile(r"^\s*task\b")
NAME_TAIL = re.compile(r"\b(\w+)\s*;")
ALWAYS = re.compile(r"^\s*(always_ff|always_comb|always_latch|always)\b")
INITIAL = re.compile(r"^\s*initial\b")


def routine_map(path: Path) -> dict[int, str]:
    """line number -> enclosing routine label.

    Function/task signatures wrap across lines in this RTL, so the name is not
    on the `function` line itself; look ahead a few lines for it.
    """
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    owner: dict[int, str] = {}
    stack: list[str] = []
    i = 0
    while i < len(lines):
        raw = lines[i]
        ln = i + 1
        if FUNC_OPEN.match(raw) or TASK_OPEN.match(raw):
            name = None
            for probe in range(i, min(i + 8, len(lines))):
                m = NAME_TAIL.search(lines[probe])
                if m:
                    name = m.group(1)
                    # a name equal to the keyword itself is not a name
                    if name not in ("function", "task", "automatic", "static"):
                        break
                    name = None
            stack.append(f"{name}()" if name else f"anonymous@{ln}")
            owner[ln] = stack[-1]
            i += 1
            continue
        if re.match(r"^\s*endfunction|^\s*endtask", raw):
            if stack:
                stack.pop()
            owner[ln] = stack[-1] if stack else "<top>"
            i += 1
            continue
        if ALWAYS.match(raw):
            stack.append(f"always@{ln}")
            owner[ln] = stack[-1]
            i += 1
            continue
        if INITIAL.match(raw):
            stack.append(f"initial@{ln}")
            owner[ln] = stack[-1]
            i += 1
            continue
        if re.match(r"^\s*end\b", raw) and stack and stack[-1].startswith(("always@", "initial@")):
            stack.pop()
        owner[ln] = stack[-1] if stack else "<top>"
        i += 1
    return owner


def load(path: Path) -> list[dict]:
    with open(path, encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))


def main() -> int:
    owner = routine_map(RTL)
    uvm = load(UVM_CSV)
    d2 = load(D2_CSV)

    # D1 gap line sets, wrapper only
    d1_stmt = {int(r["line"]) for r in d2
               if r["design_unit"] == "unified_its_wrapper"
               and r["coverage_type"] == "Statement"}
    d1_branch = {int(r["line"]) for r in d2
                 if r["design_unit"] == "unified_its_wrapper"
                 and r["coverage_type"] == "Branch"}

    print("=== D1 gap set size (wrapper only) ===")
    print(f"  statements: {len(d1_stmt)}   branches: {len(d1_branch)}")

    print("\n=== UVM gap count by type ===")
    by_type = defaultdict(int)
    for r in uvm:
        by_type[r["coverage_type"]] += 1
    for k, v in sorted(by_type.items()):
        print(f"  {k:<12} {v}")

    print("\n=== uncovered statements grouped by enclosing routine ===")
    stmt = [r for r in uvm if r["coverage_type"] == "Statement"]
    groups = defaultdict(list)
    for r in stmt:
        ln = int(r["line"])
        groups[owner.get(ln, "?")].append(ln)
    for name, lines in sorted(groups.items(), key=lambda kv: -len(kv[1])):
        print(f"  {name:<28} {len(lines):>4}   lines {min(lines)}-{max(lines)}")

    print("\n=== branches by routine ===")
    br = [r for r in uvm if r["coverage_type"] == "Branch"]
    bg = defaultdict(list)
    for r in br:
        ln = int(r["line"])
        bg[owner.get(ln, "?")].append(ln)
    for name, lines in sorted(bg.items(), key=lambda kv: -len(kv[1])):
        print(f"  {name:<28} {len(lines):>4}   lines {min(lines)}-{max(lines)}")

    # The useful set: lines D1 covered but UVM misses.
    uvm_stmt_lines = {int(r["line"]) for r in stmt}
    only_uvm = sorted(uvm_stmt_lines - d1_stmt)   # D1 did NOT miss these
    print("\n=== statements UVM misses that D1 covered (true UVM gap) ===")
    print(f"  {len(only_uvm)} line(s)")
    for ln in only_uvm:
        print(f"    {ln:>5}  [{owner.get(ln,'?'):<24}] {RTL.read_text(encoding='utf-8',errors='replace').splitlines()[ln-1].strip()[:80]}")

    uvm_br_lines = {int(r["line"]) for r in br}
    only_uvm_br = sorted(uvm_br_lines - d1_branch)
    print("\n=== branches UVM misses that D1 covered ===")
    print(f"  {len(only_uvm_br)} line(s): {only_uvm_br[:40]}")

    print("\n=== both flows miss (dead/unreachable candidates) ===")
    print(f"  statements: {len(uvm_stmt_lines & d1_stmt)}")
    print(f"  branches:   {len(uvm_br_lines & d1_branch)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())