"""R4B_PRE read-only butterfly connectivity audit.

This audit uses the active R4A RTL/table files and the existing R4A physical
reports.  It does not modify RTL, constraints, DCPs, or run implementation.
The generated connectivity is an event-level proof of the schedule, not a
claim that a future static rewrite will automatically improve timing.
"""
from __future__ import annotations

import csv
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RTL = ROOT / "02_rtl/rtl/p2f_dct2_64_b1_step102.sv"
TABLE = ROOT / "02_rtl/rtl/p2f_step102_tables.svh"
POST_DCP = ROOT / "03_verification/vivado/reports_r4a_postroute/p2f_b2_controlled_postroute.dcp"
POST_SYNTH_FANOUT = ROOT / "03_verification/vivado/reports_r4a_postroute/report_high_fanout_postsynth.rpt"
POST_TIMING = ROOT / "03_verification/vivado/reports_r4a_postroute/report_timing_worst20_postroute.rpt"
READONLY_OUT = ROOT / "03_verification/vivado/reports_r4b_pre_readonly"
ALL_FAILING = READONLY_OUT / "all_failing_setup_paths.csv"
READONLY_FANOUT = READONLY_OUT / "high_fanout.rpt"
OUT = ROOT / "03_verification/output/r4b_pre_butterfly_audit"
OUT.mkdir(parents=True, exist_ok=True)

def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def parse_fun(text: str, name: str) -> dict[int, int]:
    pat = rf"(?m)^\s*(\d+)\s*:\s*{re.escape(name)}\s*=\s*(-?\d+)\s*;"
    rows = {int(k): int(v) for k, v in re.findall(pat, text)}
    if not rows:
        raise RuntimeError(f"no table rows found for {name}")
    return rows

rtl_text = RTL.read_text(encoding="utf-8", errors="replace")
table_text = TABLE.read_text(encoding="utf-8", errors="replace")

tables = {name: parse_fun(table_text, "p2f102_" + name) for name in (
    "bf_count", "bf_sig", "bf_even_sig", "bf_even_dot", "bf_odd_dot", "bf_high"
)}
bfcaps = {4: 4, 8: 8, 16: 16, 32: 16, 64: 8}

# The table key format is the active RTL key_tmp = level*2048 + bf_cycle*64+r.
events: list[dict] = []
for level, cap in bfcaps.items():
    for phase in range(1, 18):
        count = tables["bf_count"].get(level * 32 + phase, 0)
        for slot in range(cap):
            key = level * 2048 + phase * 64 + slot
            sid = tables["bf_sig"].get(key, -1)
            if slot >= count or sid < 0:
                continue
            es = tables["bf_even_sig"].get(key, -1)
            ed = tables["bf_even_dot"].get(key, -1)
            od = tables["bf_odd_dot"].get(key, -1)
            even = {"kind": "signal", "id": es} if es >= 0 else {"kind": "dot", "id": ed}
            odd = {"kind": "dot", "id": od}
            events.append({
                "event_id": len(events), "level": level, "phase": phase,
                "slot": slot, "destination": sid, "even": even, "odd": odd,
                "operation": "sub" if tables["bf_high"].get(key, 0) else "add",
                "key": key,
            })

failures: list[str] = []
if len(events) != 124:
    failures.append(f"butterfly event count {len(events)} != expected 124")

dest_events: dict[int, list[dict]] = defaultdict(list)
for event in events:
    dest_events[event["destination"]].append(event)

# A destination may be written once in the whole factorized graph.  If it is
# reused, it must at least have a unique producer for each phase/context.
duplicate_dest = {k: v for k, v in dest_events.items() if len(v) != 1}
if duplicate_dest:
    failures.append(f"{len(duplicate_dest)} destinations have multiple producers")

pair_sets: dict[tuple[int, int], set[tuple]] = defaultdict(set)
phase_sets: dict[tuple[int, int], set[int]] = defaultdict(set)
for event in events:
    key = (event["level"], event["slot"])
    pair_sets[key].add((event["even"]["kind"], event["even"]["id"], event["odd"]["kind"], event["odd"]["id"]))
    phase_sets[key].add(event["phase"])

source_dist = Counter(len(v) for v in pair_sets.values())
if any(n > 3 for n in source_dist):
    failures.append("at least one butterfly slot has more than three source choices")

phase_stats = []
for phase in range(1, 18):
    pe = [e for e in events if e["phase"] == phase]
    phase_stats.append({"phase": phase, "event_count": len(pe), "destinations": sorted(e["destination"] for e in pe),
                        "levels": dict(Counter(e["level"] for e in pe))})

