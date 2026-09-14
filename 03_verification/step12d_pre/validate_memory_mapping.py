"""Validate the generated logical rectangular-memory proof."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def main() -> int:
    proof = json.loads((EVIDENCE / "MEMORY_MAPPING_PROOF.json").read_text(encoding="utf-8"))
    assert proof["status"] == "PASS_LOGICAL_MAPPING_CONFLICT_FREE_NOT_PHYSICAL_PROOF"
    assert proof["physical_proof"] is False
    assert proof["official_shape_rows_checked"] == 57
    assert proof["unique_shape_rows"] == 25
    assert proof["conflict_checks"]["all_four_lane_banks_distinct"] is True
    assert proof["conflict_checks"]["all_addresses_in_range"] is True
    assert proof["conflict_checks"]["result_raster_order"] is True
    for record in proof["records"]:
        assert record["result_beats"] == record["width"] * record["height"] // 4
        assert record["status"] == "PASS_LOGICAL_NO_4_LANE_BANK_CONFLICT"
    print(json.dumps({
        "status": "PASS_LOGICAL_MEMORY_MAPPING",
        "shape_type_rows": proof["official_shape_rows_checked"],
        "unique_shapes": proof["unique_shape_rows"],
        "physical_proof": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
