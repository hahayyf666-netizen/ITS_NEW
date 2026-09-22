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
    profile["_sha256"] = hashlib.sha256(candidate.read_bytes()).hexdigest().upper()
    return profile


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

