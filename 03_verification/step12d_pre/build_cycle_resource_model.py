"""Build the non-physical Step12D-PRE cycle/resource model."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def direct_products(n: int) -> int:
    return 4 * n


def build_model() -> dict:
    reference = json.loads((EVIDENCE / "REFERENCE_TRANSFORM_TUPLES.json").read_text(encoding="utf-8"))
    records = []
    for item in reference["tuples"]:
        width = int(item["width"])
        height = int(item["height"])
        v_groups = height // 4
        h_groups = width // 4
        v_cycles = width * v_groups
        h_cycles = height * h_groups
        assert v_cycles == width * height // 4
        assert h_cycles == width * height // 4
        records.append({
            "width": width,
            "height": height,
            "hor_type": item["hor_type"],
            "ver_type": item["ver_type"],
            "lfnst_idx": item["lfnst_idx"],
            "tuple_status": item["status"],
            "vertical_vectors": width,
            "vertical_vector_length": height,
            "vertical_groups_per_vector": v_groups,
            "vertical_compute_cycles": v_cycles,
            "horizontal_vectors": height,
            "horizontal_vector_length": width,
            "horizontal_groups_per_vector": h_groups,
            "horizontal_compute_cycles": h_cycles,
            "single_shared_fabric_compute_cycles": v_cycles + h_cycles,
            "final_coefficients": width * height,
            "result_beats": width * height // 4,
            "single_shared_fabric_final_equivalent_points_per_cycle": 2.0,
            "hor_direct_products_per_cycle": direct_products(width) if width <= 32 else None,
            "ver_direct_products_per_cycle": direct_products(height) if height <= 32 else None,
        })

    return {
        "schema": "step12d_pre.cycle_resource_model.v1",
        "status": "PASS_REFERENCE_CANDIDATE_GEOMETRY_RESOURCE_LOWER_BOUND_NOT_PHYSICAL_PROOF",
        "tuple_scope": "89 VTM reference candidates with lfnst_idx=0; not official legal matrix",
        "throughput_contract": {
            "one_d_group": "4 complete outputs",
            "group_ii": 1,
            "candidate_vector_ii": "N/4",
            "single_shared_fabric_2d_equivalent": "2 final coefficients/cycle before boundary overhead",
            "output_interface": "4 final coefficients per output_fire when req permits",
        },
        "candidate_resource_summary": {
            "A": {
                "description": "fully shared multiplier and reduction fabric",
                "direct_p4_multiplier_lower_bound_N_le_32": 128,
                "dct2_64": "factorized 128-lane reference required; direct matrix form is 256 products/cycle",
                "physical_selection": "pending reduction/mux/bandwidth analysis",
            },
            "B": {
                "description": "shared multipliers with family-specific reductions",
                "direct_p4_multiplier_lower_bound_N_le_32": 128,
                "dct2_64": "factorized 128-lane reference required; direct matrix form is 256 products/cycle",
                "physical_selection": "pending reduction/mux/bandwidth analysis",
            },
            "C": {
                "description": "frozen R4C-64 plus new <=32/LFNST kernel",
                "parallel_lower_bound": 256,
                "time_shared_lower_bound": 128,
                "physical_selection": "pending overlap/mode-switch analysis",
            },
        },
        "lfnst": {
            "status": "PENDING_OFFICIAL_PAIR_MAPPING_AND_FABRIC_OWNERSHIP",
            "ntrs16_or_48_direct_products_per_cycle_at_p4": 64,
        },
        "records": records,
        "physical_proof": False,
        "vivado_run": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout", action="store_true")
    args = parser.parse_args()
    model = build_model()
    if args.stdout:
        print(json.dumps(model, ensure_ascii=False, indent=2))
        return 0
    (EVIDENCE / "CYCLE_RESOURCE_MODEL.json").write_text(
        json.dumps(model, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({
        "status": model["status"],
        "reference_tuple_count": len(model["records"]),
        "physical_proof": False,
        "vivado_run": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
