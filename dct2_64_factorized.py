"""Exact integer factorization study for the canonical DCT2-64 inverse.

This is a software-only P2F-Pre artifact.  It deliberately does not modify
the V3.4 RTL or its golden vectors.  The source matrix C and the frozen
inverse operator A=C^T are read from the copied, read-only V3.4 baseline.

The factorization is the exact even/odd frequency decimation identity:

    E[p] = sum_m C_N[2m][p] x[2m]
    O[p] = sum_m C_N[2m+1][p] x[2m+1]
    y[p]       = E[p] + O[p]
    y[N-1-p]   = E[p] - O[p]

For N>4, E is recursively evaluated as the canonical DCT2-(N/2) matrix;
the odd branch remains a dense, exact odd-frequency submatrix.  No rounding,
shift, clipping, or narrowing is performed in the raw factorized path.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Sequence

N = 64
WIDTH = 16


def _find_canonical() -> Path:
    candidates = [
        Path(__file__).resolve().parent / "03_verification" / "output" / "canonical_matrices.json",
        Path(__file__).resolve().parent.parent / "ITS_STUDY_V34_LFNST_FIX" / "03_verification" / "output" / "canonical_matrices.json",
    ]
    for path in candidates:
        if path.exists():
            return path
    raise FileNotFoundError("canonical_matrices.json not found in the copied V3.4 tree")


def load_canonical(path: Path | None = None) -> dict[str, Any]:
    with (path or _find_canonical()).open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _matrices(data: dict[str, Any], n: int) -> tuple[list[list[int]], list[list[int]]]:
    t = data["transforms"]["0"]
    source = [[int(v) for v in row] for row in t["source_kernel"][str(n)]]
    inverse = [[int(v) for v in row] for row in t["inverse_operator"][str(n)]]
    return source, inverse


def wrap_signed_16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


@dataclass
class FactorizedDetails:
    even: list[int]
    odd: list[int]
    raw: list[int]
    biased: list[int]
    shifted: list[int]
    stage16: list[int]


class ExactDCT2Factorizer:
    """Exact recursive factorizer driven by canonical source rows."""

    def __init__(self, data: dict[str, Any] | None = None):
        self.data = data or load_canonical()
        self.source: dict[int, list[list[int]]] = {}
        self.inverse: dict[int, list[list[int]]] = {}
        for n in (4, 8, 16, 32, 64):
            c, a = _matrices(self.data, n)
            self.source[n] = c
            self.inverse[n] = a
        self._check_structure()

    def _check_structure(self) -> None:
        for n in (4, 8, 16, 32, 64):
            c = self.source[n]
            for k in range(0, n, 2):
                for p in range(n):
                    assert c[k][p] == c[k][n - 1 - p], (
                        f"DCT2-{n} even mirror failure k={k} p={p}"
                    )
            for k in range(1, n, 2):
                for p in range(n):
                    assert c[k][p] == -c[k][n - 1 - p], (
                        f"DCT2-{n} odd mirror failure k={k} p={p}"
                    )
        for n in (8, 16, 32, 64):
            c = self.source[n]
            half = self.source[n // 2]
            for m in range(n // 2):
                for p in range(n):
                    ref = half[m][p if p < n // 2 else n - 1 - p]
                    assert c[2 * m][p] == ref, (
                        f"DCT2-{n} even recursive failure m={m} p={p}"
                    )

    def _factor_raw(self, x: Sequence[int], n: int, trace: list[dict[str, Any]]) -> list[int]:
        if len(x) != n:
            raise ValueError(f"expected {n} inputs, got {len(x)}")
        if n == 4:
            # The smallest exact node is still represented as the same
            # even/odd pair butterfly; no approximation is introduced.
            even = []
            odd = []
            c = self.source[n]
            for p in range(n // 2):
                e = sum(c[2 * m][p] * int(x[2 * m]) for m in range(n // 2))
                o = sum(c[2 * m + 1][p] * int(x[2 * m + 1]) for m in range(n // 2))
                even.append(e)
                odd.append(o)
            y = [0] * n
            for p, (e, o) in enumerate(zip(even, odd)):
                y[p] = e + o
                y[n - 1 - p] = e - o
            trace.append({"n": n, "even": even, "odd": odd, "raw": list(y)})
            return y

        c = self.source[n]
        x_even = [int(x[2 * m]) for m in range(n // 2)]
        x_odd = [int(x[2 * m + 1]) for m in range(n // 2)]
        even = self._factor_raw(x_even, n // 2, trace)
        odd = [
            sum(c[2 * m + 1][p] * x_odd[m] for m in range(n // 2))
            for p in range(n // 2)
        ]
        y = [0] * n
        for p in range(n // 2):
            y[p] = even[p] + odd[p]
            y[n - 1 - p] = even[p] - odd[p]
        trace.append({"n": n, "even": list(even), "odd": list(odd), "raw": list(y)})
        return y

    def factorized_raw(self, x: Sequence[int]) -> list[int]:
        trace: list[dict[str, Any]] = []
        return self._factor_raw(x, N, trace)

    def factorized_raw_size(self, n: int, x: Sequence[int]) -> list[int]:
        """Evaluate one of the canonical DCT2 sizes using the same identity."""
        if n not in self.source:
            raise ValueError(f"unsupported canonical DCT2 size {n}")
        trace: list[dict[str, Any]] = []
        return self._factor_raw(x, n, trace)

    def factorized_details(self, x: Sequence[int]) -> FactorizedDetails:
        trace: list[dict[str, Any]] = []
        raw = self._factor_raw(x, N, trace)
        biased = [v + 32 for v in raw]
        shifted = [v >> 6 for v in biased]
        stage16 = [wrap_signed_16(v) for v in shifted]
        return FactorizedDetails(
            even=trace[-1]["even"],
            odd=trace[-1]["odd"],
            raw=raw,
            biased=biased,
            shifted=shifted,
            stage16=stage16,
        )

    def operator_math_raw(self, x: Sequence[int]) -> list[int]:
        """Independent A*x reference; A is consumed as stored, never transposed."""
        if len(x) != N:
            raise ValueError(f"expected {N} inputs, got {len(x)}")
        a = self.inverse[N]
        return [sum(a[i][j] * int(x[j]) for j in range(N)) for i in range(N)]

    def direct_details(self, x: Sequence[int]) -> FactorizedDetails:
        raw = self.operator_math_raw(x)
        biased = [v + 32 for v in raw]
        shifted = [v >> 6 for v in biased]
        stage16 = [wrap_signed_16(v) for v in shifted]
        return FactorizedDetails(
            even=[], odd=[], raw=raw, biased=biased, shifted=shifted, stage16=stage16
        )

    def operation_counts(self) -> dict[str, int | float]:
        # Recursive exact construction: at each N>4, the odd branch is a
        # (N/2)x(N/2) dense constant matrix; N=4 is the terminal pair node.
        mult = 8
        dot_add = 4
        butterfly_add_sub = 4
        for n in (8, 16, 32, 64):
            h = n // 2
            mult += h * h
            dot_add += h * (h - 1)
            butterfly_add_sub += n
        constants: set[int] = set()
        for n in (4, 8, 16, 32, 64):
            c = self.source[n]
            if n == 4:
                rows = range(n)
            else:
                rows = range(1, n, 2)
            for k in rows:
                for p in range(n // 2):
                    constants.add(int(c[k][p]))
        return {
            "direct_raw_multiplications": 64 * 64,
            "direct_raw_additions": 64 * 63,
            "factorized_constant_multiplications": mult,
            "factorized_dot_additions": dot_add,
            "factorized_butterfly_add_sub": butterfly_add_sub,
            "factorized_total_add_sub_nodes": dot_add + butterfly_add_sub,
            "factorized_mult_reduction_ratio": (64 * 64) / mult,
            "factorized_add_reduction_ratio": (64 * 63) / (dot_add + butterfly_add_sub),
            "unique_signed_constants_used": len(constants),
            "unique_absolute_constants_used": len({abs(v) for v in constants}),
        }


def fixed_point_details(factorizer: ExactDCT2Factorizer, x: Sequence[int]) -> dict[str, list[int]]:
    d = factorizer.factorized_details(x)
    return {
        "raw": d.raw,
        "biased": d.biased,
        "shifted": d.shifted,
        "stage16": d.stage16,
    }


if __name__ == "__main__":
    f = ExactDCT2Factorizer()
    print(json.dumps(f.operation_counts(), indent=2, sort_keys=True))
    for x in ([0] * 64, [1] + [0] * 63):
        assert f.factorized_raw(x) == f.operator_math_raw(x)
    print("P2F_SELFTEST PASS")
