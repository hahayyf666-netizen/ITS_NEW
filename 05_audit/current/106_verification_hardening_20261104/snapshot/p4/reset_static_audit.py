"""P4 static pass: classify sequential elements by reset coverage.

For every always_ff block, collect the identifiers assigned inside the reset
branch (`if (!rst_n) begin ... end`) and the identifiers assigned outside it.
Registers assigned only outside the reset branch have no defined post-reset
value; they need a category before they can be called safe.

This is a syntactic pass. It produces candidates, not verdicts.
"""
from __future__ import annotations
import json, re, sys
from collections import defaultdict
from pathlib import Path

RTL = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\its_push\02_rtl\rtl")
OUT = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\closure_audit\p4")
FILES = ["unified_its_wrapper.sv", "unified_p4_kernel.sv", "bounded_lfnst_engine.sv",
         "its_input_cache_bank.sv", "its_simple_ram.sv"]

ASSIGN = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*(\[[^\]]*\])*\s*<=")


def assigns_at_top_level(line):
    """Yield identifiers assigned with <= at parenthesis depth 0.

    A depth check is required: `(active_size <= 7'd4)` is a comparison, not an
    assignment, and treating it as one invents phantom registers.
    """
    s = re.sub(r"//.*", "", line)
    depth = 0
    hits = []
    for i, ch in enumerate(s):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == "<" and i + 1 < len(s) and s[i + 1] == "=" and depth == 0:
            m = None
            for cand in ASSIGN.finditer(s[:i + 2]):
                m = cand
            if m:
                hits.append(m.group(1))
    return hits


def block_end(lines, start):
    """Return index of the `end` matching the `begin` region starting at start."""
    depth = 0
    started = False
    for i in range(start, len(lines)):
        s = re.sub(r"//.*", "", lines[i])
        for tok in re.findall(r"\b(begin|end)\b", s):
            if tok == "begin":
                depth += 1
                started = True
            else:
                depth -= 1
                if started and depth == 0:
                    return i
    return len(lines) - 1


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    report = {}

    for fname in FILES:
        text = (RTL / fname).read_text(encoding="utf-8", errors="replace").replace("\r\n", "\n")
        lines = text.split("\n")
        blocks = []
        for i, ln in enumerate(lines):
            if "always_ff" not in ln:
                continue
            bstart = i
            bend = block_end(lines, bstart)
            body = lines[bstart:bend + 1]
            # locate reset branch
            rst_idx = None
            for j, b in enumerate(body):
                if re.search(r"if\s*\(\s*!\s*rst_n\s*\)", b):
                    rst_idx = j
                    break
            reset_regs, other_regs = set(), set()
            if rst_idx is not None:
                rstart = rst_idx
                rend = block_end(body, rstart)
                for b in body[rstart:rend + 1]:
                    reset_regs.update(assigns_at_top_level(b))
                for b in body[:rstart] + body[rend + 1:]:
                    other_regs.update(assigns_at_top_level(b))
            else:
                for b in body:
                    other_regs.update(assigns_at_top_level(b))
            blocks.append({"start_line": bstart + 1, "end_line": bend + 1,
                           "has_reset": rst_idx is not None,
                           "reset_regs": sorted(reset_regs),
                           "unreset_regs": sorted(other_regs - reset_regs)})

        all_unreset = defaultdict(list)
        for b in blocks:
            for r in b["unreset_regs"]:
                all_unreset[r].append(b["start_line"])
        report[fname] = {
            "always_ff_blocks": len(blocks),
            "blocks_without_any_reset": sum(1 for b in blocks if not b["has_reset"]),
            "reset_registers": len({r for b in blocks for r in b["reset_regs"]}),
            "unreset_registers": len(all_unreset),
            "unreset_detail": {k: v for k, v in sorted(all_unreset.items())},
        }

    (OUT / "P4_RESET_STATIC.json").write_text(json.dumps({
        "schema": "its.p4.reset_static.v1",
        "scope": "syntactic candidate list; every entry still needs a category",
        "files": report,
    }, indent=2) + "\n", encoding="utf-8")

    for f, r in report.items():
        print(f"{f}: blocks={r['always_ff_blocks']} no_reset_blocks={r['blocks_without_any_reset']} "
              f"reset_regs={r['reset_registers']} unreset_regs={r['unreset_registers']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())