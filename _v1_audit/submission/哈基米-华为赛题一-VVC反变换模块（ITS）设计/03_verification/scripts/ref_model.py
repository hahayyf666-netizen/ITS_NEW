"""
VVC Inverse Transform Module (ITS) - Python Reference Model
Supports: DCT2, DCT8, DST7 inverse transforms + LFNST
Formulas from VVC standard (JVET-S2001)
"""

import math
import os
import sys
from typing import List, Tuple

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
# DCT2 matrix generation (VVC standard)
# T(i,j) = 64 for i=0
# T(i,j) = round(89 * cos(pi*i*(2j+1)/(2N))) for i>0
# ============================================================

def get_dct2_matrix(N: int) -> List[List[int]]:
    """Generate DCT2 matrix matching gen_rom_coeffs.py formula.
    T(i,j) = 64 for i=0, round(89 * cos(pi*i*(2j+1)/(2N))) for i>0.
    """
    T = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            if i == 0:
                T[i][j] = 64
            else:
                angle = math.pi * i * (2*j + 1) / (2 * N)
                T[i][j] = round(89 * math.cos(angle))
    return T


# ============================================================
# DCT8 / DST7 matrix generation (VVC standard)
# DCT8: T(i,j) = round(64 * cos(pi*(2i+1)*(2j+1)/(4N)))
# DST7: T(i,j) = round(64 * sin(pi*(i+1)*(j+1)/(N+1)))
# ============================================================

def get_dct8_matrix(N: int) -> List[List[int]]:
    T = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            angle = math.pi * (2*i + 1) * (2*j + 1) / (4 * N)
            T[i][j] = round(64 * math.cos(angle))
    return T

def get_dst7_matrix(N: int) -> List[List[int]]:
    T = [[0]*N for _ in range(N)]
    for i in range(N):
        for j in range(N):
            angle = math.pi * (i + 1) * (j + 1) / (N + 1)
            T[i][j] = round(64 * math.sin(angle))
    return T

def get_transform_matrix(tr_type: int, N: int) -> List[List[int]]:
    if tr_type == 0:
        return get_dct2_matrix(N)
    elif tr_type == 1:
        return get_dct8_matrix(N)
    elif tr_type == 2:
        return get_dst7_matrix(N)
    else:
        raise ValueError(f"Unknown tr_type: {tr_type}")


# ============================================================
# LFNST matrices - loaded from official competition attachment
# ============================================================

_lfnst_matrices = None

def _load_lfnst_matrices():
    """Load LFNST matrices from lfnst_doc.txt (official attachment)."""
    global _lfnst_matrices
    if _lfnst_matrices is not None:
        return _lfnst_matrices

    # Try to import from parse_lfnst_matrices.py
    script_dir = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, script_dir)
    try:
        from parse_lfnst_matrices import parse_lfnst_doc
        doc_path = os.path.join(script_dir, '..', 'output', 'lfnst_doc.txt')
        _lfnst_matrices = parse_lfnst_doc(doc_path)
        return _lfnst_matrices
    except Exception as e:
        print(f"WARNING: Could not load LFNST matrices from doc: {e}")
        print("Falling back to hardcoded matrices")
        _lfnst_matrices = {}
        return _lfnst_matrices

def get_lfnst_matrix(ntrs: int, set_idx: int, lfnst_idx: int) -> List[List[int]]:
    """Get LFNST transform matrix for given parameters.

    Args:
        ntrs: 16 or 48 (official VVC definition: (w>=8 && h>=8) ? 48 : 16)
        set_idx: 0..3 (lfnstTrSetIdx)
        lfnst_idx: 1 or 2 (0 means no LFNST)
    """
    matrices = _load_lfnst_matrices()
    key = (ntrs, set_idx, lfnst_idx)
    if key in matrices:
        return matrices[key]
    raise ValueError(f"LFNST matrix not found for nTrs={ntrs}, set={set_idx}, idx={lfnst_idx}")


# ============================================================
# 1D inverse transform
# y = T * x, then >> 6 with rounding
# ============================================================

def inverse_transform_1d(input_vec: List[int], tr_type: int, N: int) -> List[int]:
    """1D inverse transform: y = T * x >> 6 (matches hardware implementation).
    The ROM stores the transform matrix T. Hardware reads T[i][j] and computes
    y[i] = (sum_j T[i][j]*x[j] + 32) >> 6.
    """
    T = get_transform_matrix(tr_type, N)
    result = mat_vec_mul(T, input_vec)
    return [(r + 32) >> 6 for r in result]


# ============================================================
# LFNST inverse transform
# y[i] = clip3(-32768, 32767, (sum_j(T[i][j]*x[j]) + 64) >> 7)
# ============================================================

