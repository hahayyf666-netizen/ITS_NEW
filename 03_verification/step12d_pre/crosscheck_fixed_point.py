"""Independent fixed-point cross-check for Step12D-PRE.

This checker implements its own dot-product and signed-16 post-processing,
then compares the result with the frozen v3.4 oracle. It does not import the
oracle's arithmetic functions and never modifies RTL or evidence files.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"
ORACLE_DIR = ROOT / "04_reference" / "oracle"


def load_frozen_oracle():
    sys.path.insert(0, str(ORACLE_DIR))
    spec = importlib.util.spec_from_file_location(
        "frozen_v34_rtl_bitexact", ORACLE_DIR / "v34_rtl_bitexact.py"
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load frozen oracle")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def wrap16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def independent_main(data: dict, tr_type: int, n: int, vector: list[int]) -> list[int]:
    matrix = data["transforms"][str(tr_type)]["inverse_operator"][str(n)]
    raw = [sum(matrix[i][j] * vector[j] for j in range(n)) for i in range(n)]
    return [wrap16((value + 32) >> 6) for value in raw]


def vector_for(n: int, salt: int) -> list[int]:
    return [((i * 37 + salt * 19) % 511) - 255 for i in range(n)]


def main() -> int:
    data = json.loads(CANONICAL.read_text(encoding="utf-8"))
    frozen = load_frozen_oracle()
    cases = [(0, n) for n in (4, 8, 16, 32, 64)]
    cases += [(1, n) for n in (4, 8, 16, 32)]
    cases += [(2, n) for n in (4, 8, 16, 32)]
    checks = 0
    for tr_type, n in cases:
        for salt in (0, 1, 7):
            vector = vector_for(n, salt)
            got = independent_main(data, tr_type, n, vector)
            expected = frozen.main_1d(vector, tr_type, n)
            assert got == expected, (tr_type, n, salt)
            checks += 1
        for index in (0, n - 1):
            vector = [0] * n
            vector[index] = 1
            assert independent_main(data, tr_type, n, vector) == frozen.main_1d(vector, tr_type, n)
            checks += 1
    print(json.dumps({
        "status": "PASS_REFERENCE_FIXED_POINT_CROSSCHECK",
        "cases": len(cases),
        "vectors_per_case": 5,
        "checks": checks,
        "rule_scope": "reference cross-check only; official per-case promotion remains pending source audit",
        "rtl_modified": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
