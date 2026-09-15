#!/usr/bin/env python3
"""Prove the P3 bank-local V-write map is equivalent to the frozen map."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


WIDTHS = (4, 8, 16, 32, 64)
HEIGHTS = (4, 8, 16, 32, 64)


def old_map(row: int, col: int, width: int) -> tuple[int, int]:
    return ((row + col) & 3, (row >> 2) * width + col)


def new_map(group: int, lane: int, col: int, width: int) -> tuple[int, int]:
    return ((lane + (col & 3)) & 3, group * width + col)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    checks = 0
    collisions = 0
    mismatches: list[dict[str, int]] = []
    for width in WIDTHS:
        for height in HEIGHTS:
            groups = (height + 3) // 4
            for group in range(groups):
                banks: list[int] = []
                for lane in range(4):
                    row = group * 4 + lane
                    if row >= height:
                        continue
                    for col in range(width):
                        old = old_map(row, col, width)
                        new = new_map(group, lane, col, width)
                        checks += 1
                        if old != new:
                            mismatches.append(
                                {"width": width, "height": height,
                                 "group": group, "lane": lane,
                                 "col": col, "old_bank": old[0],
                                 "new_bank": new[0], "old_local": old[1],
                                 "new_local": new[1]}
                            )
                    banks.append(new_map(group, lane, 0, width)[0])
                if len(banks) != len(set(banks)):
                    collisions += 1

    result = {
        "schema": "step12f.p3.intermediate_mapping_proof.v1",
        "status": "PASS" if not mismatches and not collisions else "FAIL",
        "widths": list(WIDTHS),
        "heights": list(HEIGHTS),
        "coordinate_checks": checks,
        "group_bank_collision_checks": sum(
            (h + 3) // 4 for h in HEIGHTS for _w in WIDTHS
        ),
        "collisions": collisions,
        "mismatch_count": len(mismatches),
        "mismatches": mismatches[:8],
        "frozen_mapping": "bank=(row+col)&3; local=(row>>2)*width+col",
        "p3_mapping": "bank=(lane+col[1:0])&3; local=group*width+col",
    }
    payload = json.dumps(result, indent=2, sort_keys=True).encode("utf-8")
    result["sha256"] = hashlib.sha256(payload).hexdigest()
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n",
                   encoding="utf-8")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
