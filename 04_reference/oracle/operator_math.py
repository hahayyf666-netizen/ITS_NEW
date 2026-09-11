"""P1-A operator_math oracle.

Only the mathematical operators are implemented here:
  main:  raw[i] = sum_j A[i][j] * x[j], A = canonical inverse_operator
  LFNST: raw[i] = sum_j M[i][j] * x[j]

No rounding, shift, wrapping, clipping, or RTL/golden dependency is used.
"""

from __future__ import annotations

from typing import List

from oracle_common import load_canonical, transform_matrix, lfnst_matrix


def raw_main(input_vec: List[int], tr_type: int, n: int) -> List[int]:
    data = load_canonical()
    matrix = transform_matrix(data, tr_type, n)  # already A = C^T
    if len(input_vec) != n:
        raise ValueError(f"main input length {len(input_vec)} != N={n}")
    return [sum(matrix[i][j] * input_vec[j] for j in range(n))
            for i in range(n)]


def raw_lfnst(input_vec: List[int], ntrs: int, set_idx: int,
              lfnst_idx: int, nonzero_size: int) -> List[int]:
    data = load_canonical()
    if nonzero_size not in (8, 16):
        raise ValueError(f"invalid nonzero_size={nonzero_size}")
    matrix = lfnst_matrix(data, ntrs, set_idx, lfnst_idx)
    if len(input_vec) < nonzero_size:
        raise ValueError("LFNST input shorter than nonzero_size")
    return [sum(matrix[i][j] * input_vec[j] for j in range(nonzero_size))
            for i in range(len(matrix))]


def main_one_hot_examples() -> dict[str, List[int]]:
    return {
        "DCT2-4-e0": raw_main([1, 0, 0, 0], 0, 4),
        "DST7-4-e0": raw_main([1, 0, 0, 0], 1, 4),
    }
