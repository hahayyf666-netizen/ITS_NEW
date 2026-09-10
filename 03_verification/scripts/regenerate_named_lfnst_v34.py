"""Regenerate only named LFNST goldens affected by nonZeroSize.

Inputs are preserved.  Golden values come from ref_model.py, never from RTL.
"""

from __future__ import annotations

import re
from pathlib import Path
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[1]
TV_DIR = ROOT / "03_verification" / "tb" / "test_vectors"
sys.path.insert(0, str(SCRIPT_DIR))
from ref_model import its_inverse_transform, flatten_raster  # noqa: E402


def read_sparse_input(path: Path, width: int, height: int):
    data = [[0] * width for _ in range(height)]
    for raw in path.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        word = int(raw, 16)
        pos = (word >> 16) & 0xFFFF
        value = word & 0xFFFF
        if value & 0x8000:
            value -= 0x10000
        if pos >= width * height:
            raise ValueError(f"input index {pos} out of range for {width}x{height}")
        data[pos // width][pos % width] = value
    return data


def to_hex10(value: int) -> str:
    return f"{value & 0x3FF:03X}"


def decode_case(stem: str):
    if stem.startswith("lfnst16_"):
        m = re.fullmatch(r"lfnst16_s([0-3])_i([12])", stem)
        if not m:
            raise ValueError(stem)
        return 4, 4, 0, 0, int(m.group(1)), int(m.group(2))
    if stem.startswith("lfnst48_"):
        m = re.fullmatch(r"lfnst48_s([0-3])_i([12])", stem)
        if not m:
            raise ValueError(stem)
        return 8, 8, 0, 0, int(m.group(1)), int(m.group(2))
    m = re.fullmatch(r"dct2_(4|8)x\1_lfnst([12])_s([0-3])", stem)
    if not m:
        raise ValueError(stem)
    n = int(m.group(1))
    return n, n, 0, 0, int(m.group(3)), int(m.group(2))


def main() -> int:
    stems = []
    for n in (4, 8):
        for idx in (1, 2):
            for sidx in range(4):
                stems.append(f"dct2_{n}x{n}_lfnst{idx}_s{sidx}")
    for prefix in ("lfnst16", "lfnst48"):
        for sidx in range(4):
            for idx in (1, 2):
                stems.append(f"{prefix}_s{sidx}_i{idx}")

    for stem in stems:
        width, height, tr_hor, tr_ver, set_idx, lfnst_idx = decode_case(stem)
        inp = read_sparse_input(TV_DIR / f"{stem}_input.hex", width, height)
        output = its_inverse_transform(inp, width, height, tr_hor, tr_ver,
                                       set_idx, lfnst_idx)
        golden = TV_DIR / f"{stem}_golden.hex"
        golden.write_text("\n".join(to_hex10(v) for v in flatten_raster(output)) + "\n",
                          encoding="utf-8", newline="\n")
    print(f"Regenerated {len(stems)} named LFNST goldens from ref_model")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
