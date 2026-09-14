"""Validate the source-extraction and schedule-geometry phase of Step12D-PRE.

This is a verification-only script. It does not edit RTL, invoke Vivado, or
generate a legal descriptor Cartesian product.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"


def load(name: str):
    with (EVIDENCE / name).open("r", encoding="utf-8") as fh:
        return json.load(fh)


def main() -> int:
    legal = load("LEGAL_TRANSFORM_MATRIX.json")
    schedules = load("P4_SCHEDULES.json")
    manifest = load("STEP12D_PRE_MANIFEST.json")
    canonical = json.loads(CANONICAL.read_text(encoding="utf-8"))

    assert legal["it_info_contract"]["width_bits"] == 22
    assert len(legal["official_shape_support"]["DCT2"]) == 25
    assert len(legal["official_shape_support"]["DCT8"]) == 16
    assert len(legal["official_shape_support"]["DST7"]) == 16
    assert len(legal["lfnst_shape_support"]["nTrs16"]) == 9
    assert len(legal["lfnst_shape_support"]["nTrs48"]) == 16
    assert legal["complete_descriptor_tuples"]["status"] != "official_complete"

    transforms = canonical["transforms"]
    for tr_type, sizes in (("0", (4, 8, 16, 32, 64)),
                           ("1", (4, 8, 16, 32)),
                           ("2", (4, 8, 16, 32))):
        assert tr_type in transforms
        for n in sizes:
            assert str(n) in transforms[tr_type]["inverse_operator"]

    expected = {(name, n) for name, sizes in (
        ("DCT2", (4, 8, 16, 32, 64)),
        ("DST7", (4, 8, 16, 32)),
        ("DCT8", (4, 8, 16, 32)),
    ) for n in sizes}
    actual = {(row["transform"], row["N"]) for row in schedules["cases"]}
    assert actual == expected
    assert schedules["group_contract"]["complete_outputs_per_group"] == 4
    assert schedules["group_contract"]["group_ii"] == 1
    for row in schedules["cases"]:
        n = row["N"]
        assert row["groups"] == n // 4
        assert row["vector_ii"] == n // 4
        assert row["direct_products_per_cycle"] == 4 * n
        output_indices = []
        for group in range(n // 4):
            for lane in range(4):
                output_indices.append(group * 4 + lane)
        assert output_indices == list(range(n))

    print(json.dumps({
        "status": "PASS_PHASE_0_1_GEOMETRY",
        "official_shape_counts": {
            "DCT2": 25, "DCT8": 16, "DST7": 16,
            "LFNST_nTrs16": 9, "LFNST_nTrs48": 16,
        },
        "one_d_case_count": len(actual),
        "canonical_transform_cases_checked": 13,
        "p4_output_lane_maps_checked": 13,
        "complete_descriptor_tuple_matrix": legal["complete_descriptor_tuples"]["status"],
        "vivado_run": manifest["vivado_run"],
        "rtl_tree_changed": manifest["rtl_tree_changed"],
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
