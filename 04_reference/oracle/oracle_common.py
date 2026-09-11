"""Shared read-only data loader for the independent P1-A oracles.

This module only loads the frozen V3.4 canonical matrix data.  It does not
import the V3.4 reference model, RTL, test vectors, or golden files.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any, List


# The oracle is vendored into the frozen repository. Resolve the canonical
# file from this checkout so a clean clone is self-contained; never fall back
# to a historical ITS_STUDY tree or an environment-selected path.
BASELINE_ROOT = Path(__file__).resolve().parents[2]
CANONICAL_PATH = BASELINE_ROOT / "03_verification" / "output" / "canonical_matrices.json"


@lru_cache(maxsize=1)
def load_canonical() -> dict[str, Any]:
    with CANONICAL_PATH.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def transform_matrix(data: dict[str, Any], tr_type: int, n: int) -> List[List[int]]:
    """Return the frozen inverse operator A directly; never transpose here."""
    return data["transforms"][str(tr_type)]["inverse_operator"][str(n)]


def source_kernel(data: dict[str, Any], tr_type: int, n: int) -> List[List[int]]:
    return data["transforms"][str(tr_type)]["source_kernel"][str(n)]


def lfnst_matrix(data: dict[str, Any], ntrs: int, set_idx: int, lfnst_idx: int) -> List[List[int]]:
    return data["lfnst"][str(ntrs)][str(set_idx)][str(lfnst_idx)]


def clip3(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))
