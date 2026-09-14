"""Generate deterministic ModelSim vectors for the Gate-B P4 RTL.

Expected values come from the canonical coefficient matrices and the
independent row-wise Oracle in validate_gate_b.py.  The generated text file
is a simulation input artifact; it is not produced by the RTL implementation.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from validate_gate_b import CANONICAL, oracle_1d, vector


CASES = [(0, n) for n in (4, 8, 16, 32, 64)]
CASES += [(1, n) for n in (4, 8, 16, 32)]
CASES += [(2, n) for n in (4, 8, 16, 32)]
PATTERNS = (
    ("zero", 0),
    ("boundary", 1),
    ("random", 7),
    ("random", 19),
    ("extreme", 41),
    ("random", 73),
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    canonical = json.loads(CANONICAL.read_text(encoding="utf-8"))
    records: list[tuple[int, int, int, list[int], list[int]]] = []
    for tr_type, n in CASES:
        for stage_sel, shift in ((0, 7), (1, 10)):
            for kind, salt in PATTERNS:
                samples = vector(0x2468 + salt, n, kind)
                expected = oracle_1d(canonical, samples, tr_type, n, shift)
                records.append((tr_type, n, stage_sel, samples, expected))

    lines = [str(len(records))]
    for tr_type, n, stage_sel, samples, expected in records:
        lines.append(f"{tr_type} {n} {stage_sel}")
        lines.append(" ".join(str(value) for value in samples))
        for group in range(n // 4):
            base = group * 4
            lines.append(" ".join(str(value) for value in expected[base:base + 4]))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(("\n".join(lines) + "\n").encode("ascii"))
    print(json.dumps({
        "status": "PASS",
        "cases": len(records),
        "one_d_modes": len(CASES),
        "stages": 2,
        "patterns_per_stage": len(PATTERNS),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
