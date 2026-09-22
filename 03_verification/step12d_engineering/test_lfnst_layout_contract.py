"""Independent directed checks for the fixed LFNST layout contract.

The expected coordinates below are written out from the source-backed
contract rather than derived from the implementation helper.  This prevents
the two Python models from silently sharing a wrong 48-output permutation.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_gate_c_model import (
    CANONICAL,
    LFNST_INPUT_SCAN,
    apply_lfnst,
    lfnst_output_scan,
    load_json,
)
from run_vtm_engineering_oracle import (
    LFNST_INPUT_SCAN as ORACLE_INPUT_SCAN,
    lfnst_output_scan as oracle_output_scan,
)


EXPECTED_INPUT = [
    (0, 0), (1, 0), (0, 1), (2, 0),
    (1, 1), (0, 2), (3, 0), (2, 1),
    (1, 2), (0, 3), (3, 1), (2, 2),
    (1, 3), (3, 2), (2, 3), (3, 3),
]
EXPECTED_OUTPUT_16 = [(r, c) for r in range(4) for c in range(4)]
EXPECTED_OUTPUT_48 = (
    [(r, c) for r in range(4) for c in range(8)] +
    [(r, c) for r in range(4, 8) for c in range(4)]
)


def main() -> int:
    assert list(LFNST_INPUT_SCAN) == EXPECTED_INPUT
    assert list(ORACLE_INPUT_SCAN) == EXPECTED_INPUT
    assert lfnst_output_scan(16) == EXPECTED_OUTPUT_16
    assert lfnst_output_scan(48) == EXPECTED_OUTPUT_48
    assert oracle_output_scan(16) == EXPECTED_OUTPUT_16
    assert oracle_output_scan(48) == EXPECTED_OUTPUT_48

    # These are the boundary indices most likely to expose block-major vs
    # top-4x8 row-major confusion.
    expected_points = {
        0: (0, 0), 4: (0, 4), 7: (0, 7), 8: (1, 0),
        15: (1, 7), 16: (2, 0), 31: (3, 7),
        32: (4, 0), 47: (7, 3),
    }
    for index, point in expected_points.items():
        assert EXPECTED_OUTPUT_48[index] == point
    assert len(set(EXPECTED_OUTPUT_48)) == 48

    # Poison the old nTrs=48 tail (bottom-right 4x4).  It must be
    # observationally equivalent to an all-zero tail after LFNST writeback.
    canonical = load_json(CANONICAL)
    clean = [[0 for _ in range(8)] for _ in range(8)]
    poisoned = [row[:] for row in clean]
    poisoned[4][4] = 32767
    poisoned[7][7] = -32768
    clean_result = apply_lfnst(clean, 8, 8, 0, 1, canonical, 15)
    poison_result = apply_lfnst(poisoned, 8, 8, 0, 1, canonical, 15)
    assert poison_result == clean_result

    print("PASS_LFNST_LAYOUT_CONTRACT scatter=16/48 boundaries=9 tail_poison=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
