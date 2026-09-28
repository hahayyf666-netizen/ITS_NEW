"""Validate the SAT10 profile without reopening historical Gate-A evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

from profile_contract import (
    SAT10_PROFILE_NAME,
    SAT10_PROFILE_SHA256,
    load_profile,
    profile_metadata,
    profile_parser,
)


ROOT = Path(__file__).resolve().parents[2]
HISTORICAL = ROOT / "05_audit" / "current" / "27" / "step12d_engineering"
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def main() -> int:
    parser = profile_parser("Validate a SAT10 engineering profile")
    parser.add_argument("--emit", action="store_true")
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    profile = load_profile(args.profile)
    if profile["profile_name"] != SAT10_PROFILE_NAME:
        raise AssertionError(f"checkpoint requires frozen profile {SAT10_PROFILE_NAME}")
    if profile["final10"]["default"] != "SAT10":
        raise AssertionError("this validator only accepts a SAT10 profile")
    if profile["_sha256"] != SAT10_PROFILE_SHA256:
        raise AssertionError("SAT10 profile identity does not match the frozen checkpoint")
    old = json.loads((HISTORICAL / "ENGINEERING_PROFILE.json").read_text(encoding="utf-8"))
    for key in ("algorithm_binding", "vtm_reference_build", "inverse_2d", "lfnst"):
        if profile[key] != old[key]:
            raise AssertionError(f"SAT10 profile changed frozen arithmetic binding: {key}")
    if profile["final10"]["range"] != [-512, 511]:
        raise AssertionError("SAT10 range must be [-512, 511]")
    result = {
        "schema": "step12d_engineering.sat10_profile_validation.v1",
        "status": "PASS_SAT10_PROFILE_INHERITS_V1_ARITHMETIC",
        **profile_metadata(profile),
        "historical_profile": old["profile_name"],
        "tested_profile_sha256": profile["_sha256"],
        "historical_profile_sha256": sha256(HISTORICAL / "ENGINEERING_PROFILE.json"),
        "canonical_sha256": sha256(CANONICAL),
        "arithmetic_inheritance": "PASS",
        "final10": profile["final10"],
        "official_equivalence": "NOT_PROVEN",
        "historical_hidden_golden_equivalence": "UNKNOWN",
        "historical_low10_evidence_mutated": False,
    }
    output = args.evidence_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    text = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.emit:
        print(text, end="")
    else:
        (output / "SAT10_PROFILE_VALIDATION.json").write_text(text, encoding="utf-8")
        print(json.dumps({"status": result["status"], "profile": profile["profile_name"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

