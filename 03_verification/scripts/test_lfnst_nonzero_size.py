"""Independent audit of the Huawei LFNST nonZeroSize rule.

This test intentionally does not import ref_model.py.  It reads the canonical
LFNST matrices and computes the specified matrix-vector product directly.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[2]
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"
sys.path.insert(0, str(ROOT / "03_verification" / "scripts"))
import ref_model  # noqa: E402


def nonzero_size(width: int, height: int) -> int:
    return 8 if ((width, height) in ((4, 4), (8, 8))) else 16


def ntrs(width: int, height: int) -> int:
    return 48 if width >= 8 and height >= 8 else 16


def lfnst_oracle(matrix, vector, nz):
    if len(vector) != 16:
        raise AssertionError("LFNST oracle expects exactly 16 input values")
    return [max(-32768, min(32767,
                            (sum(matrix[i][j] * vector[j]
                                 for j in range(nz)) + 64) >> 7))
            for i in range(len(matrix))]


def main() -> int:
    data = json.loads(CANONICAL.read_text(encoding="utf-8"))
    total = 0

    # One-hot x[k]=128: a participating column is visible after >>7.
    for width, height in ((4, 4), (8, 8), (4, 8), (8, 4), (8, 16)):
        trs = ntrs(width, height)
        nz = nonzero_size(width, height)
        for set_idx in range(4):
            for lfnst_idx in (1, 2):
                matrix = data["lfnst"][str(trs)][str(set_idx)][str(lfnst_idx)]
                for k in range(16):
                    vector = [0] * 16
                    vector[k] = 128
                    got = ref_model.lfnst_inverse(
                        vector, trs, set_idx, lfnst_idx, nz)
                    expected = lfnst_oracle(matrix, vector, nz)
                    # For exact 4x4/8x8, columns 8..15 must be ignored.
                    if nz == 8 and k >= 8:
                        expected = [0] * len(matrix)
                    if got != expected:
                        raise AssertionError(
                            f"one-hot mismatch {width}x{height} "
                            f"set={set_idx} idx={lfnst_idx} k={k}")
                    total += 1

    # Tail poison: changing only x[8:16] must not affect exact 4x4/8x8.
    for width, height in ((4, 4), (8, 8)):
        trs = ntrs(width, height)
        for set_idx in range(4):
            for lfnst_idx in (1, 2):
                matrix = data["lfnst"][str(trs)][str(set_idx)][str(lfnst_idx)]
                vector = [0] * 16
                vector[8:] = [128] * 8
                got = ref_model.lfnst_inverse(
                    vector, trs, set_idx, lfnst_idx, nonzero_size(width, height))
                expected = lfnst_oracle(matrix, vector, nonzero_size(width, height))
                if got != expected:
                    raise AssertionError(
                        f"model/oracle mismatch {width}x{height} "
                        f"set={set_idx} idx={lfnst_idx}")
                if any(got):
                    raise AssertionError(
                        f"tail poison affected {width}x{height} "
                        f"set={set_idx} idx={lfnst_idx}: {got}")
                total += 1

    # Control sizes must retain all 16 terms; tail-only input must be visible
    # for at least one output in every matrix.
    for width, height in ((4, 8), (8, 4), (8, 16)):
        trs = ntrs(width, height)
        for set_idx in range(4):
            for lfnst_idx in (1, 2):
                matrix = data["lfnst"][str(trs)][str(set_idx)][str(lfnst_idx)]
                vector = [0] * 16
                vector[8:] = [128] * 8
                got = ref_model.lfnst_inverse(
                    vector, trs, set_idx, lfnst_idx, 16)
                expected = lfnst_oracle(matrix, vector, 16)
                if got != expected:
                    raise AssertionError(
                        f"model/oracle mismatch {width}x{height} "
                        f"set={set_idx} idx={lfnst_idx}")
                if not any(got):
                    raise AssertionError(
                        f"tail was ignored for control size {width}x{height} "
                        f"set={set_idx} idx={lfnst_idx}")
                total += 1

    print(f"LFNST nonZeroSize independent audit: {total} checks PASS")
    print("  exact 4x4/8x8: columns 8..15 ignored")
    print("  control sizes: all 16 columns retained")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
