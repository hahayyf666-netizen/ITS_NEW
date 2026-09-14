#!/usr/bin/env python3
"""Generate dense/basis active-LFNST vectors for the integrated wrapper.

The ordinary Gate-C campaign intentionally uses sparse stress inputs.  This
focused set exercises every low-frequency diagonal gather/scatter position in
both LFNST dimensions and every set/index selector, while retaining the same
independent Gate-A Oracle used by the main campaign.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from validate_gate_c_model import (
    CANONICAL,
    Descriptor,
    diag_scan,
    inverse_2d,
    load_json,
    output_beats,
)


def add_case(cases: list[tuple[Descriptor, list[tuple[int, int]]]],
             desc: Descriptor, entries: list[tuple[int, int]]) -> None:
    cases.append((desc, sorted(entries)))


def pack_beat(values: tuple[int, int, int, int]) -> int:
    packed = 0
    for lane, value in enumerate(values):
        packed |= (value & 0x3FF) << (10 * lane)
    return packed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    canonical = load_json(CANONICAL)
    cases: list[tuple[Descriptor, list[tuple[int, int]]]] = []

    # nTrs=16: 4x4 support and nonzeroSize=8.  Terms 0..15 are all sent,
    # including the eight terms that the contract requires the engine to
    # ignore for nonzeroSize=8.
    scan4 = diag_scan(4, 4)
    for set_idx in range(4):
        for idx in (1, 2):
            for term, value in enumerate([32767, -32768] * 8):
                row, col = scan4[term]
                add_case(cases, Descriptor(4, 4, 0, 0, set_idx, idx),
                         [(row * 4 + col, value)])

    # nTrs=48: 8x16 support and nonzeroSize=16.  This exercises the complete
    # 16-term gather and all 48 output scatter positions for every selector.
    scan8 = diag_scan(8, 8)
    for set_idx in range(4):
        for idx in (1, 2):
            for term in range(16):
                row, col = scan8[term]
                value = 32767 if term % 2 == 0 else -32768
                add_case(cases, Descriptor(8, 16, 0, 0, set_idx, idx),
                         [(row * 8 + col, value)])

    # Dense directed patterns ensure accumulation and writeback are also
    # exercised when multiple gather terms are simultaneously nonzero.
    add_case(cases, Descriptor(4, 4, 0, 0, 0, 1),
             [(row * 4 + col, 257 if i % 2 == 0 else -311)
              for i, (row, col) in enumerate(scan4)])
    add_case(cases, Descriptor(8, 16, 0, 0, 3, 2),
             [(row * 8 + col, 1024 - 37 * i if i % 2 == 0
               else -1024 + 29 * i) for i, (row, col) in enumerate(scan8[:16])])

    lines = [str(len(cases))]
    total_beats = 0
    for desc, entries in cases:
        coeff = [[0 for _ in range(desc.width)] for _ in range(desc.height)]
        for address, value in entries:
            row, col = divmod(address, desc.width)
            coeff[row][col] = value
        wide = inverse_2d(coeff, desc.width, desc.height, desc.hor, desc.ver,
                          desc.set_idx, desc.lfnst_idx, canonical)
        beats = output_beats(wide, "LOW10")
        lines.append(f"{desc.pack():06x} {len(entries)} {len(beats)}")
        lines.extend(f"{address} {value}" for address, value in entries)
        lines.extend(f"{pack_beat(beat):010x}" for beat in beats)
        total_beats += len(beats)

    encoded = ("\n".join(lines) + "\n").encode("ascii")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(encoded)
    print(json.dumps({
        "status": "PASS_GENERATE_LFNST_WRAPPER_VECTORS",
        "cases": len(cases),
        "beats": total_beats,
        "ntrs16_cases": 64 + 1,
        "ntrs48_cases": 128 + 1,
        "all_gather_terms": True,
        "all_set_index": True,
        "sha256": hashlib.sha256(encoded).hexdigest().upper(),
        "canonical": str(CANONICAL),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
