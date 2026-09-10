"""
VVC Inverse Transform Module (ITS) - Python Reference Model
Refactored V1: Matrices loaded from attachment_matrices.json (competition spec).
trType mapping follows attachment: 0=DCT2, 1=DST7, 2=DCT8.
"""
import json
import json
import os
import sys
from typing import List, Tuple

# ============================================================
# Attachment matrix loading
# ============================================================

_canonical_matrices = None

def _load_canonical_matrices():
    global _canonical_matrices
    if _canonical_matrices is not None:
        return _canonical_matrices
    script_dir = os.path.dirname(os.path.abspath(__file__))
    json_path = os.path.join(script_dir, '..', 'output', 'canonical_matrices.json')
    with open(json_path, 'r', encoding='utf-8') as f:
        _canonical_matrices = json.load(f)
    return _canonical_matrices

def get_canonical_transform_matrix(tr_type: int, N: int) -> List[List[int]]:
    """Get canonical transform matrix.
    trType: 0=DCT2, 1=DST7, 2=DCT8.
    Sources: Huawei attachment + VTM RomTr.cpp (see canonical_matrices.json metadata).
    """
    data = _load_canonical_matrices()
    return data["transforms"][str(tr_type)]["inverse_operator"][str(N)]

def get_canonical_lfnst_matrix(ntrs: int, set_idx: int, lfnst_idx: int) -> List[List[int]]:
    """Get canonical LFNST matrix."""
    data = _load_canonical_matrices()
    return data["lfnst"][str(ntrs)][str(set_idx)][str(lfnst_idx)]

# Backward-compatible aliases
get_attachment_transform_matrix = get_canonical_transform_matrix
get_attachment_lfnst_matrix = get_canonical_lfnst_matrix

def get_attachment_lfnst_matrix(ntrs: int, set_idx: int, lfnst_idx: int) -> List[List[int]]:
    """Get LFNST matrix from competition attachment."""
    data = _load_attachment_matrices()
    return data["lfnst"][str(ntrs)][str(set_idx)][str(lfnst_idx)]

# ============================================================
# LFNST scan orders - per competition attachment diagrams
# ============================================================

# Input: diagonal scan (attachment Fig: LFNST 4x4 block → 16-element vector)
#   Attachment numbering of 4x4:
#     0  2  5  9
#     1  4  8 12
#     3  7 11 14
#     6 10 13 15
#   Vector order: (0,0),(1,0),(0,1),(2,0),(1,1),(0,2),(3,0),(2,1),
#                 (1,2),(0,3),(3,1),(2,2),(1,3),(3,2),(2,3),(3,3)

LFNST_INPUT_SCAN_4x4: List[Tuple[int, int]] = [
    (0, 0), (1, 0), (0, 1), (2, 0),
    (1, 1), (0, 2), (3, 0), (2, 1),
    (1, 2), (0, 3), (3, 1), (2, 2),
    (1, 3), (3, 2), (2, 3), (3, 3),
]

# Output nTrs=16: row-major within top-left 4x4 (attachment Fig)
#     0  1  2  3
#     4  5  6  7
#     8  9 10 11
#    12 13 14 15

LFNST_OUTPUT_SCAN_16: List[Tuple[int, int]] = [
    (0, 0), (0, 1), (0, 2), (0, 3),
    (1, 0), (1, 1), (1, 2), (1, 3),
    (2, 0), (2, 1), (2, 2), (2, 3),
    (3, 0), (3, 1), (3, 2), (3, 3),
]

# Output nTrs=48: top 4x8 row-major (indices 0-31), then bottom-left 4x4 row-major (32-47)
# (attachment Fig)

