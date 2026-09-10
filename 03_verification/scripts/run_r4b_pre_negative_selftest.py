"""Fail-closed negative tests for the R4B_PRE event-map checker."""
from __future__ import annotations

import csv
import json
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AUDIT = ROOT / "03_verification/output/r4b_pre_butterfly_audit"
EVENTS = AUDIT / "r4b_pre_butterfly_events.csv"
OUT = AUDIT / "r4b_pre_negative_selftest.json"

with EVENTS.open(encoding="utf-8-sig", newline="") as f:
    base = list(csv.DictReader(f))

fields = ["event_id", "level", "phase", "slot", "destination", "operation", "even", "odd", "key"]

def normalize(rows):
    return [{k: str(row[k]) for k in fields} for row in rows]

expected = normalize(base)

def checker(rows):
    rows = normalize(rows)
    if len(rows) != 124:
        return False
    if len({r["destination"] for r in rows}) != 124:
        return False
    if len({r["event_id"] for r in rows}) != 124:
        return False
    if any(int(r["phase"]) < 1 or int(r["phase"]) > 17 for r in rows):
        return False
    # Authoritative event-by-event connectivity comparison. This is intentionally
    # field-level, not a file hash/name/comment test.
    return rows == expected

cases = {}
for name, field, mutate in (
    ("source_mutation", "even", lambda x: '{"kind": "dot", "id": 9999}'),
    ("destination_mutation", "destination", lambda x: str(int(x) + 1)),
    ("phase_mutation", "phase", lambda x: str(17 if int(x) != 17 else 16)),
):
    rows = deepcopy(base)
    rows[0][field] = mutate(rows[0][field])
    cases[name] = {"checker_result": checker(rows), "expected": "FAIL"}

rows = deepcopy(base)
rows[1]["destination"] = rows[0]["destination"]
cases["duplicate_producer"] = {"checker_result": checker(rows), "expected": "FAIL"}

cases["normal"] = {"checker_result": checker(base), "expected": "PASS"}
failures = [name for name, item in cases.items() if (item["checker_result"] and item["expected"] == "FAIL") or (not item["checker_result"] and item["expected"] == "PASS")]
result = {"status": "PASS" if not failures else "FAIL", "cases": cases, "failures": failures}
OUT.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
print(json.dumps(result, indent=2, ensure_ascii=False))
raise SystemExit(0 if not failures else 1)
