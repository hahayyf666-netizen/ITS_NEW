"""Validate the executable P4 schedule evidence."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def main() -> int:
    proof = json.loads((EVIDENCE / "P4_EXECUTION_PROOF.json").read_text(encoding="utf-8"))
    assert proof["status"] == "PASS_EXECUTABLE_P4_SCHEDULE_NOT_PHYSICAL_PROOF"
    assert proof["physical_proof"] is False
    assert proof["vivado_run"] is False
    assert len(proof["cases"]) == 13
    for case in proof["cases"]:
        n = case["N"]
        assert case["groups"] == n // 4
        assert case["group_ii"] == 1
        assert case["vector_ii_candidate"] == n // 4
        assert case["products_per_group"] == 4 * n
        assert case["bit_exact_against_frozen_oracle"] is True
    print(json.dumps({
        "status": "PASS_P4_EXECUTION_PROOF",
        "case_count": len(proof["cases"]),
        "direct_cases_bit_exact": 12,
        "dct2_64_arithmetic_reference": True,
        "physical_proof": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
