"""Independent V3.4 RTL bit-exact oracle.

This file intentionally does not import ref_model.py or any existing golden.
It consumes only canonical_matrices.json and independently models the RTL
address/datatypes/post-processing contract.
"""

from __future__ import annotations

from typing import Any, Dict, List

from oracle_common import clip3, load_canonical, lfnst_matrix, transform_matrix


ROM_BASE = {
    (0, 4): 0, (0, 8): 16, (0, 16): 80, (0, 32): 336, (0, 64): 1360,
    (1, 4): 5456, (1, 8): 5472, (1, 16): 5536, (1, 32): 5792,
    (2, 4): 6816, (2, 8): 6832, (2, 16): 6896, (2, 32): 7152,
}


def wrap_signed_16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def low10(value: int) -> int:
    return value & 0x3FF


def rom_address(tr_type: int, n: int, output_row: int, input_col: int) -> int:
    """Independent row-major address calculation used by the V3.4 engine."""
    if (tr_type, n) not in ROM_BASE:
        raise ValueError(f"unsupported ROM block tr_type={tr_type}, N={n}")
    if not (0 <= output_row < n and 0 <= input_col < n):
        raise ValueError("ROM row/column out of range")
    return ROM_BASE[(tr_type, n)] + output_row * n + input_col


def canonical_rom_coeff(tr_type: int, n: int, output_row: int, input_col: int) -> int:
    """Return the coefficient at the independently calculated ROM address."""
    data = load_canonical()
    addr = rom_address(tr_type, n, output_row, input_col)
    local = addr - ROM_BASE[(tr_type, n)]
    return transform_matrix(data, tr_type, n)[local // n][local % n]


def _check_vec(input_vec: List[int], n: int) -> None:
    if len(input_vec) != n:
        raise ValueError(f"input length {len(input_vec)} != N={n}")


def main_1d_details(input_vec: List[int], tr_type: int, n: int) -> Dict[str, List[int]]:
    _check_vec(input_vec, n)
    # Consume coefficients through the independently modeled row-major ROM
    # address, rather than calling legacy ref_model or reading an existing ROM.
    raw = [sum(canonical_rom_coeff(tr_type, n, i, j) * input_vec[j]
               for j in range(n))
           for i in range(n)]
    biased = [v + 32 for v in raw]
    shifted = [v >> 6 for v in biased]
    stage16 = [wrap_signed_16(v) for v in shifted]
    return {"raw_dot": raw, "biased": biased, "shifted": shifted,
            "stage16": stage16}


def main_1d(input_vec: List[int], tr_type: int, n: int) -> List[int]:
    return main_1d_details(input_vec, tr_type, n)["stage16"]


def main_2d_details(coeff: List[List[int]], tr_type_hor: int,
                    tr_type_ver: int, width: int, height: int) -> Dict[str, Any]:
    if len(coeff) != height or any(len(row) != width for row in coeff):
        raise ValueError("coefficient matrix shape does not match width/height")

    # Stage 1 is vertical: each input column has length height.
    v_details = [main_1d_details([coeff[r][c] for r in range(height)],
                                 tr_type_ver, height)
                 for c in range(width)]
    stage1 = [[v_details[c]["stage16"][r] for c in range(width)]
              for r in range(height)]
    stage1_raw = [[v_details[c]["raw_dot"][r] for c in range(width)]
                  for r in range(height)]
    stage1_biased = [[v_details[c]["biased"][r] for c in range(width)]
                     for r in range(height)]
    stage1_shifted = [[v_details[c]["shifted"][r] for c in range(width)]
                      for r in range(height)]

    # Stage 2 is horizontal: each row has length width.
    h_details = [main_1d_details(stage1[r], tr_type_hor, width)
                 for r in range(height)]
    stage2 = [d["stage16"] for d in h_details]
    stage2_raw = [d["raw_dot"] for d in h_details]
    stage2_biased = [d["biased"] for d in h_details]
    stage2_shifted = [d["shifted"] for d in h_details]
    final10 = [[low10(v) for v in row] for row in stage2]

    return {
        "stage1_raw_dot": stage1_raw,
        "stage1_biased": stage1_biased,
        "stage1_shifted": stage1_shifted,
        "stage1_stage16": stage1,
        "stage2_raw_dot": stage2_raw,
        "stage2_biased": stage2_biased,
        "stage2_shifted": stage2_shifted,
        "stage2_stage16": stage2,
        "final10": final10,
    }


def main_2d(coeff: List[List[int]], tr_type_hor: int,
            tr_type_ver: int, width: int, height: int) -> List[List[int]]:
    return main_2d_details(coeff, tr_type_hor, tr_type_ver, width, height)["final10"]


def lfnst_details(input_vec: List[int], ntrs: int, set_idx: int,
                  lfnst_idx: int, nonzero_size: int) -> Dict[str, List[int]]:
    data = load_canonical()
    if nonzero_size not in (8, 16):
        raise ValueError(f"invalid nonzero_size={nonzero_size}")
    matrix = lfnst_matrix(data, ntrs, set_idx, lfnst_idx)
    if len(input_vec) < nonzero_size:
        raise ValueError("LFNST input shorter than nonzero_size")
    raw = [sum(matrix[i][j] * input_vec[j] for j in range(nonzero_size))
           for i in range(len(matrix))]
    biased = [v + 64 for v in raw]
    shifted = [v >> 7 for v in biased]
    clipped = [clip3(v, -32768, 32767) for v in shifted]
    return {"raw_dot": raw, "biased": biased, "shifted": shifted,
            "stage16_clip": clipped}


def lfnst_nonzero_size(tu_width: int, tu_height: int) -> int:
    """Huawei TU-aware LFNST input rule.

    Only the exact 4x4 and 8x8 TUs use the first eight scanned inputs;
    every other supported LFNST TU uses all sixteen inputs.
    """
    return 8 if ((tu_width == 4 and tu_height == 4) or
                 (tu_width == 8 and tu_height == 8)) else 16


def lfnst_ntrs(tu_width: int, tu_height: int) -> int:
    """Huawei TU-aware LFNST output transform size."""
    return 48 if (tu_width >= 8 and tu_height >= 8) else 16


def lfnst_tu_details(input_vec: List[int], tu_width: int, tu_height: int,
                     set_idx: int, lfnst_idx: int) -> Dict[str, Any]:
    """TU-level LFNST wrapper deriving nTrs/nonZeroSize from dimensions.

    The caller cannot accidentally select the wrong 8/16-input contract.
    The input is the sixteen-element diagonal-scanned top-left block; the
    low-level primitive performs the matrix multiply and fixed-point
    post-processing.
    """
    if tu_width < 4 or tu_height < 4:
        raise ValueError("LFNST TU dimensions must be at least 4x4")
    if len(input_vec) < 16:
        raise ValueError("TU-level LFNST requires 16 scanned input values")
    ntrs = lfnst_ntrs(tu_width, tu_height)
    nonzero_size = lfnst_nonzero_size(tu_width, tu_height)
    details = lfnst_details(input_vec[:16], ntrs, set_idx, lfnst_idx,
                            nonzero_size)
    return {
        "tu_width": tu_width,
        "tu_height": tu_height,
        "ntrs": ntrs,
        "nonzero_size": nonzero_size,
        **details,
    }


def lfnst(input_vec: List[int], ntrs: int, set_idx: int,
          lfnst_idx: int, nonzero_size: int) -> List[int]:
    return lfnst_details(input_vec, ntrs, set_idx, lfnst_idx, nonzero_size)["stage16_clip"]
