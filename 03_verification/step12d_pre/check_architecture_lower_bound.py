"""Check the arithmetic lower-bound claims used in the Step12D PRE comparison."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def main() -> int:
    data = json.loads((EVIDENCE / "ARCHITECTURE_LOWER_BOUND.json").read_text(encoding="utf-8"))
    assert data["direct_p4"]["max_products_per_cycle_requirement"] == 4 * 32
    assert data["direct_p4"]["lfnst_ntrs16_or_48_products_per_cycle_requirement"] == 4 * 16
    assert data["dct2_64_reference"]["direct_matrix_product_count_per_cycle"] == 4 * 64
    assert data["candidates"]["A"]["same_cycle_no_reuse_reference_multiplier_count"] == 128
    assert data["candidates"]["B"]["same_cycle_no_reuse_reference_multiplier_count"] == 128
    assert data["candidates"]["C"]["parallel_reference_instance_count"] == 256
    assert data["vivado_run"] is False
    print(json.dumps({"status": "PASS_ANALYTIC_LOWER_BOUND", "physical_proof": False}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
