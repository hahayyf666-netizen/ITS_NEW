"""Generate the P2A DCT2-64 coefficient artifact from frozen canonical data."""

from __future__ import annotations

import json
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ORACLE = Path(r"D:\Workspace\ITS_STUDY_V35_ORACLE")
sys.path.insert(0, str(ORACLE))
from oracle_common import load_canonical, transform_matrix  # noqa: E402


def main() -> int:
    data = load_canonical()
    matrix = transform_matrix(data, 0, 64)
    if len(matrix) != 64 or any(len(row) != 64 for row in matrix):
        raise SystemExit("canonical DCT2-64 inverse_operator is not 64x64")
    values = [int(v) for row in matrix for v in row]
    if any(v < -32768 or v > 32767 for v in values):
        raise SystemExit("coefficient outside signed16")
    hex_path = ROOT / "rtl" / "dct2_64_coeff.hex"
    hex_path.write_text("\n".join(f"{v & 0xffff:04x}" for v in values) + "\n", encoding="ascii")
    # Lane-partitioned copies keep the output-lane dimension static during
    # synthesis.  Each lane still selects all 16 out_group rows dynamically;
    # no coefficient group is hard-wired or omitted.
    for lane in range(4):
        lane_values = []
        for group in range(16):
            row = group * 4 + lane
            lane_values.extend(matrix[row])
        (ROOT / "rtl" / f"dct2_64_coeff_l{lane}.hex").write_text(
            "\n".join(f"{int(v) & 0xffff:04x}" for v in lane_values) + "\n",
            encoding="ascii")
    meta = {
        "transform": "DCT2-64",
        "operator": "inverse_operator = C^T",
        "layout": "row-major A[output_row][input_col]",
        "entries": len(values),
        "min": min(values),
        "max": max(values),
        "sha256": hashlib.sha256(hex_path.read_bytes()).hexdigest(),
        "canonical_path": r"D:\Workspace\ITS_STUDY_V34_LFNST_FIX\03_verification\output\canonical_matrices.json",
    }
    (ROOT / "rtl" / "dct2_64_coeff_metadata.json").write_text(
        json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(meta, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