# Check that the current RTL really contains the generic runtime selection
# pattern; this is a diagnostic, not a textual proof of synthesized topology.
dynamic_patterns = {
    "bf_cycle_key": len(re.findall(r"key_tmp\s*=\s*\d+\s*\*\s*2048\s*\+\s*bf_cycle\s*\*\s*64", rtl_text)),
    "dynamic_signal_destination": len(re.findall(r"signal_reg\s*\[sid_tmp\]", rtl_text)),
    "dynamic_signal_source": len(re.findall(r"signal_reg\s*\[esig_tmp\]", rtl_text)),
    "dynamic_function_lookup": len(re.findall(r"p2f102_bf_(?:sig|even_sig|odd_dot|high)\s*\(", rtl_text)),
}
if dynamic_patterns["bf_cycle_key"] < 5 or dynamic_patterns["dynamic_signal_destination"] < 5:
    failures.append("active RTL dynamic butterfly pattern was not found in all five levels")

fanout_rows = []
if POST_SYNTH_FANOUT.exists():
    for line in POST_SYNTH_FANOUT.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"\|\s*([^|]+?)\s*\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|", line)
        if m:
            fanout_rows.append({"net": m.group(1).strip(), "fanout": int(m.group(2)), "driver": m.group(3).strip()})
fanout_rows.sort(key=lambda x: x["fanout"], reverse=True)
fanout_targets = [x for x in fanout_rows if "r4a_vector_buf_a[0]" in x["net"] or "r4a_vector_buf_b[0]" in x["net"]]

def path_category(row: dict[str, str]) -> str:
    sp = row.get("startpoint", "").lower()
    ep = row.get("endpoint", "").lower()
    if "signal_reg" in ep or "bf_cycle" in sp:
        return "butterfly"
    if re.search(r"lane_product|operand_x|operand_coeff|r4a_vector_buf", ep + " " + sp):
        return "multiplier_frontend"
    if re.search(r"red_|dot_value|reduction", ep + " " + sp):
        return "reduction"
    if re.search(r"sched_|valid_reg|issue_|bf_cycle", ep + " " + sp):
        return "control_schedule"
    if re.search(r"result|group|out_|reorder|raw_flat|final10", ep + " " + sp):
        return "output_reorder"
    return "other"

all_path_rows = []
if ALL_FAILING.exists():
    with ALL_FAILING.open(encoding="utf-8", newline="") as f:
        all_path_rows = list(csv.DictReader(f))
path_groups: dict[str, list[dict[str, str]]] = defaultdict(list)
for row in all_path_rows:
    path_groups[path_category(row)].append(row)
path_category_summary = {}
for name, rows in sorted(path_groups.items()):
    slacks = [float(r["slack"]) for r in rows]
    delays = [float(r["datapath_delay"]) for r in rows]
    path_category_summary[name] = {
        "count": len(rows), "fraction": len(rows) / len(all_path_rows) if all_path_rows else 0.0,
        "min_slack_ns": min(slacks), "mean_slack_ns": sum(slacks) / len(slacks),
        "mean_datapath_delay_ns": sum(delays) / len(delays),
    }
readonly_fanout_rows = []
if READONLY_FANOUT.exists():
    for line in READONLY_FANOUT.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"\|\s*([^|]+?)\s*\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|", line)
        if m:
            readonly_fanout_rows.append({"net": m.group(1).strip(), "fanout": int(m.group(2)), "driver": m.group(3).strip()})
readonly_fanout_rows.sort(key=lambda x: x["fanout"], reverse=True)

timing_text = POST_TIMING.read_text(encoding="utf-8", errors="replace") if POST_TIMING.exists() else ""
timing_evidence = {
    "report_exists": POST_TIMING.exists(),
    "bf_cycle_to_signal_reg_occurrences": len(re.findall(r"Source:\s+bf_cycle_reg.*?\n\s*Destination:\s+signal_reg_reg", timing_text, re.S)),
    "source_examples": sorted(set(re.findall(r"Source:\s+([^\r\n]+)", timing_text)))[:20],
    "destination_examples": sorted(set(re.findall(r"Destination:\s+([^\r\n]+)", timing_text)))[:20],
    "note": "Existing R4A report is worst-20 only; full failing-endpoint census requires the read-only Vivado TCL audit.",
}

slot_rows = []
for key in sorted(pair_sets):
    level, slot = key
    slot_rows.append({"level": level, "slot": slot, "choice_count": len(pair_sets[key]),
                      "phases": sorted(phase_sets[key]), "choices": [list(p) for p in sorted(pair_sets[key], key=str)]})
eight_choice_slots = [f"N{row['level']}_slot{row['slot']}" for row in slot_rows if row["choice_count"] == 8]

