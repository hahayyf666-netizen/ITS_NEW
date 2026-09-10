"""Summarize the read-only routed-DCP topology audit for P2F-B2-R3."""
from __future__ import annotations

import csv
import json
import re
from pathlib import Path

ROOT = Path(r"D:\Workspace\ITS_STUDY_V35_P2F_B2_R3")
AUDIT = ROOT / "03_verification" / "output" / "p2f_b2_r3_timing_topology"
OUT_JSON = ROOT / "03_verification" / "output" / "p2f_b2_r3_timing_topology.json"
OUT_MD = ROOT / "03_verification" / "output" / "V35_P2F_B2_R3_TIMING_TOPOLOGY_AUDIT.md"


def category(row: dict[str, str]) -> str:
    sp = row["startpoint"].lower()
    ep = row["endpoint"].lower()
    if "signal_reg" in ep or "bf_cycle" in sp:
        return "butterfly"
    if re.search(r"lane_product|operand_x|operand_coeff", ep):
        return "multiplier_frontend"
    if re.search(r"red_|dot_value|reduction", ep):
        return "reduction"
    if re.search(r"sched_|valid_reg|issue_|bf_cycle", ep):
        return "control_schedule"
    if re.search(r"result|group|out_|reorder|raw_flat", ep):
        return "output_reorder"
    return "other"


rows = list(csv.DictReader((AUDIT / "top1000_setup_paths.csv").open(encoding="utf-8")))
groups: dict[str, list[dict[str, str]]] = {}
for row in rows:
    groups.setdefault(category(row), []).append(row)

summary: dict[str, object] = {
    "status": "PASS_READ_ONLY_TOPOLOGY_AUDIT",
    "baseline": str(ROOT),
    "dcp": str(AUDIT.parent.parent / "vivado" / "reports_controlled_impl" / "p2f_b2_controlled_postroute.dcp"),
    "path_rows": len(rows),
    "categories": {},
    "evidence": {
        "timing_summary": str(AUDIT / "timing_summary.rpt"),
        "top1000": str(AUDIT / "top1000_setup_paths.rpt"),
        "top1000_csv": str(AUDIT / "top1000_setup_paths.csv"),
        "high_fanout": str(AUDIT / "high_fanout.rpt"),
        "route_status": str(AUDIT / "route_status.rpt"),
        "congestion": str(AUDIT / "congestion.rpt"),
        "hierarchical_utilization": str(AUDIT / "hierarchical_utilization.rpt"),
    },
}

for name, items in groups.items():
    slacks = [float(x["slack"]) for x in items if x["slack"]]
    summary["categories"][name] = {
        "count": len(items),
        "fraction": len(items) / len(rows) if rows else 0.0,
        "min_slack_ns": min(slacks) if slacks else None,
        "mean_slack_ns": sum(slacks) / len(slacks) if slacks else None,
    }

high_fanout_text = (AUDIT / "high_fanout.rpt").read_text(encoding="utf-8", errors="replace")
fanout_rows = []
for line in high_fanout_text.splitlines():
    m = re.match(r"\|\s*([^|]+?)\s*\|\s*(\d+)\s*\|\s*([^|]+?)\s*\|", line)
    if m and m.group(2).isdigit():
        fanout_rows.append({"net": m.group(1).strip(), "fanout": int(m.group(2)), "driver": m.group(3).strip()})
summary["high_fanout_top"] = sorted(fanout_rows, key=lambda x: x["fanout"], reverse=True)[:20]

OUT_JSON.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

cats = summary["categories"]
lines = [
    "# V35 P2F-B2-R3 Routed Timing Topology Audit",
    "",
    "本报告只读取 R3 post-route DCP 及其报告，不修改 RTL、约束或实现结果。",
    "",
    "## 1. 证据",
    f"- DCP: `{summary['dcp']}`",
    f"- setup path rows extracted: {len(rows)}",
    f"- top-path report: `{AUDIT / 'top1000_setup_paths.rpt'}`",
    f"- high-fanout report: `{AUDIT / 'high_fanout.rpt'}`",
    f"- congestion report: `{AUDIT / 'congestion.rpt'}`",
    "",
    "## 2. Top-1000 setup path classification",
    "分类依据是实际 startpoint/endpoint 名称，不使用变量注释、脚本 token 或文件哈希判断结构。",
    "",
    "| Category | Count | Fraction | Min slack (ns) | Mean slack (ns) |",
    "|---|---:|---:|---:|---:|",
]
for name in ["multiplier_frontend", "butterfly", "reduction", "control_schedule", "output_reorder", "other"]:
    x = cats.get(name, {"count": 0, "fraction": 0, "min_slack_ns": None, "mean_slack_ns": None})
    lines.append(f"| {name} | {x['count']} | {x['fraction']:.1%} | {x['min_slack_ns']} | {x['mean_slack_ns']} |")

lines += [
    "",
    "## 3. Interpretation",
    "",
    "1. 最差单条路径属于 butterfly：`bf_cycle_reg[3] → signal_reg_reg[...]`，R3 post-route WNS 为 -0.904 ns；该路径报告显示约70%为 route delay。",
    "2. 但 top-1000 中 multiplier front-end 占多数，说明问题不是单一 butterfly 瓶颈。operand/vector buffer 到 operand/lane-product 的路径仍然形成大范围跨区网络。",
    "3. reduction 占比已经较低，说明 R3 的静态 terminal-dot 改造确实消除了部分 reduction 动态写回网络，但没有使全局设计达到500 MHz。",
    "4. 高扇出证据中，除全局 reset 外，`final10_mem`/`ready_vector_id` 相关网达到约1040、`vector_buf` 相关网约1024，`sched_src_reg_reg_n_0_[10][1]` fanout 800，另有多个 `signal_reg` LUT net 超过250；这说明输出/状态控制、调度和 butterfly 存储网络仍然高度全局化。",
    "5. 因此不能只做 butterfly 局部补丁，也不能只继续修 multiplier 单条路径；下一版本必须同时做 multiplier/operand cluster 与 butterfly/signal cluster 的局部化。",
    "",
    "## 4. Gate decision",
    "",
    "- R3 functional/bit-exact: 保持已验证通过。",
    "- R3 static reduction connectivity: 保持通过。",
    "- R3 500 MHz post-route: FAIL（WNS -0.904 ns）。",
    "- 下一步：暂停 R3 局部补丁，进入新的架构级 cluster-local static dataflow 设计；不得直接复制当前全局动态 signal bank。",
    "",
    "## 5. STOP items",
    "",
    "- 当前版本不得宣称500 MHz闭合。",
    "- 在完成新的局部化结构并通过综合门禁前，不得继续集成 DST7/DCT8、LFNST 或完整二维 Core。",
]
OUT_MD.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("R3_TIMING_TOPOLOGY_SUMMARY_PASS")
print(f"paths={len(rows)}")
for name in ["multiplier_frontend", "butterfly", "reduction", "control_schedule", "output_reorder", "other"]:
    print(name, cats.get(name, {}).get("count", 0))
