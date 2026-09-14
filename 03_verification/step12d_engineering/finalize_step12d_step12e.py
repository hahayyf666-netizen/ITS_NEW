"""Assemble the final Step12D/Step12E engineering batch evidence.

The script is intentionally conservative: a passing software model and a
present RTL file do not become an HDL functional PASS without an actual
normal- and SYNTHESIS-mode simulator run.  In environments without ModelSim
or another HDL simulator it emits a finite Gate-C P1 STOP instead.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "27" / "step12d_engineering"
FROZEN = {
    "r4c": (ROOT / "02_rtl/rtl/p2f_dct2_64_b1_step102.sv",
            "15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1"),
    "wrapper": (ROOT / "02_rtl/rtl/step12b_dct2_64_wrapper.sv",
                 "45E581A5CC542EE31ADAD49171076F804854B85D675B0CC37E2E8B0064D12A5C"),
    "xdc": (ROOT / "03_verification/vivado/step12c_wrapper_2ns.xdc",
            "5FC2465A7E852A99BE1B7C6B484C9EDF85FB96DDAF256F277D4A2E3DB467F2F3"),
}
UNIFIED = ROOT / "02_rtl/rtl/unified_its_wrapper.sv"
TB = ROOT / "03_verification/tb/unified_its_wrapper_tb.sv"
MODEL = EVIDENCE / "GATE_C_MODEL_VALIDATION.json"
EMIT = "--emit" in sys.argv


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest().upper()


def simulator_candidates() -> list[str]:
    names = ["vsim", "vlog", "iverilog", "verilator", "xvlog"]
    return [name for name in names if shutil.which(name)]


def git_head() -> str:
    return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT,
                                   text=True).strip()


def build() -> dict[str, Any]:
    model = json.loads(MODEL.read_text(encoding="utf-8"))
    rtl_text = UNIFIED.read_text(encoding="utf-8")
    tb_text = TB.read_text(encoding="utf-8")
    required_rtl_markers = [
        "module unified_its_wrapper",
        "always_ff @(posedge clk or negedge rst_n)",
        "SLOT_FREE", "SLOT_FILL", "SLOT_READY", "SLOT_OUT",
        "descriptor_legal", "it_data_out_vld = output_active && it_data_out_req",
        "output_last_fire", "COEFF_FILE", "LFNST_FILE",
    ]
    assert all(marker in rtl_text for marker in required_rtl_markers)
    assert "unified_its_wrapper dut" in tb_text
    frozen_checks = {
        name: {"expected": expected, "actual": sha256(path),
               "match": sha256(path) == expected}
        for name, (path, expected) in FROZEN.items()
    }
    assert all(row["match"] for row in frozen_checks.values())
    sims = simulator_candidates()
    model_pass = model["status"] == "PASS_ENGINEERING_PROFILE_2D_PROTOCOL_MODEL"
    if model_pass and sims:
        status = "GATE_C_HDL_SIMULATION_PENDING_COMMAND_EXECUTION"
        blocker: list[str] = []
    else:
        status = "STOP_GATE_C_HDL_SIMULATOR_UNAVAILABLE"
        blocker = [
            "No HDL simulator executable (vsim/vlog/iverilog/verilator/xvlog) is available in the current environment; normal and SYNTHESIS-mode wrapper simulation cannot be claimed.",
        ]
    return {
        "schema": "step12d_engineering.step12d_step12e_final_manifest.v1",
        "status": status,
        "phase": "step12d_engineering_closure_to_step12e_unified_functional_rtl",
        "created_from_commit": git_head(),
        "base_tag": "v3.5-18",
        "base_tag_target": "7415b0acb33481af1845f63e16b93ce7c33b977b",
        "frozen_boundary": {
            "v35_18_unchanged": True,
            "r4c_unchanged": True,
            "old_step12b_wrapper_unchanged": True,
            "xdc_unchanged": True,
            "hashes": frozen_checks,
        },
        "engineering_profile": "contest_engineering_vtm10_v1",
        "official_equivalence": "NOT_PROVEN",
        "historical_hidden_golden_equivalence": "UNKNOWN",
        "gate_a": {"status": "PASS_GATE_A_ENGINEERING_PROFILE",
                   "validator": "GATE_A_VALIDATION.json"},
        "gate_b": {"status": "PASS_UNIFIED_P4_FUNCTIONAL_SCHEDULE_CONTRACT",
                   "validator": "GATE_B_VALIDATION.json",
                   "rtl": "02_rtl/rtl/unified_p4_kernel.sv"},
        "gate_c_model": {"status": model["status"],
                         "validator": "GATE_C_MODEL_VALIDATION.json",
                         "cases": model["aggregate"]["cases"],
                         "beats": model["aggregate"]["beats"],
                         "dropped_beats": model["aggregate"]["dropped_beats"],
                         "duplicated_beats": model["aggregate"]["duplicated_beats"],
                         "ownership_violations": model["aggregate"]["ownership_violations"]},
        "unified_rtl": {"present": UNIFIED.exists(), "path": str(UNIFIED.relative_to(ROOT)).replace("\\", "/"),
                        "sha256": sha256(UNIFIED), "tb": str(TB.relative_to(ROOT)).replace("\\", "/")},
        "hdl_simulation": {"normal": False, "synthesis_mode": False,
                           "simulator_candidates": sims,
                           "physical_timing_proof": False},
        "blockers": blocker,
        "next_action": "Run unified_its_wrapper_tb.sv in normal and SYNTHESIS compile modes with an available HDL simulator; only then reevaluate Gate C PASS." if blocker else "Execute the available HDL simulator in both modes and record logs before declaring Gate C.",
        "scope_guard": {
            "no_vivado": True,
            "no_xdc_change": True,
            "no_frozen_r4c_change": True,
            "no_old_wrapper_change": True,
            "p2_p3_enhancements_nonblocking": True,
        },
    }


def main() -> int:
    result = build()
    if EMIT:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        EVIDENCE.joinpath("STEP12D_STEP12E_FINAL_MANIFEST.json").write_text(
            json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print(json.dumps({"status": result["status"], "blockers": result["blockers"]}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
