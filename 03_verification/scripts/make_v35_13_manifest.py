"""Create the V3.5-13 post-reorganization SHA-256 manifest."""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "05_audit" / "current" / "v35_13"
OUT_FILE = OUT_DIR / "V35_13_FREEZE_MANIFEST.json"
SKIP_PARTS = {".git", ".Xil", "__pycache__", "modelsim_work"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    files: dict[str, dict[str, int | str]] = {}
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if any(part in SKIP_PARTS for part in rel.parts):
            continue
        if path == OUT_FILE:
            continue
        files[rel.as_posix()] = {"sha256": sha256(path), "size": path.stat().st_size}
    payload = {
        "version": "V3.5-13",
        "purpose": "complete project snapshot after category-based directory reorganization",
        "source_baseline": "ITS_STUDY_V35_STEP12A_R2_1_DCT2_64_2D_PRE",
        "historical_git_tag": "v3.5-step12ar2.1-full",
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "file_count": len(files),
        "excluded_parts": sorted(SKIP_PARTS),
        "files": files,
    }
    OUT_FILE.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"V35_13_MANIFEST_PASS files={len(files)} output={OUT_FILE}")


if __name__ == "__main__":
    main()
