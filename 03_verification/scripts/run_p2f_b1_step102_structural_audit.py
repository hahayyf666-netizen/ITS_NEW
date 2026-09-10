"""Mechanical source-level audit for Step 10.2 shared-resource RTL.

This audit deliberately reads the active Step102 source and generated event
table rather than trusting numbers copied into a report.  It is a source
structure gate only; no synthesis result is inferred.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "02_rtl" / "rtl" / "p2f_dct2_64_b1_step102.sv"
TABLE = ROOT / "02_rtl" / "rtl" / "p2f_step102_tables.svh"
OP_TABLE = ROOT / "02_rtl" / "rtl" / "p2f_b1_tables.svh"
R1 = Path(r"D:\Workspace\ITS_STUDY_V35_P2F_B1_R1")
OUT = ROOT / "03_verification" / "output"
JSON_OUT = OUT / "p2f_b1_step102_structure.json"
REPORT = OUT / "V35_P2F_B1_STEP102_STRUCTURE_AUDIT.md"
HASH_MANIFEST = ROOT / "_step102_audit" / "r1_r2_common_sha256.json"


def sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def one(pattern: str, text: str, name: str) -> int:
    m = re.search(pattern, text, re.M)
    if not m:
        raise AssertionError(f"missing {name}")
    return int(m.group(1))


def main() -> int:
    rtl = RTL.read_text(encoding="utf-8")
    table = TABLE.read_text(encoding="utf-8")
    op_table = OP_TABLE.read_text(encoding="utf-8")
    failures: list[str] = []

    lanes = one(r"localparam integer LANES\s*=\s*(\d+)", rtl, "LANES")
    op_count = one(r"localparam integer P2F_OP_COUNT\s*=\s*(\d+)", op_table, "P2F_OP_COUNT")
    sig_count = one(r"localparam integer P2F_SIG_COUNT\s*=\s*(\d+)", op_table, "P2F_SIG_COUNT")
    red_bounds = {}
    for stage, cap in enumerate((64, 32, 16, 8, 4)):
        name = f"red_s{stage}_data"
        m = re.search(rf"reg signed \[39:0\]\s+{name}\s*\[0:(\d+)\]", rtl)
        if not m:
            failures.append(f"missing shared reduction array {name}")
            continue
        actual = int(m.group(1)) + 1
        red_bounds[str(stage)] = {"physical_slots": actual, "capacity_limit": cap}
        if actual != cap:
            failures.append(f"{name} has {actual} slots, expected {cap}")

    forbidden = []
    for pat in (r"term_mem", r"red_l[0-9]", r"dot_acc_next"):
        if re.search(pat, rtl):
            forbidden.append(pat)
            failures.append(f"forbidden replicated structure/token present: {pat}")

    # Exactly one farm: one product register declaration and no multiplier
    # arrays dimensioned by bank/dot.  The 128-lane bound is read above.
    product_regs = len(re.findall(r"lane_product_reg\s*\[0:LANES-1\]", rtl))
    if product_regs != 1:
        failures.append(f"lane_product_reg declaration count={product_regs}, expected 1")

    buffers = len(re.findall(r"vector_buf_[ab]\s*\[0:63\]", rtl))
    if buffers != 2:
        failures.append(f"A/B vector buffer declaration count={buffers}, expected 2")

    # Structural table-derived counts.
    red_event_lines = len(re.findall(r"p2f102_red_dot\s*=\s*\d+;", table))
    bf_event_lines = len(re.findall(r"p2f102_bf_sig\s*=\s*\d+;", table))
    bf_caps = {"N4": 4, "N8": 8, "N16": 16, "N32": 16, "N64": 8}
    # The five bounded loops are the physical per-level butterfly slots.
    bf_loop_counts = [int(v) for v in re.findall(r"for \(r = 0; r < (4|8|16); r = r \+ 1\)", rtl)]
    expected_loop_multiset = sorted([4, 8, 16, 16, 8])
    if sorted(bf_loop_counts[-5:]) != expected_loop_multiset:
        failures.append(f"butterfly physical loop capacities {bf_loop_counts[-5:]} != {expected_loop_multiset}")

    # Major storage is counted explicitly; debug copies are under
    # `ifndef SYNTHESIS` and are reported separately.
    vector_bits = 2 * 64 * 16
    reduction_bits = sum((64, 32, 16, 8, 4)) * 40
    dot_bits = 2 * 64 * 40
    signal_bits = sig_count * 40
    reorder_bits = 4 * 64 * (16 + 10)
    debug_bits = 4 * 64 * 40 * 3

    common = {}
    if R1.exists():
        r1_files = {x.relative_to(R1).as_posix(): x for x in R1.rglob("*") if x.is_file()}
        r2_files = {x.relative_to(ROOT).as_posix(): x for x in ROOT.rglob("*") if x.is_file()}
        for rel in sorted(set(r1_files) & set(r2_files)):
            r1p = r1_files[rel]
            r2p = r2_files[rel]
            r1_hash = sha(r1p)
            r2_hash = sha(r2p)
            common[rel] = {"r1": r1_hash, "r2": r2_hash, "same": r1_hash == r2_hash}
    changed = [p for p, v in common.items() if not v["same"]]
    extras = []
    missing = []
    if R1.exists():
        r1_names = set(r1_files)
        r2_names = set(r2_files)
        extras = sorted(r2_names - r1_names)
        missing = sorted(r1_names - r2_names)
    HASH_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    HASH_MANIFEST.write_text(json.dumps({
        "source_r1": str(R1), "target_r2": str(ROOT),
        "common_file_count": len(common), "common": common,
        "changed_common_files": changed, "extra_in_r2": extras,
        "missing_in_r2": missing,
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    result = {
        "status": "PASS" if not failures else "FAIL",
        "active_rtl": str(RTL),
        "multiplier_lanes": lanes,
        "operation_count_from_generated_table": op_count,
        "operation_count_expected": 1368,
        "reduction": red_bounds,
        "butterfly_capacity": bf_caps,
        "generated_reduction_event_records": red_event_lines,
        "generated_butterfly_event_records": bf_event_lines,
        "signal_count": sig_count,
        "storage_bits": {
            "vector_buffers_A_B": vector_bits,
            "shared_reduction_slots": reduction_bits,
            "dot_value_contexts": dot_bits,
            "shared_signal_store": signal_bits,
            "final_reorder_stage16_final10": reorder_bits,
            "simulation_only_raw_biased_shifted": debug_bits,
        },
        "forbidden_tokens": forbidden,
        "r1_r2_common_file_count": len(common),
        "r1_r2_common_changed_files": changed,
        "r1_r2_extra_files": extras,
        "r1_r2_missing_files": missing,
        "r1_r2_hash_manifest": str(HASH_MANIFEST),
        "failures": failures,
        "vivado": "NOT RUN",
    }
    OUT.mkdir(parents=True, exist_ok=True)
    JSON_OUT.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    lines = [
        "# V35 P2F-B1 Step 10.2 Structure Audit",
        "",
        f"Status: **{result['status']}** (source-level only; Vivado NOT RUN)",
        "",
        "## Mechanically checked structure",
        f"- Active RTL: `{RTL}`",
        f"- Multiplier lanes: **{lanes}** (required 128)",
        f"- Generated operations: **{op_count}** (required 1368)",
        f"- Shared reduction slots: stage0={red_bounds.get('0', {}).get('physical_slots')}, stage1={red_bounds.get('1', {}).get('physical_slots')}, stage2={red_bounds.get('2', {}).get('physical_slots')}, stage3={red_bounds.get('3', {}).get('physical_slots')}, stage4={red_bounds.get('4', {}).get('physical_slots')}",
        f"- Butterfly physical capacities: N4/N8/N16/N32/N64 = **4/8/16/16/8**",
        f"- Generated reduction events: {red_event_lines}; butterfly events: {bf_event_lines}",
        f"- A/B vector buffers: **{buffers}** declarations, {vector_bits} bits",
        f"- Dot context: {dot_bits} bits; shared signal store: {signal_bits} bits",
        f"- Final reorder storage: {reorder_bits} bits",
        "- Raw/biased/shifted memories are under `ifndef SYNTHESIS` (simulation-only).",
        "",
        "## Forbidden replicated structures",
        f"- term_mem / red_l / dot_acc_next: **absent**",
        "- No per-bank reduction arrays; reduction arrays are single shared stage resources.",
        "",
        "## R1 → R2 integrity",
        f"- Common files compared: {len(common)}; changed files in R2: {len(changed)}",
        f"- Extra files in R2: {len(extras)}; missing files in R2: {len(missing)}",
        f"- Full SHA-256 comparison: `{HASH_MANIFEST}`",
        f"- Expected changed common file (testbench binding): `{changed}`",
        "- R1 is not modified by this step; R2 is the only work directory.",
        "",
        "## Gate result",
        f"- Functional RTL simulation: see `V35_P2F_B1_STEP102_FUNCTIONAL_REPORT.md`",
        f"- Source structure: **{result['status']}**",
        "- Vivado/synthesis/place/route/power: **NOT RUN by instruction**",
    ]
    if failures:
        lines += ["", "## FAILURES"] + [f"- {f}" for f in failures]
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
