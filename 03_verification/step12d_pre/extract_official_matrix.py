"""Mechanically extract the Huawei attachment transform-size rows.

The script is read-only and intentionally reports the it_info width conflict
instead of silently normalizing it.
"""

from __future__ import annotations

import json
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
DOCX = ROOT / "04_reference" / "huawei" / "华为附件.docx"
W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"


def cell_text(cell: ET.Element) -> str:
    return "".join(node.text or "" for node in cell.iter(W + "t")).strip()


def tables() -> list[list[list[str]]]:
    with zipfile.ZipFile(DOCX) as zf:
        root = ET.fromstring(zf.read("word/document.xml"))
    result = []
    for table in root.iter(W + "tbl"):
        rows = []
        for row in table.findall(W + "tr"):
            rows.append([cell_text(cell) for cell in row.findall(W + "tc")])
        result.append(rows)
    return result


def main() -> int:
    rows = [row for table in tables() for row in table]
    wanted = {row[0]: row[1] for row in rows if row and row[0] in {"DCT2", "DCT8", "DST7", "LFNST"}}
    assert "DCT2" in wanted and "DCT8" in wanted and "DST7" in wanted
    assert "4x64" in wanted["DCT2"] and "64x64" in wanted["DCT2"]
    assert "4x64" not in wanted["DCT8"] and "4x64" not in wanted["DST7"]
    lfnst_rows = [row for row in rows if row and any("nTrs =" in cell for cell in row)]
    assert len(lfnst_rows) == 2
    return_data = {
        "status": "PASS_OFFICIAL_TABLE_EXTRACTION",
        "docx": str(DOCX),
        "shape_row_counts": {
            "DCT2": len(wanted["DCT2"].split("、")),
            "DCT8": len(wanted["DCT8"].split("、")),
            "DST7": len(wanted["DST7"].split("、")),
        },
        "lfnst_rows": [row[1] for row in lfnst_rows],
        "it_info_width_note": "The attachment table says 20 while the described fields reach [21:20]; repository contract remains 22.",
    }
    print(json.dumps(return_data, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