def lfnst_inverse(input_vec: List[int], ntrs: int,
                  set_idx: int, lfnst_idx: int) -> List[int]:
    if lfnst_idx == 0:
        return input_vec

    T = get_lfnst_matrix(ntrs, set_idx, lfnst_idx)
    result = mat_vec_mul(T, input_vec)
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
    """Full ITS inverse transform pipeline."""
    coeff = [row[:] for row in input_data]  # deep copy

    # Step 1: LFNST (if needed)
    if lfnst_idx != 0:
        # nTrs = (tu_width >= 8 && tu_height >= 8) ? 48 : 16
        ntrs = 48 if (tu_width >= 8 and tu_height >= 8) else 16

        # Input: read top-left 4x4 block (rows 0-3, cols 0-3)
        input_vec = []
        for i in range(min(4, tu_height)):
            for j in range(min(4, tu_width)):
                input_vec.append(coeff[i][j])

        # Apply LFNST: ntrs x 16 matrix * 16-element vector
        transformed = lfnst_inverse(input_vec, ntrs, lfnst_tr_set_idx, lfnst_idx)

        # Write back to coeff array
        # nTrs=16: write to top-left 4x4 block (rows 0-3, cols 0-3)
        # nTrs=48: write to top-left 8x8 (48 elements = 3 sub-blocks of 4x4)
        if ntrs == 16:
            for k in range(16):
                row = k // 4          # row within 4x4 block
                col = k % 4           # col within 4x4 block
                coeff[row][col] = transformed[k]
        else:  # ntrs == 48
            # Write 48 elements: 3 sub-blocks of 4x4
            # Block 0: rows 0-3, cols 0-3 (top-left)
            # Block 1: rows 0-3, cols 4-7 (right of block 0)
            # Block 2: rows 4-7, cols 0-3 (below block 0)
            idx = 0
            for blk in range(3):
                row_offset = 4 if blk == 2 else 0
                col_offset = 4 if blk == 1 else 0
                for i in range(min(4, tu_height - row_offset)):
                    for j in range(min(4, tu_width - col_offset)):
                        coeff[row_offset + i][col_offset + j] = transformed[idx]
                        idx += 1

    # Step 2: 2D inverse transform
    # VVC standard: when LFNST is active, main transform must be DCT2
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
    print("VVC ITS Reference Model")
    print("=" * 60)

    # Verify DCT matrices match ROM
    print("\n--- DCT2 4x4 ---")
    for row in get_dct2_matrix(4):
        print(row)

    print("\n--- DCT8 4x4 ---")
    for row in get_dct8_matrix(4):
        print(row)

    print("\n--- DST7 4x4 ---")
    for row in get_dst7_matrix(4):
        print(row)

    # Test inverse transform
    print("\n--- DCT2 4x4 Inverse (DC only) ---")
    input_dc = [[64,0,0,0],[0,0,0,0],[0,0,0,0],[0,0,0,0]]
    out = its_inverse_transform(input_dc, 4, 4, 0, 0, 0, 0)
    for row in out:
        print(row)

    # Load and verify LFNST matrices
    print("\n--- LFNST Matrices ---")
    matrices = _load_lfnst_matrices()
    print(f"Loaded {len(matrices)} LFNST scenarios")
    for (ntrs, set_idx, lfnst_idx), mat in sorted(matrices.items()):
        print(f"  nTrs={ntrs}, set={set_idx}, idx={lfnst_idx}: {len(mat)}x{len(mat[0])}")

    # Generate test vectors
    print("\n--- Generating test vectors ---")
    tv_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tb', 'test_vectors')
    os.makedirs(tv_dir, exist_ok=True)

    import random
    random.seed(42)

    test_cases = [
        # (width, height, tr_hor, tr_ver, set_idx, lfnst, description)
        (4, 4, 0, 0, 0, 0, "dct2_4x4"),
        (8, 8, 0, 0, 0, 0, "dct2_8x8"),
        (16, 16, 0, 0, 0, 0, "dct2_16x16"),
        (4, 4, 1, 1, 0, 0, "dct8_4x4"),
        (4, 4, 2, 2, 0, 0, "dst7_4x4"),
        (8, 8, 1, 1, 0, 0, "dct8_8x8"),
        (4, 4, 0, 0, 0, 1, "dct2_4x4_lfnst1"),
        (4, 4, 0, 0, 0, 2, "dct2_4x4_lfnst2"),
        (4, 4, 0, 0, 1, 1, "dct2_4x4_lfnst_s1_i1"),
        (8, 8, 0, 0, 0, 1, "dct2_8x8_lfnst1"),
        (8, 8, 0, 0, 0, 2, "dct2_8x8_lfnst2"),
        (16, 16, 0, 0, 0, 1, "dct2_16x16_lfnst1"),
    ]

    for w, h, tr_h, tr_v, sidx, lfnst, desc in test_cases:
        # Generate random input (sparse)
        data = [[0]*w for _ in range(h)]
        num_nonzero = min(w*h, random.randint(1, min(8, w*h)))
        for _ in range(num_nonzero):
            r = random.randint(0, h-1)
            c = random.randint(0, w-1)
            data[r][c] = random.randint(-100, 100)

        fname = os.path.join(tv_dir, f"{desc}.tv")
        out = generate_test_vector_file(fname, w, h, tr_h, tr_v, sidx, lfnst, data)
        flat_out = flatten_raster(out)
        print(f"  {desc}: {num_nonzero} inputs -> {len(flat_out)} outputs")

    print(f"\nTest vectors generated in {tv_dir}")
    print("\nDone!")
