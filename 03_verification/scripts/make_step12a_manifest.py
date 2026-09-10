"""Create a reproducible Step 12A integrity manifest.

The copied R4C project remains the functional baseline.  This manifest records
the complete copy's controlled source/evidence files plus the exact Step 12A
additions.  Large tool caches and simulator work directories are excluded.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(r"D:\Workspace\ITS_STUDY_V35_P2F_B2_R4C_DSP_PIPE")
OUT = ROOT / "_step12a_audit"
MANIFEST = OUT / "STEP12A_FREEZE_MANIFEST.json"
COPY_COMPARE = OUT / "r4c_copy_integrity.json"

EXTENSIONS = {".v", ".sv", ".vh", ".svh", ".py", ".tcl", ".xdc", ".hex",
              ".json", ".md", ".txt", ".do", ".sh", ".bat"}
SKIP_PARTS = {".Xil", "modelsim", "tclstore_run10", "tclstore_run13",
              "tclstore_clean", "tclstore_diag", "tclstore_hold_report"}


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def files(root: Path) -> dict[str, Path]:
    ans: dict[str, Path] = {}
    for p in root.rglob("*"):
        if not p.is_file() or p.suffix.lower() not in EXTENSIONS:
            continue
        rel = p.relative_to(root).as_posix()
        if any(part in SKIP_PARTS for part in p.relative_to(root).parts):
            continue
        # These are generated audit outputs.  Excluding them avoids a
        # self-referential hash for STEP12A_FREEZE_MANIFEST.json.
        if rel.startswith("_step12a_audit/"):
            continue
        ans[rel] = p
    return ans


def main() -> int:
    current = files(ROOT)
    baseline = files(SOURCE) if SOURCE.exists() else {}
    common = sorted(set(current) & set(baseline))
    same = [x for x in common if sha(current[x]) == sha(baseline[x])]
    different = [x for x in common if x not in set(same)]
    copy_result = {
        "source": str(SOURCE), "target": str(ROOT),
        "controlled_source_like_files": len(current),
        "common_with_r4c": len(common),
        "same_as_r4c": len(same),
        "different_from_r4c": different,
        "extra_in_step12a": sorted(set(current) - set(baseline)),
        "missing_from_step12a": sorted(set(baseline) - set(current)),
        "copy_integrity": not different and not (set(baseline) - set(current)),
    }
    OUT.mkdir(parents=True, exist_ok=True)
    COPY_COMPARE.write_text(json.dumps(copy_result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    controlled = {}
    for rel, p in sorted(current.items()):
        controlled[rel] = sha(p)
    result = {
        "format": "STEP12A_FREEZE_MANIFEST_V1",
        "version": "V3.5 Step 12A DCT2-64 2D Integration PRE",
        "created_from": str(SOURCE),
        "functional_baseline": "R4C standalone DCT2-64 P4 kernel",
        "r4c_dut_sha256": "15AA962C197C4CE0B9DAF2E5478B64C51F3C6712E582F8950DF6BF1C339C31B1",
        "step12a_scope": "64x64 DCT2 vertical -> stage16 memory -> DCT2 horizontal; LFNST OFF",
        "step12a_files": [
            "03_verification/scripts/step12a_2d_cycle_model.py",
            "03_verification/scripts/make_step12a_manifest.py",
            "03_verification/output/step12a_results.json",
            "03_verification/output/V35_STEP12A_2D_INTEGRATION_PRE.md",
            "_step12a_audit/r4c_copy_integrity.json",
            "_step12a_audit/STEP12A_FREEZE_MANIFEST.json",
        ],
        "excluded_tool_generated_parts": sorted(SKIP_PARTS),
        "controlled_file_count": len(controlled),
        "controlled_files_sha256": controlled,
        "copy_integrity": copy_result,
    }
    MANIFEST.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps({"manifest": str(MANIFEST), "controlled": len(controlled),
                      "copy_integrity": copy_result["copy_integrity"]}, ensure_ascii=False))
    return 0 if copy_result["copy_integrity"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