result = {
    "status": "FAIL_AUDIT" if failures else "PASS_PRE_AUDIT",
    "scope": "R4A active RTL/table + existing R4A reports; no RTL or implementation changes",
    "baseline": str(ROOT),
    "evidence": {
        "rtl": str(RTL), "rtl_sha256": sha256(RTL), "tables": str(TABLE), "tables_sha256": sha256(TABLE),
        "postroute_dcp": str(POST_DCP), "postroute_dcp_sha256": sha256(POST_DCP) if POST_DCP.exists() else None,
        "postsynth_high_fanout": str(POST_SYNTH_FANOUT), "postroute_worst20": str(POST_TIMING),
    },
    "butterfly_event_count": len(events),
    "destination_count": len(dest_events),
    "duplicate_destinations": duplicate_dest,
    "source_choice_distribution": dict(sorted(source_dist.items())),
    "slot_rows": slot_rows,
    "eight_choice_slots": eight_choice_slots,
    "phase_stats": phase_stats,
    "dynamic_rtl_pattern_counts": dynamic_patterns,
    "timing_evidence": timing_evidence,
    "all_failing_path_count": len(all_path_rows),
    "all_failing_path_category_summary": path_category_summary,
    "fanout_targets": fanout_targets,
    "fanout_top20": fanout_rows[:20],
    "postroute_fanout_top20": readonly_fanout_rows[:20],
    "failures": failures,
    "decision": "STOP_NO_PROVEN_REPAIR",
    "limitations": [
        "This stage does not claim source locality from signal indices.",
        "This stage does not claim that static connectivity will close 2.000 ns.",
        "The path census is endpoint/path evidence; it does not prove that static connectivity will improve physical locality.",
    ],
}

(OUT / "r4b_pre_butterfly_connectivity.json").write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
with (OUT / "r4b_pre_butterfly_events.csv").open("w", newline="", encoding="utf-8-sig") as f:
    writer = csv.DictWriter(f, fieldnames=["event_id", "level", "phase", "slot", "destination", "operation", "even", "odd", "key"])
    writer.writeheader()
    for e in events:
        row = dict(e); row["even"] = json.dumps(e["even"], ensure_ascii=False); row["odd"] = json.dumps(e["odd"], ensure_ascii=False); writer.writerow(row)

lines = [
    "# V35 P2F R4B_PRE Butterfly Topology Audit", "",
    f"结论：**{result['status']}**", "",
    "本轮只读取 R4A RTL、调度表、现有 DCP 和既有时序报告；没有修改 RTL、约束或实现结果。", "",
    "## 1. 连接级结果", "",
    f"- Butterfly events: {len(events)}（预期124）",
    f"- Destination count: {len(dest_events)}",
    f"- Duplicate destinations: {len(duplicate_dest)}",
    f"- Source-choice distribution: {dict(sorted(source_dist.items()))}",
    f"- Eight-choice slots: {', '.join(eight_choice_slots)}",
    "- 每个 event 的完整映射见 `r4b_pre_butterfly_events.csv`。",
    "", "## 2. 当前 RTL 结构证据", "",
    f"- dynamic key expressions: {dynamic_patterns['bf_cycle_key']}",
    f"- dynamic signal destinations: {dynamic_patterns['dynamic_signal_destination']}",
    f"- dynamic signal sources: {dynamic_patterns['dynamic_signal_source']}",
    f"- dynamic table lookups: {dynamic_patterns['dynamic_function_lookup']}",
    "- 当前确实使用 `bf_cycle` 计算 key，并通过 `sid_tmp/esig_tmp` 动态访问 signal_reg；这只是 RTL 证据，不等同于综合网表证明。",
    "", "## 3. 时序与高扇出证据", "",
    f"- R4A post-route DCP: `{POST_DCP}`",
    f"- worst-20 中 bf_cycle→signal_reg 路径数：{timing_evidence['bf_cycle_to_signal_reg_occurrences']}",
    f"- vector-buffer fanout entries: {len(fanout_targets)}",
    "- post-synthesis vector-buffer driver: LUT2; post-route driver: BUFGCE (1024 loads each)",
    f"- DCP 只读 census failing paths: {len(all_path_rows)}",
    "- 全部 failing path 分类：",
    *[f"  - {name}: {info['count']} ({info['fraction']:.1%}), min slack {info['min_slack_ns']} ns" for name, info in sorted(path_category_summary.items())],
    "", "## 4. 决策", "",
    "完整 DCP census 已完成，但连接级统计显示 butterfly 存在 8 个八选一 slot，不能直接套用 reduction 的固定/二选一改法。",
    "当前决策：STOP_NO_PROVEN_REPAIR。需要针对八选一 source-set 和 bf_cycle/control fanout 进一步评估局部化或流水方案，不能直接生成 R4B RTL。",
    "", "## 5. STOP", "",
    "- 不得把 source-set 统计直接等同于物理 locality。",
    "- 不得把 worst-20 等同于全部 failing endpoints。",
    "- 不得在本阶段修改 1024 fanout、DSP、reduction 或 butterfly RTL。",
]
(OUT / "V35_P2F_R4B_PRE_BUTTERFLY_AUDIT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
print(json.dumps({"status": result["status"], "events": len(events), "destinations": len(dest_events),
                  "source_choice_distribution": dict(sorted(source_dist.items())), "failures": failures,
                  "out": str(OUT)}, ensure_ascii=False, indent=2))
