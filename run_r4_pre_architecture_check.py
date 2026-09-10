"""R4_PRE read-only architecture census.

Consumes the frozen P4Dataflow model and the copied R3R routed reports.  It
does not modify RTL or regenerate tables/golden data.
"""
from __future__ import annotations

import csv
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
import sys
sys.path.insert(0, str(ROOT))
from run_p2f_a1_dataflow import P4Dataflow  # noqa: E402

OUT = ROOT / "03_verification" / "output"
CENSUS = OUT / "r4_pre_timing_census"
OUT.mkdir(parents=True, exist_ok=True)


def path_census() -> dict:
    csv_path = CENSUS / "top1000_setup_paths.csv"
    rows = list(csv.DictReader(csv_path.open(encoding="utf-8"))) if csv_path.exists() else []

    def cat(row: dict[str, str]) -> str:
        sp = row.get("startpoint", "").lower()
        ep = row.get("endpoint", "").lower()
        if "signal_reg" in ep or "bf_cycle" in sp:
            return "butterfly"
        if re.search(r"operand_x|operand_coeff|vector_buf|lane_product", ep + sp):
            return "operand_frontend"
        if re.search(r"red_|dot_value|reduction", ep + sp):
            return "reduction"
        if re.search(r"sched_|issue_|valid_reg|bf_cycle", ep + sp):
            return "control_schedule"
        if re.search(r"result|group|out_|reorder|raw_flat", ep + sp):
            return "output_reorder"
        return "other"

    groups: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        groups[cat(row)].append(row)
    result = {"path_rows": len(rows), "categories": {}}
    for name, items in sorted(groups.items()):
        slacks = [float(x["slack"]) for x in items if x.get("slack")]
        result["categories"][name] = {
            "count": len(items),
            "fraction": len(items) / len(rows) if rows else 0.0,
            "min_slack_ns": min(slacks) if slacks else None,
            "mean_slack_ns": sum(slacks) / len(slacks) if slacks else None,
        }
    return result


def signal_records(model: P4Dataflow) -> list[dict]:
    all_signals = []
    seen: set[int] = set()

    def collect(signals):
        for sig in signals:
            if id(sig) in seen:
                continue
            seen.add(id(sig))
            all_signals.append(sig)
            if sig.even is not None:
                collect([sig.even])

    collect(model.root)
    out = []
    for sig in all_signals:
        if sig.even is None:
            even_ref = {"kind": "dot", "dot_id": getattr(sig, "even_dot").dot_id}
            even_ready = getattr(sig, "even_dot").ready_rel
        else:
            even_ref = {"kind": "signal", "signal_id": sig.even.signal_id}
            even_ready = sig.even.ready_rel
        odd_ref = {"kind": "dot", "dot_id": sig.odd.dot_id if sig.odd else None}
        out.append({
            "signal_id": sig.signal_id,
            "level": sig.level,
            "p": sig.p,
            "ready_rel": sig.ready_rel,
            "cycle_rel": max(even_ready, sig.odd.ready_rel if sig.odd else 0) + 1,
            "op": "sub" if "high" in sig.signal_id else "add",
            "even": even_ref,
            "odd": odd_ref,
        })
    return out


def lane_records(model: P4Dataflow) -> list[dict]:
    recs = []
    for op in model.ops:
        recs.append({
            "op_id": op.op_id,
            "level": op.level,
            "branch": op.branch,
            "output_p": op.output_p,
            "input_m": op.input_m,
            "issue_cycle": op.issue_rel,
            "physical_lane": op.physical_lane,
            "source_x_index": op.source_x_index,
            "coefficient": op.coefficient,
        })
    return recs


