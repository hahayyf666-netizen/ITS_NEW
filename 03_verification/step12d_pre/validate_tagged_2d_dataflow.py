"""Validate the tagged two-dimensional reference dataflow proof."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def main() -> int:
    proof = json.loads((EVIDENCE / "TAGGED_2D_DATAFLOW_PROOF.json").read_text(encoding="utf-8"))
    assert proof["status"] == "PASS_TAGGED_2D_DATAFLOW_REFERENCE_NOT_OFFICIAL_OR_PHYSICAL_PROOF"
    assert proof["physical_proof"] is False
    assert proof["vivado_run"] is False
    assert len(proof["records"]) == 95
    for record in proof["records"]:
        area = record["width"] * record["height"]
        assert record["input_tagged_events"] == 2 * area
        assert record["intermediate_write_events"] == 2 * area
        assert record["intermediate_read_events"] == 2 * area
        assert record["result_output_events"] == 2 * area
        assert record["raster_order"] is True
        assert record["single_intermediate_owner_serialized"] is True
        assert all(bp["fires"] == area // 4 and bp["done_pulses"] == 1 for bp in record["backpressure"])
    print(json.dumps({
        "status": "PASS_TAGGED_2D_DATAFLOW",
        "tuple_count": len(proof["records"]),
        "physical_proof": False,
        "official_tuple_proof": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
