"""Validate the Step12D engineering-profile Gate A checkpoint.

The validator is intentionally read-only with respect to RTL and historical
evidence.  Use --emit to print the machine-readable validation record; the
caller may store that record through the repository patch workflow.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "27" / "step12d_engineering"
EMIT = "--emit" in sys.argv


def load(name: str) -> dict:
    return json.loads((EVIDENCE / name).read_text(encoding="utf-8"))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest().upper()


def main() -> int:
    profile = load("ENGINEERING_PROFILE.json")
    legal = load("LEGAL_TRANSFORM_MATRIX.json")
    lfnst = load("LFNST_CASE_MATRIX.json")
    p4 = load("P4_EXECUTION_PROOF.json")
    arch = load("ARCHITECTURE_DECISION.json")
    cycle = load("CYCLE_RESOURCE_CONTRACT.json")
    checkpoint = load("GATE_A_CHECKPOINT.json")
    qa = load("OFFICIAL_EXPERT_QA_EVIDENCE.json")

    assert profile["profile_name"] == "contest_engineering_vtm10_v1"
    assert profile["algorithm_binding"] == {
        "bit_depth": 10,
        "extended_precision_processing": False,
        "max_log2_transform_dynamic_range": 15,
        "derivation": "VTM SPS getMaxLog2TrDynamicRange: extended=false => 15",
    }
    assert profile["inverse_2d"]["vertical"] == {"shift": 7, "rounding_add": 64, "clip": [-32768, 32767]}
    assert profile["inverse_2d"]["horizontal"] == {"shift": 10, "rounding_add": 512, "clip": [-32768, 32767]}
    assert profile["official_equivalence"] == "NOT_PROVEN"
    assert profile["final10"]["default"] == "LOW10_TWOS_COMPLEMENT"
    assert profile["final10"]["alternate"]["mode"] == "SAT10"

    assert legal["descriptor"]["width_bits"] == 22
    assert legal["lfnst_off"]["count"] == 169
    assert len(legal["lfnst_off"]["tuples"]) == 169
    assert legal["lfnst_on"]["count"] == 200
    assert len(lfnst["active_cases"]) == 200
    assert all(row["official_legal"] == "unknown" for row in legal["lfnst_off"]["tuples"])
    assert all(row["official_legal"] is True for row in legal["lfnst_on"]["tuples"])

    expected_cases = {(name, n) for name, sizes in (("DCT2", (4, 8, 16, 32, 64)), ("DST7", (4, 8, 16, 32)), ("DCT8", (4, 8, 16, 32))) for n in sizes}
    actual_cases = {(row["transform"], row["N"]) for row in p4["cases"]}
    assert actual_cases == expected_cases
    assert all(row["group_outputs"] == 4 and row["group_ii"] == 1 and row["vector_ii"] == row["N"] // 4 for row in p4["cases"])
    assert arch["recommended_candidate"] == "C_PRIME"
    assert "new_profile_path" in arch["dct2_64_ownership"]
    assert cycle["throughput"]["backpressure"].startswith("completion latency is stall-dependent")
    assert qa["confirmed_contracts"]["axis_order"] == "vertical_then_horizontal"

    expected_paths = {
        "r4c": ROOT / checkpoint["immutable_files"]["r4c"]["path"],
        "wrapper": ROOT / checkpoint["immutable_files"]["wrapper"]["path"],
        "xdc": ROOT / checkpoint["immutable_files"]["xdc"]["path"],
        "canonical": ROOT / checkpoint["immutable_files"]["canonical"]["path"],
    }
    hash_checks = {}
    for key, path in expected_paths.items():
        actual = sha256(path)
        expected = checkpoint["immutable_files"][key]["sha256"]
        assert actual == expected, (key, actual, expected)
        hash_checks[key] = {"expected": expected, "actual": actual, "match": True}
    rtl_diff = subprocess.check_output(["git", "diff", "--name-only", "HEAD", "--", "02_rtl/rtl"], cwd=ROOT, text=True).splitlines()
    # Gate A freezes the historical R4C/wrapper boundary.  Gate B is
    # explicitly authorized to add the new unified RTL outside that boundary,
    # so a later re-run must reject edits to frozen files but may see these
    # two newly authorized paths.
    allowed_unified = {
        "02_rtl/rtl/unified_p4_kernel.sv",
        "02_rtl/rtl/unified_its_wrapper.sv",
    }
    assert set(rtl_diff) <= allowed_unified, rtl_diff

    result = {
        "schema": "step12d_engineering.gate_a_validation.v1",
        "status": "PASS_GATE_A_ENGINEERING_PROFILE",
        "profile": profile["profile_name"],
        "official_equivalence": profile["official_equivalence"],
        "historical_hidden_golden_equivalence": profile["historical_hidden_golden_equivalence"],
        "counts": {"lfnst_off_engineering_superset": len(legal["lfnst_off"]["tuples"]), "lfnst_on_active": len(lfnst["active_cases"]), "one_d_cases": len(actual_cases)},
        "architecture_candidate": arch["recommended_candidate"],
        "immutable_hash_checks": hash_checks,
        "rtl_tree_diff": rtl_diff,
        "vivado_run": False,
        "unified_rtl_authorized": True,
        "gate_b_entry": "AUTHORIZED: implement unified P4 1-D RTL outside frozen v3.5-18 files",
        "residual_risks": ["lfnst_idx=0 exact official pair subset remains unknown; supported per-axis superset is explicitly not claimed official", "engineering profile/LOW10 is reproducible but historical hidden-golden equivalence remains unknown"],
    }
    if EMIT:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        (EVIDENCE / "GATE_A_VALIDATION.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
