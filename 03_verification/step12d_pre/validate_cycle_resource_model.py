"""Validate the Step12D-PRE reference cycle/resource model."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def main() -> int:
    model = json.loads((EVIDENCE / "CYCLE_RESOURCE_MODEL.json").read_text(encoding="utf-8"))
    assert model["status"] == "PASS_REFERENCE_CANDIDATE_GEOMETRY_RESOURCE_LOWER_BOUND_NOT_PHYSICAL_PROOF"
    assert model["physical_proof"] is False
    assert model["vivado_run"] is False
    assert len(model["records"]) == 89
    assert model["throughput_contract"]["group_ii"] == 1
    assert model["candidate_resource_summary"]["A"]["direct_p4_multiplier_lower_bound_N_le_32"] == 128
    assert model["candidate_resource_summary"]["B"]["direct_p4_multiplier_lower_bound_N_le_32"] == 128
    assert model["candidate_resource_summary"]["C"]["parallel_lower_bound"] == 256
    for row in model["records"]:
        area = row["width"] * row["height"]
        assert row["single_shared_fabric_compute_cycles"] == area // 2
        assert row["final_coefficients"] == area
        assert row["result_beats"] == area // 4
        assert row["single_shared_fabric_final_equivalent_points_per_cycle"] == 2.0
    print(json.dumps({
        "status": "PASS_CYCLE_RESOURCE_MODEL",
        "reference_tuple_count": len(model["records"]),
        "single_shared_fabric_equivalent": "2 final coefficients/cycle before boundary overhead",
        "physical_proof": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
