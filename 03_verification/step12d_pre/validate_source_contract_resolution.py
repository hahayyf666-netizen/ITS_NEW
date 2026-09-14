"""Validate the post-closure Step12D-PRE source-contract resolution.

This checker validates a deliberate STOP state.  It does not promote VTM/H.266
reference semantics to contest requirements, edit RTL, or invoke Vivado.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def load(name: str) -> dict:
    return json.loads((EVIDENCE / name).read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def main() -> int:
    resolution = load("SOURCE_CONTRACT_RESOLUTION.json")
    decision = load("FINAL_CLOSURE_DECISION.json")
    manifest = load("STEP12D_PRE_MANIFEST.json")
    source = load("SOURCE_TRACEABILITY.json")
    legal = load("LEGAL_TRANSFORM_MATRIX.json")
    lfnst = load("LFNST_CASE_MATRIX.json")
    fixed = load("FIXED_POINT_CONTRACT.json")
    architecture = load("ARCHITECTURE_COMPARISON.json")
    cycle = load("CYCLE_RESOURCE_MODEL.json")

    assert resolution["status"] == "STOP_TWO_ROOT_SOURCE_BLOCKERS_REMAIN"
    assert {row["id"] for row in resolution["remaining_root_blockers"]} == {
        "SRC-DESC-COUPLING-01",
        "FIXED-POINT-SOURCE-01",
    }
    assert decision["status"] == "STOP"
    assert {row["id"] for row in decision["blockers"]} == {
        "SRC-DESC-COUPLING-01",
        "FIXED-POINT-SOURCE-01",
    }
    assert manifest["source_issue_count"] == 2
    assert manifest["rtl_tree_changed"] is False
    assert manifest["vivado_run"] is False
    assert manifest["new_unified_rtl_authorized"] is False

    assert lfnst["source_backed_closure"] is True
    assert lfnst["main_transform_pair_coupling"]["status"] == "OFFICIAL_DCT2_X_DCT2"
    assert legal["complete_descriptor_tuples"]["lfnst_pair_coupling"]["status"] == "official_dct2_x_dct2"
    assert cycle["lfnst"]["main_transform_pair"] == "DCT2_DCT2"
    assert fixed["status"] == "STOP_MAIN_TRANSFORM_SOURCE_CONTRACT_UNRESOLVED"
    assert fixed["source_resolution"]["main_transform_stage1_round_shift_wrap_or_clip"] == "unresolved"
    assert fixed["source_resolution"]["main_transform_final_signed10_mapping"] == "unresolved"
    assert architecture["recommended_candidate"] == "NONE_SOURCE_CONTRACT_BLOCKED"
    assert len(architecture["selection_blockers"]) == 2
    assert source["final_closure"]["resolution_evidence"] == "SOURCE_CONTRACT_RESOLUTION.json"

    r4c = ROOT / "02_rtl" / "rtl" / "p2f_dct2_64_b1_step102.sv"
    wrapper = ROOT / "02_rtl" / "rtl" / "step12b_dct2_64_wrapper.sv"
    assert sha256(r4c) == "15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1"
    assert sha256(wrapper) == "45E581A5CC542EE31ADAD49171076F804854B85D675B0CC37E2E8B0064D12A5C"

    print(json.dumps({
        "status": "PASS_EXPECTED_STOP_STATE",
        "pre_status": "STOP",
        "remaining_root_blockers": 2,
        "resolved_source_contract": "active_LFNST",
        "rtl_tree_changed": False,
        "vivado_run": False,
        "unified_rtl_authorized": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
