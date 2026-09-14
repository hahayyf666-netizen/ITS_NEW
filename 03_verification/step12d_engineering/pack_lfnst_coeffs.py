#!/usr/bin/env python3
"""Pack the canonical LFNST ROM into one bounded issue-group word.

The source ROM stores each LFNST matrix row as 16 signed 16-bit entries.
The synthesizable engine consumes four rows per issue cycle, so this script
reorders the immutable canonical data into 128 words of 4x16 coefficients.
"""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path


def read_values(path: Path) -> list[int]:
    values: list[int] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("//", 1)[0].strip()
        if not line:
            continue
        for token in line.split():
            value = int(token, 16)
            if value & 0x8000:
                value -= 0x10000
            values.append(value)
    if len(values) != 8192:
        raise ValueError(f"expected 8192 coefficients, got {len(values)}")
    return values


def bundle_index(ntrs: int, set_idx: int, lfnst_idx: int, group: int) -> int:
    if ntrs == 16:
        return set_idx * 8 + (lfnst_idx - 1) * 4 + group
    return 32 + set_idx * 24 + (lfnst_idx - 1) * 12 + group


def pack(values: list[int]) -> list[int]:
    bundles = [0] * 128
    for ntrs, region_base, groups in ((16, 0, 4), (48, 2048, 12)):
        for set_idx in range(4):
            for lfnst_idx in (1, 2):
                matrix_base = region_base + set_idx * (512 if ntrs == 16 else 1536)
                matrix_base += (lfnst_idx - 1) * (256 if ntrs == 16 else 768)
                for group in range(groups):
                    word = 0
                    for lane in range(4):
                        row = group * 4 + lane
                        for term in range(16):
                            value = values[matrix_base + row * 16 + term] & 0xFFFF
                            word |= value << ((lane * 16 + term) * 16)
                    bundles[bundle_index(ntrs, set_idx, lfnst_idx, group)] = word
    return bundles


def write_hex(path: Path, bundles: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(f"{word:0256x}" for word in bundles) + "\n",
                    encoding="ascii")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("outputs", nargs="+", type=Path)
    args = parser.parse_args()
    source_bytes = args.source.read_bytes()
    values = read_values(args.source)
    bundles = pack(values)
    for output in args.outputs:
        write_hex(output, bundles)
    payload = b"".join(word.to_bytes(128, "big") for word in bundles)
    print({
        "status": "PASS_PACK_LFNST_COEFFICIENTS",
        "source_sha256": hashlib.sha256(source_bytes).hexdigest().upper(),
        "bundle_count": len(bundles),
        "bundle_bits": 1024,
        "packed_sha256": hashlib.sha256(payload).hexdigest().upper(),
        "outputs": [str(path) for path in args.outputs],
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
