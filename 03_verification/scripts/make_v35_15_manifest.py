"""Create the V3.5-15 reproducible non-cache SHA-256 manifest."""
from __future__ import annotations
import hashlib, json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "05_audit" / "current" / "15"
MANIFEST = OUT / "V35_15_FREEZE_MANIFEST.json"
SKIP = {".Xil", "modelsim", "work", "tclstore_run10", "tclstore_run13",
        "tclstore_clean", "tclstore_diag", "tclstore_hold_report", "__pycache__"}

def sha(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    files = {}
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        rel = p.relative_to(ROOT).as_posix()
        if any(part in SKIP for part in p.relative_to(ROOT).parts):
            continue
        if rel.startswith("05_audit/current/15/"):
            continue
        files[rel] = {"bytes": p.stat().st_size, "sha256": sha(p)}
    doc = {"step": "V3.5-15", "root_policy": "workspace-relative",
           "cache_policy": "excluded",
           "file_count": len(files), "files": dict(sorted(files.items()))}
    MANIFEST.write_text(json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"V3.5-15 manifest: {len(files)} files")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