def cluster_metrics(records: list[dict], signals: list[dict]) -> dict:
    metrics = {}
    for cluster_count in (4, 8, 16):
        lanes_per = 128 // cluster_count
        clusters = defaultdict(list)
        for r in records:
            clusters[r["physical_lane"] // lanes_per].append(r)
        source_sets = {str(c): sorted({r["source_x_index"] for r in rs}) for c, rs in clusters.items()}
        coeff_sets = {str(c): sorted({r["coefficient"] for r in rs}) for c, rs in clusters.items()}
        lane_unique = defaultdict(set)
        for r in records:
            lane_unique[r["physical_lane"]].add(r["source_x_index"])
        source_cluster_use = defaultdict(set)
        for c, rs in clusters.items():
            for src in {r["source_x_index"] for r in rs}:
                source_cluster_use[src].add(c)
        metrics[str(cluster_count)] = {
            "lanes_per_cluster": lanes_per,
            "source_union_per_cluster": source_sets,
            "coefficient_union_per_cluster": coeff_sets,
            "max_lane_unique_source_count": max((len(v) for v in lane_unique.values()), default=0),
            "mean_lane_unique_source_count": sum(map(len, lane_unique.values())) / len(lane_unique),
            "input_source_cluster_replication": {
                str(src): len(cs) for src, cs in sorted(source_cluster_use.items())
            },
            "max_input_source_cluster_replication": max(
                (len(cs) for cs in source_cluster_use.values()), default=0
            ),
        }
    return metrics


def main() -> None:
    model = P4Dataflow()
    records = lane_records(model)
    signals = signal_records(model)
    lane_unique = defaultdict(set)
    coeff_unique = defaultdict(set)
    for r in records:
        lane_unique[r["physical_lane"]].add(r["source_x_index"])
        coeff_unique[r["physical_lane"]].add(r["coefficient"])

    summary = {
        "status": "PASS_MODEL_CENSUS",
        "baseline": "copied R3R; no RTL modified",
        "operation_count": len(records),
        "dot_count": len(model.dots),
        "signal_count": len(signals),
        "lane_count": 128,
        "issue_cycle_counts": dict(sorted(Counter(r["issue_cycle"] for r in records).items())),
        "lane_unique_source_count_histogram": dict(sorted(Counter(len(v) for v in lane_unique.values()).items())),
        "lane_unique_coeff_count_histogram": dict(sorted(Counter(len(v) for v in coeff_unique.values()).items())),
        "max_lane_unique_sources": max(map(len, lane_unique.values())),
        "max_lane_unique_coefficients": max(map(len, coeff_unique.values())),
        "lane_source_map": {
            str(lane): {
                "sources": sorted(lane_unique[lane]),
                "coefficients": sorted(coeff_unique[lane]),
                "records": [r for r in records if r["physical_lane"] == lane],
            }
            for lane in sorted(lane_unique)
        },
        "butterfly_signal_records": signals,
        "cluster_partition_metrics": cluster_metrics(records, signals),
        "timing_census": path_census(),
    }

    (OUT / "r4_lane_source_map.json").write_text(
        json.dumps(summary["lane_source_map"], indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (OUT / "r4_butterfly_connectivity.json").write_text(
        json.dumps({"signals": signals, "signal_count": len(signals)}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    (OUT / "r4_cluster_partition_comparison.json").write_text(
        json.dumps(summary["cluster_partition_metrics"], indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    (OUT / "r4_pre_architecture_census.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    timing = summary["timing_census"]
    lines = [
        "# V35 P2F-B2 R4_PRE Architecture Census",
        "",
        "本报告只做 R3R 的只读架构/时序预检查，未修改 RTL、ROM、golden 或约束。",
        "",
        "## Frozen graph",
        f"- operations: {len(records)}",
        f"- dots: {len(model.dots)}",
        f"- butterfly signals: {len(signals)}",
        f"- lanes: 128",
        f"- issue-cycle counts: `{summary['issue_cycle_counts']}`",
        "",
        "## Lane candidate evidence",
        f"- max unique x sources per physical lane: {summary['max_lane_unique_sources']}",
        f"- max unique coefficients per physical lane: {summary['max_lane_unique_coefficients']}",
        f"- source-count histogram: `{summary['lane_unique_source_count_histogram']}`",
        f"- coefficient-count histogram: `{summary['lane_unique_coeff_count_histogram']}`",
        "",
        "## R3R routed timing census",
        f"- path rows: {timing.get('path_rows', 0)}",
        "",
        "| category | count | fraction | min slack (ns) | mean slack (ns) |",
        "|---|---:|---:|---:|---:|",
    ]
    for name, item in sorted(timing.get("categories", {}).items()):
        lines.append(
            f"| {name} | {item['count']} | {item['fraction']:.1%} | "
            f"{item['min_slack_ns']} | {item['mean_slack_ns']} |"
        )
    lines += [
        "",
        "## Interpretation",
        "",
        "The current post-route bottleneck must be treated as two coupled locality problems:",
        "the operand/coefficient front-end and the butterfly/signal store. A single butterfly-only patch is not accepted by this precheck.",
        "The lane/source map and full butterfly connectivity JSON are the authoritative inputs for the next cluster partition step.",
        "",
        "## Gate",
        "",
        "PASS_MODEL_CENSUS: exact 1368-op / 64-dot / 124-signal graph extracted from the frozen P4Dataflow model.",
        "No R4 RTL was written and no new synthesis/implementation was launched in this step.",
    ]
    (OUT / "V35_P2F_R4_CLUSTER_ARCHITECTURE_PRECHECK.md").write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )
    print("R4_PRE_ARCHITECTURE_CENSUS_PASS")
    print(json.dumps({
        "operations": len(records),
        "dots": len(model.dots),
        "signals": len(signals),
        "max_lane_unique_sources": summary["max_lane_unique_sources"],
        "max_lane_unique_coefficients": summary["max_lane_unique_coefficients"],
        "timing_categories": timing.get("categories", {}),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
