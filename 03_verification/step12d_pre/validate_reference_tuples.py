"""Validate reference transform tuple provenance and non-Cartesian derivation."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def main() -> int:
    data = json.loads((EVIDENCE / "REFERENCE_TRANSFORM_TUPLES.json").read_text(encoding="utf-8"))
    assert data["official_legal"] is False
    assert data["status"] == "REFERENCE_CANDIDATES_ONLY_OFFICIAL_MAPPING_PENDING"
    tuples = data["tuples"]
    assert len(tuples) == 95
    assert all(t["status"] == "reference_candidate_not_official_legal" for t in tuples)
    assert all(t["lfnst_idx"] == 0 for t in tuples)
    keys = {(t["width"], t["height"], t["hor_type"], t["ver_type"], t["lfnst_idx"]) for t in tuples}
    assert len(keys) == len(tuples)
    assert sum(t["hor_type"] == "DCT2" and t["ver_type"] == "DCT2" for t in tuples) == 25
    assert sum(t["hor_type"] != "DCT2" and t["ver_type"] != "DCT2" for t in tuples) == 64
    assert sum(t["hor_type"] == "DST7" and t["ver_type"] == "DCT2" for t in tuples) == 3
    assert sum(t["hor_type"] == "DCT2" and t["ver_type"] == "DST7" for t in tuples) == 3
    assert data["lfnst"]["status"] == "PENDING_OFFICIAL_OR_CONTEXT_MAPPING"
    print(json.dumps({
        "status": "PASS_REFERENCE_TUPLE_PROVENANCE",
        "tuple_count": len(tuples),
        "official_legal": False,
        "lfnst_mapping_pending": True,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
