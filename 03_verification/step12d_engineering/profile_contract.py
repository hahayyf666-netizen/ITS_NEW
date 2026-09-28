"""Fail-closed profile selection for the engineering verification tools.

The profile name is part of every generated vector/evidence contract.  Do not
replace this with an independent ``--adapter`` switch: a free-standing mode
flag can silently make the RTL, Oracle and manifest disagree.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
# ``HERE`` is the step12d_engineering directory; its second parent is the
# repository root (the first is 03_verification).  Keep generated evidence
# paths repository-relative even when this code runs from a linked worktree.
REPO_ROOT = HERE.parents[1]
PROFILE_DIR = HERE / "profiles"
DEFAULT_PROFILE = "contest_engineering_vtm10_sat10_v2"
SAT10_PROFILE_NAME = "contest_engineering_vtm10_sat10_v2"
# SHA-256 over the frozen profile bytes after canonicalizing CRLF to LF.
# This remains stable across Windows and Unix checkouts while still pinning
# the exact committed JSON identity.
SAT10_PROFILE_SHA256 = "FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746"


def profile_parser(description: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--profile",
        default=DEFAULT_PROFILE,
        help="profile name in step12d_engineering/profiles (or a JSON path)",
    )
    return parser


def load_profile(name_or_path: str | None = None) -> dict[str, Any]:
    selected = name_or_path or DEFAULT_PROFILE
    candidate = Path(selected)
    if not candidate.suffix:
        candidate = PROFILE_DIR / f"{selected}.json"
    if not candidate.is_absolute():
        candidate = (HERE / candidate).resolve()
    if not candidate.is_file():
        raise FileNotFoundError(f"engineering profile not found: {selected}")
    profile = json.loads(candidate.read_text(encoding="utf-8"))
    if profile.get("schema") != "step12d_engineering.vtm_profile.v2":
        raise ValueError(f"unsupported/non-versioned engineering profile: {candidate}")
    final10 = profile.get("final10", {})
    default = final10.get("default")
    if default not in {"LOW10_TWOS_COMPLEMENT", "SAT10"}:
        raise ValueError(f"invalid final10.default in {candidate}: {default}")
    if default == "SAT10" and final10.get("range") != [-512, 511]:
        raise ValueError("SAT10 profile must declare range [-512, 511]")
    profile["_path"] = candidate.relative_to(REPO_ROOT).as_posix()
    canonical_bytes = candidate.read_bytes().replace(b"\r\n", b"\n")
    profile["_sha256"] = hashlib.sha256(canonical_bytes).hexdigest().upper()
    frozen_sat10_path = (PROFILE_DIR / f"{SAT10_PROFILE_NAME}.json").resolve()
    if profile.get("profile_name") == SAT10_PROFILE_NAME or candidate.resolve() == frozen_sat10_path:
        validate_sat10_release_profile(profile)
    return profile


def validate_sat10_release_profile(profile: dict[str, Any]) -> None:
    """Fail closed unless this is the exact frozen SAT10 release profile."""
    if profile.get("profile_name") != SAT10_PROFILE_NAME:
        raise ValueError(f"SAT10 release requires profile {SAT10_PROFILE_NAME}")
    if profile.get("_path") != f"03_verification/step12d_engineering/profiles/{SAT10_PROFILE_NAME}.json":
        raise ValueError("SAT10 release profile must be loaded from the frozen repository profile path")
    final10 = profile.get("final10", {})
    if final10.get("default") != "SAT10" or final10.get("range") != [-512, 511]:
        raise ValueError("SAT10 release profile must select SAT10 range [-512, 511]")
    if profile.get("decision_class") != "PROVISIONAL_ENGINEERING_DECISION":
        raise ValueError("SAT10 release profile decision class changed")
    if profile.get("official_equivalence") != "NOT_PROVEN":
        raise ValueError("SAT10 official equivalence must remain NOT_PROVEN")
    if profile.get("_sha256") != SAT10_PROFILE_SHA256:
        raise ValueError(
            "SAT10 profile identity hash mismatch: "
            f"expected {SAT10_PROFILE_SHA256}, got {profile.get('_sha256')}"
        )


def adapter_mode(profile: dict[str, Any]) -> str:
    default = profile["final10"]["default"]
    return "SAT10" if default == "SAT10" else "LOW10"


def profile_metadata(profile: dict[str, Any]) -> dict[str, Any]:
    return {
        "profile_name": profile["profile_name"],
        "adapter_default": profile["final10"]["default"],
        "decision_class": profile.get("decision_class", "UNSPECIFIED"),
        "official_equivalence": profile.get("official_equivalence"),
        "profile_path": profile["_path"],
        "profile_sha256": profile["_sha256"],
    }

