"""Create the Step12B functional-prototype SHA-256 manifest."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "05_audit" / "current" / "17"
FILES = [
    "01_docs/current/Step12B.md",
    "02_rtl/rtl/p2f_dct2_64_b1_step102.sv",
    "02_rtl/rtl/step12b_dct2_64_wrapper.sv",
    "03_verification/scripts/step12b_cycle_model.py",
    "03_verification/scripts/gen_step12b_rtl_random_vectors.py",
    "03_verification/scripts/validate_step12b_rtl_trace.py",
    "03_verification/scripts/run_step12b_checks.ps1",
    "03_verification/tb/step12b_dct2_64_wrapper_tb.sv",
    "03_verification/tb/step12b_dct2_64_wrapper_two_tu_tb.sv",
    "03_verification/tb/step12b_dct2_64_wrapper_descriptor_tb.sv",
    "03_verification/tb/step12b_dct2_64_wrapper_epoch_tb.sv",
    "03_verification/tb/step12b_dct2_64_wrapper_random_tb.sv",
    "03_verification/sim/run_step12b.do",
    "03_verification/sim/run_step12b_synthesis.do",
    "03_verification/logs/step12b_wrapper_normal.log",
    "03_verification/logs/step12b_wrapper_normal_compile.log",
    "03_verification/logs/step12b_wrapper_synthesis.log",
    "03_verification/logs/step12b_wrapper_synthesis_compile.log",
    "03_verification/logs/step12b_wrapper_two_tu_normal.log",
    "03_verification/logs/step12b_wrapper_two_tu_synthesis.log",
    "03_verification/logs/step12b_wrapper_descriptor_normal.log",
    "03_verification/logs/step12b_wrapper_descriptor_synthesis.log",
    "03_verification/logs/step12b_wrapper_epoch_normal.log",
    "03_verification/logs/step12b_wrapper_epoch_synthesis.log",
    "03_verification/logs/step12b_wrapper_random_normal.log",
    "03_verification/logs/step12b_wrapper_random_synthesis.log",
    "03_verification/logs/step12b_wrapper_extreme_normal.log",
    "03_verification/logs/step12b_wrapper_extreme_synthesis.log",
    "03_verification/generated/step12b_random_input.mem",
    "03_verification/generated/step12b_random_expected.mem",
    "03_verification/generated/step12b_random_meta.json",
    "03_verification/generated/step12b_extreme_input.mem",
    "03_verification/generated/step12b_extreme_expected.mem",
    "05_audit/current/17/step12b_rtl_event_trace_normal.csv",
    "05_audit/current/17/step12b_rtl_event_trace_synthesis.csv",
    "05_audit/current/17/step12b_cycle_results.json",
    "05_audit/current/17/step12b_cycle_trace.json",
    "05_audit/current/17/step12b_mutation_manifest.json",
    "05_audit/current/17/V35_STEP12B_REPORT.md",
]


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    entries = []
    for rel in FILES:
        path = ROOT / rel
        entries.append({"path": rel, "exists": path.is_file(),
                        "sha256": sha(path) if path.is_file() else None,
                        "bytes": path.stat().st_size if path.is_file() else 0})
    payload = {"version": "V3.5-17-Step12B-functional-candidate",
               "status": "functional_gate_pass_pending_remote_freeze",
               "r4c_unchanged_reference": "02_rtl/rtl/p2f_dct2_64_b1_step102.sv",
               "files": entries}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "STEP12B_MANIFEST.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")
    missing = [e["path"] for e in entries if not e["exists"]]
    if missing:
        raise SystemExit(f"missing: {missing}")
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
