"""Fail-closed structural audit for the R4A operand/coefficient repair."""
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP = ROOT / "03_verification" / "output" / "r4_lane_source_map.json"
RTL = ROOT / "02_rtl" / "rtl" / "p2f_dct2_64_b1_step102.sv"
TABLE = ROOT / "02_rtl" / "rtl" / "p2f_r4a_local_tables.svh"
OUT = ROOT / "03_verification" / "output" / "r4a_structure_audit.json"


def table_rows(text: str, name: str) -> list[list[int]]:
    pat = (r"localparam integer " + re.escape(name) +
           r"\s*\[0:127\]\[0:[0-9]+\]\s*=\s*'\{(.*?)\n\};")
    m = re.search(pat, text, re.S)
    if not m:
        raise AssertionError(f"missing table {name}")
    rows = re.findall(r"'\{([^}]*)\}", m.group(1))
    return [[int(x.strip()) for x in row.split(",")] for row in rows]


def expected_tables() -> dict[str, list[list[int]]]:
    data = json.loads(MAP.read_text(encoding="utf-8"))
    out = {k: [] for k in ("SRC_ID", "SRC_SEL", "COEFF", "VALID", "OP_ID")}
    for lane in range(128):
        records = data[str(lane)]["records"]
        sources: list[int] = []
        by_phase = {int(r["issue_cycle"]): r for r in records}
        for r in records:
            s = int(r["source_x_index"])
            if s not in sources:
                sources.append(s)
        out["SRC_ID"].append(sources + [sources[-1]] * (3 - len(sources)))
        rows = {k: [] for k in ("SRC_SEL", "COEFF", "VALID", "OP_ID")}
        for phase in range(16):
            r = by_phase.get(phase)
            if r is None:
                rows["SRC_SEL"].append(0)
                rows["COEFF"].append(0)
                rows["VALID"].append(0)
                rows["OP_ID"].append(-1)
            else:
                rows["SRC_SEL"].append(sources.index(int(r["source_x_index"])))
                rows["COEFF"].append(int(r["coefficient"]))
                rows["VALID"].append(1)
                rows["OP_ID"].append(int(r["op_id"]))
        for k in rows:
            out[k].append(rows[k])
    return out


def audit_text(rtl_text: str, table_text: str, expected: dict[str, list[list[int]]]) -> dict:
    if "`include \"p2f_r4a_local_tables.svh\"" not in rtl_text:
        raise AssertionError("R4A local table include is missing")
    if re.search(r"\breg\s+signed\s+\[15:0\]\s+vector_buf_[ab]\s*\[", rtl_text):
        raise AssertionError("legacy global vector buffer declaration remains")
    if re.search(r"vector_buf_[ab]\s*\[\s*sched_src", rtl_text):
        raise AssertionError("dynamic sched_src vector indexing remains")
    if "r4a_vector_buf_a" not in rtl_text or "r4a_vector_buf_b" not in rtl_text:
        raise AssertionError("cluster-local vector buffers are missing")
    if rtl_text.count("r4a_vector_buf_a[c][i] <=") < 2 or rtl_text.count("r4a_vector_buf_b[c][i] <=") < 2:
        raise AssertionError("vector reset/load is not expressed as cluster-local loops")
    if "r4a_vector_buf_a[c][i] <= $signed(vector_data_flat" not in rtl_text or "r4a_vector_buf_b[c][i] <= $signed(vector_data_flat" not in rtl_text:
        raise AssertionError("vector load does not replicate input into every cluster")
    if rtl_text.count("for (c = 0; c < R4A_CLUSTER_COUNT; c = c + 1)") < 3:
        raise AssertionError("cluster replication/reset/load is incomplete")
    if "p2f_lane_op(issue_cycle * LANES + l)" in rtl_text:
        raise AssertionError("old global schedule decoder remains on active D0 path")

    actual = {k: table_rows(table_text, "R4A_" + k) for k in expected}
    for k in expected:
        if actual[k] != expected[k]:
            raise AssertionError(f"R4A_{k} table differs from authoritative source map")
    valid_ops = sum(v for row in actual["VALID"] for v in row)
    if valid_ops != 1368:
        raise AssertionError(f"valid operation count {valid_ops}, expected 1368")
    if any(len(set(row)) > 3 for row in actual["SRC_ID"]):
        raise AssertionError("lane source choice count exceeds 3")
    return {
        "status": "PASS",
        "operation_count": valid_ops,
        "lanes": 128,
        "clusters": 4,
        "lanes_per_cluster": 32,
        "max_source_choices": max(len(set(row)) for row in actual["SRC_ID"]),
        "dynamic_global_source_index": False,
        "table_matches_authoritative_map": True,
    }


def main() -> None:
    expected = expected_tables()
    rtl_text = RTL.read_text(encoding="utf-8")
    table_text = TABLE.read_text(encoding="utf-8")
    result = audit_text(rtl_text, table_text, expected)
    # Fail-closed negative self-test: corrupt one generated source entry and
    # require the same checker to reject it.
    bad = table_text.replace("'{0, 2, 1}", "'{0, 2, 2}", 1)
    try:
        audit_text(rtl_text, bad, expected)
    except AssertionError:
        result["negative_self_test"] = "PASS"
    else:
        raise AssertionError("negative self-test was not rejected")
    OUT.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print("R4A_STRUCTURE_PASS", json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
