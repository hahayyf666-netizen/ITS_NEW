"""Derive explicitly sourced transform-pair candidates for Step12D-PRE.

This is deliberately not an official legal-matrix extractor.  The Huawei
attachment supplies shape rows, while the designated VTM source supplies
context-dependent transform-pair rules.  The output therefore carries
reference-candidate provenance and must not be promoted to ``official_legal``
without an interface/context mapping review.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout", action="store_true", help="print the evidence JSON without writing it")
    args = parser.parse_args()
    legal = json.loads((EVIDENCE / "LEGAL_TRANSFORM_MATRIX.json").read_text(encoding="utf-8"))
    shape = legal["official_shape_support"]
    pairs = [
        ("DCT2", "DCT2", "DCT2", "default/non-MTS and implicit fallback"),
        ("DST7", "DST7", "DCT8_DST7_intersection", "explicit MTS and implicit/ISP both axes <=16"),
        ("DCT8", "DST7", "DCT8_DST7_intersection", "explicit MTS pair"),
        ("DST7", "DCT8", "DCT8_DST7_intersection", "explicit MTS pair"),
        ("DCT8", "DCT8", "DCT8_DST7_intersection", "explicit MTS pair"),
        ("DST7", "DCT2", "DCT2_DST7_intersection", "implicit/ISP width <=16, height >16"),
        ("DCT2", "DST7", "DCT2_DST7_intersection", "implicit/ISP width >16, height <=16"),
    ]
    intersection = sorted(set(shape["DCT8"]) & set(shape["DST7"]))
    assert len(intersection) == 16

    tuple_map: dict[tuple[int, int, str, str, int], dict[str, object]] = {}
    for hor, ver, shape_rule, context in pairs:
        if shape_rule == "DCT2":
            support = shape["DCT2"]
        elif shape_rule == "DCT2_DST7_intersection":
            support = sorted(set(shape["DCT2"]) & set(shape["DST7"]))
        else:
            support = intersection
        for block in support:
            width, height = (int(x) for x in block.split("x"))
            if shape_rule == "DCT2_DST7_intersection":
                if hor == "DST7" and not (width <= 16 and height > 16):
                    continue
                if hor == "DCT2" and not (width > 16 and height <= 16):
                    continue
            key = (width, height, hor, ver, 0)
            entry = tuple_map.setdefault(key, {
                "width": width,
                "height": height,
                "hor_type": hor,
                "ver_type": ver,
                "lfnst_idx": 0,
                "status": "reference_candidate_not_official_legal",
                "source_id": "VTM_TRQUANT_GETTRTYPES",
                "source_contexts": [],
            })
            entry["source_contexts"].append(context)

    tuples = list(tuple_map.values())
    keys = [(t["width"], t["height"], t["hor_type"], t["ver_type"], t["lfnst_idx"]) for t in tuples]
    assert len(keys) == len(set(keys))
    assert len(tuples) == 25 + 4 * 16 + 2 * 3

    out = {
        "schema": "step12d_pre.reference_transform_tuples.v1",
        "status": "REFERENCE_CANDIDATES_ONLY_OFFICIAL_MAPPING_PENDING",
        "official_legal": False,
        "source_id": "VTM_TRQUANT_GETTRTYPES",
        "source_locator": "04_reference/VTM/source/Lib/CommonLib/TrQuant.cpp:getTrTypes around lines 651-755",
        "derivation": {
            "DCT2_DCT2": "official DCT2 shape rows",
            "explicit_MTS_pairs": "intersection(official DCT8 shape rows, official DST7 shape rows)",
            "implicit_MTS_pairs": "dimension-specific DST7/DCT2 and DCT2/DST7 subsets from VTM width/height predicates",
            "forbidden": "No default width x height x hor_type x ver_type Cartesian product",
        },
        "tuple_count_lfnst_off": len(tuples),
        "tuples": tuples,
        "lfnst": {
            "status": "PENDING_OFFICIAL_OR_CONTEXT_MAPPING",
            "shape_rows_are_not_pair_rules": True,
            "reason": "Neither the attachment rows nor getTrTypes alone establish the complete lfnst/type-pair descriptor coupling.",
        },
    }
    if args.stdout:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0
    else:
        target = EVIDENCE / "REFERENCE_TRANSFORM_TUPLES.json"
        target.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "status": out["status"],
        "tuple_count_lfnst_off": len(tuples),
        "dct2_dct2_count": 25,
        "non_dct2_pair_count": 6,
        "non_dct2_shape_intersection_count": len(intersection),
        "official_legal": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