LFNST_OUTPUT_SCAN_48: List[Tuple[int, int]] = [
    # Top 4 rows × 8 cols (row-major, indices 0..31)
    (0, 0), (0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (0, 6), (0, 7),
    (1, 0), (1, 1), (1, 2), (1, 3), (1, 4), (1, 5), (1, 6), (1, 7),
    (2, 0), (2, 1), (2, 2), (2, 3), (2, 4), (2, 5), (2, 6), (2, 7),
    (3, 0), (3, 1), (3, 2), (3, 3), (3, 4), (3, 5), (3, 6), (3, 7),
    # Bottom-left 4 rows × 4 cols (row-major, indices 32..47)
    (4, 0), (4, 1), (4, 2), (4, 3),
    (5, 0), (5, 1), (5, 2), (5, 3),
    (6, 0), (6, 1), (6, 2), (6, 3),
    (7, 0), (7, 1), (7, 2), (7, 3),
]

# ============================================================
# Utility
# ============================================================

def clip3(low: int, high: int, val: int) -> int:
    return max(low, min(high, val))

def mat_vec_mul(mat: List[List[int]], vec: List[int]) -> List[int]:
    """Matrix-vector multiply: result = mat * vec"""
    rows = len(mat)
    cols = len(mat[0])
    result = []
    for i in range(rows):
        s = 0
        for j in range(cols):
            s += mat[i][j] * vec[j]
        result.append(s)
    return result

def mat_transpose(mat: List[List[int]]) -> List[List[int]]:
    rows = len(mat)
    cols = len(mat[0])
    return [[mat[j][i] for j in range(rows)] for i in range(cols)]


# ============================================================
# 1D inverse transform
# y = T * x, then >> 6 with rounding
# ============================================================

def inverse_transform_1d(input_vec: List[int], tr_type: int, N: int) -> List[int]:
    """1D inverse transform: y = T * x >> 6.
    Matrix T from canonical_matrices.json.
    trType: 0=DCT2, 1=DST7, 2=DCT8.
    """
    T = get_canonical_transform_matrix(tr_type, N)
    result = mat_vec_mul(T, input_vec)
    return [(r + 32) >> 6 for r in result]


# ============================================================
# LFNST inverse transform
# y[i] = clip3(-32768, 32767, (sum_j(T[i][j]*x[j]) + 64) >> 7)
# Matrix T loaded from attachment.
# ============================================================

def get_lfnst_nonzero_size(tu_width: int, tu_height: int) -> int:
    """Number of LFNST input coefficients used by the Huawei specification."""
    return 8 if ((tu_width == 4 and tu_height == 4) or
                 (tu_width == 8 and tu_height == 8)) else 16


def lfnst_inverse(input_vec: List[int], ntrs: int,
                  set_idx: int, lfnst_idx: int,
                  nonzero_size: int) -> List[int]:
    if lfnst_idx == 0:
        return input_vec

    if nonzero_size not in (8, 16):
        raise ValueError(f"invalid LFNST nonzero_size={nonzero_size}")
    if len(input_vec) < nonzero_size:
        raise ValueError(
            f"LFNST input has {len(input_vec)} values, requires {nonzero_size}")

    T = get_canonical_lfnst_matrix(ntrs, set_idx, lfnst_idx)
    # Do not use a generic 16-column mat_vec_mul here: 4x4 and 8x8
    # explicitly ignore input coefficients 8..15.
    result = [sum(T[i][j] * input_vec[j] for j in range(nonzero_size))
              for i in range(len(T))]
    return [clip3(-32768, 32767, (r + 64) >> 7) for r in result]


# ============================================================
# 2D inverse transform (separable: vertical then horizontal)
# ============================================================

def inverse_transform_2d(coeff: List[List[int]], tr_type_hor: int,
                         tr_type_ver: int, width: int, height: int) -> List[List[int]]:
    # Vertical transform first: process each column with tr_type_ver, size=height
    col_result = [[0]*height for _ in range(width)]
    for j in range(width):
        col = [coeff[i][j] for i in range(height)]
        col_out = inverse_transform_1d(col, tr_type_ver, height)
        for i in range(height):
            col_result[j][i] = col_out[i]

    # Horizontal transform second: process each row with tr_type_hor, size=width
    result = [[0]*width for _ in range(height)]
    for i in range(height):
        row = [col_result[j][i] for j in range(width)]
        row_out = inverse_transform_1d(row, tr_type_hor, width)
        result[i] = row_out

    return result


# ============================================================
# Full ITS pipeline
# ============================================================

def its_inverse_transform(
    input_data: List[List[int]],
    tu_width: int,
    tu_height: int,
    tr_type_hor: int,
    tr_type_ver: int,
    lfnst_tr_set_idx: int,
    lfnst_idx: int
) -> List[List[int]]:
    """Full ITS inverse transform pipeline.
    trType follows attachment: 0=DCT2, 1=DST7, 2=DCT8.
    """
    coeff = [row[:] for row in input_data]  # deep copy

    # Step 1: LFNST (if needed)
    if lfnst_idx != 0:
        ntrs = 48 if (tu_width >= 8 and tu_height >= 8) else 16

        # Input: read top-left 4x4 block in diagonal scan order (attachment spec)
        input_vec = [coeff[r][c] for (r, c) in LFNST_INPUT_SCAN_4x4
                     if r < tu_height and c < tu_width]

        # Apply LFNST
        nonzero_size = get_lfnst_nonzero_size(tu_width, tu_height)
        transformed = lfnst_inverse(input_vec, ntrs, lfnst_tr_set_idx,
                                    lfnst_idx, nonzero_size)

        # Write back: OUTPUT uses row-major for nTrs=16, 4x8+4x4 for nTrs=48
        # (attachment Fig - different from input scan)
        if ntrs == 16:
            for k, (r, c) in enumerate(LFNST_OUTPUT_SCAN_16):
                coeff[r][c] = transformed[k]
        else:  # ntrs == 48
            for k, (r, c) in enumerate(LFNST_OUTPUT_SCAN_48):
                if r < tu_height and c < tu_width:
                    coeff[r][c] = transformed[k]

    # Step 2: 2D inverse transform
    # When LFNST is active, main transform must be DCT2 per VVC spec
    actual_tr_hor = 0 if lfnst_idx != 0 else tr_type_hor
    actual_tr_ver = 0 if lfnst_idx != 0 else tr_type_ver
    result = inverse_transform_2d(coeff, actual_tr_hor, actual_tr_ver, tu_width, tu_height)
    return result


# ============================================================
# Format conversion helpers
# ============================================================

def flatten_raster(matrix: List[List[int]]) -> List[int]:
    result = []
    for row in matrix:
        result.extend(row)
    return result


# ============================================================
# Test vector generation for RTL verification
# ============================================================

def generate_test_vector_file(filename: str, width: int, height: int,
                              tr_hor: int, tr_ver: int, set_idx: int, lfnst: int,
                              input_data: List[List[int]]):
    """Generate test vector file for ModelSim."""
    output = its_inverse_transform(input_data, width, height, tr_hor, tr_ver, set_idx, lfnst)

    with open(filename, 'w') as f:
        f.write(f"# width={width} height={height} tr_hor={tr_hor} tr_ver={tr_ver} "
                f"set_idx={set_idx} lfnst={lfnst}\n")

        # Input (raster scan, non-zero only)
        flat_in = flatten_raster(input_data)
        for idx, val in enumerate(flat_in):
            if val != 0:
                f.write(f"IN {idx} {val}\n")

        # Expected output (4 values per line)
        flat_out = flatten_raster(output)
        for i in range(0, len(flat_out), 4):
            vals = flat_out[i:i+4]
            while len(vals) < 4:
                vals.append(0)
            f.write(f"OUT {vals[0]} {vals[1]} {vals[2]} {vals[3]}\n")

    return output


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":
    print("VVC ITS Reference Model (V1 - canonical matrices)")
    print("=" * 60)

    # Print matrix sources
    print()
    print("Matrix sources (29 total):")
    print("  DCT2  4/8/16/32 - VTM RomTr.cpp")
    print("  DCT2 64        - Huawei attachment + VTM (verified identical)")
    print("  DST7 4/8/16/32 - Huawei attachment")
    print("  DCT8 4/8/16/32 - Huawei attachment")
    print("  LFNST 16 scen. - Huawei attachment")
    print("VTM: commit 69f5112bae8c0f91f3cbc5ba0f44b58986080f16")

    # Print sample matrices
    print("\n--- DCT2 4x4 (VTM) ---")
    T = get_canonical_transform_matrix(0, 4)
    for row in T: print(f"  {row}")

    print("\n--- DST7 4x4 (Attachment) ---")
    T = get_canonical_transform_matrix(1, 4)
    for row in T: print(f"  {row}")

    print("\n--- DCT8 4x4 (Attachment) ---")
    T = get_canonical_transform_matrix(2, 4)
    for row in T: print(f"  {row}")

    # Test one-hot
    print("\n--- One-hot verification ---")
    for tr, name in [(0,"DCT2"),(1,"DST7"),(2,"DCT8")]:
        N = 4 if tr == 0 else 4
        x = [1] + [0]*(N-1)
        out = inverse_transform_1d(x, tr, N)
        print(f"  {name} N={N} onehot[0]: {out[:4]}")

    print("\nDone.")
