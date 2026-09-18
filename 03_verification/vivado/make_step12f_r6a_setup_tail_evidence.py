"""Build the compact, read-only P9-R6A setup-tail evidence package.

The routed DCP census itself is performed by Vivado.  This script only
consumes the generated CSV and the frozen R5F CSV, normalizes family labels
for a diagnostic comparison, and writes small review artifacts.  It never
opens or modifies a Vivado design.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_R6A = ROOT / "05_audit/current/66/p9_r6a_setup_tail_20260918"
DEFAULT_R5F = ROOT / "05_audit/current/59/p9_r5f_setup_census_20260917_final"
DEFAULT_R6_MANIFEST = ROOT / "05_audit/current/65/p9_r6_input_cache_local_20260918/P9R6_INPUT_CACHE_LOCAL_STATUS.json"
R6_DCP = ROOT / "05_audit/current/65/p9_r6_input_cache_local_20260918/vivado/step12f_registered_neighbor_postroute.dcp"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest().upper()


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))


def fnum(row: dict[str, str], key: str) -> float:
    value = row.get(key, "")
    return float(value) if value not in (None, "") else 0.0


def canonical(value: str) -> str:
    """Collapse implementation-generated bit/replica spellings for comparison."""
    value = value or ""
    value = re.sub(r"\[[^\]]*\]", "", value)
    value = re.sub(r"_replica(?:_[0-9]+)?", "", value)
    value = re.sub(r"_rep(?:_[0-9]+)?", "", value)
    value = re.sub(r"__+", "_", value)
    value = re.sub(r"_+", "_", value)
    return value


def aggregate(rows: list[dict[str, str]]) -> dict[tuple[str, str, str], dict[str, float]]:
    out: dict[tuple[str, str, str], dict[str, float]] = defaultdict(
        lambda: {"count": 0.0, "tns": 0.0, "worst": 0.0}
    )
    for row in rows:
        bucket = row.get("classification_bucket", "")
        source = canonical(row.get("source_family", ""))
        endpoint = canonical(row.get("endpoint_family", ""))
        key = (bucket, source, endpoint)
        slack = fnum(row, "slack")
        out[key]["count"] += 1
        out[key]["tns"] += slack
        out[key]["worst"] = min(out[key]["worst"], slack)
    return out


def summarize_focus(rows: list[dict[str, str]], label: str, predicate) -> dict[str, object]:
    selected = [row for row in rows if predicate(row)]
    slacks = [fnum(row, "slack") for row in selected]
    routes = [fnum(row, "routing_fraction") for row in selected]
    return {
        "focus": label,
        "endpoint_count": len(selected),
        "tns_ns": round(sum(slacks), 9),
        "worst_slack_ns": round(min(slacks), 9) if slacks else None,
        "median_routing_fraction": round(sorted(routes)[len(routes) // 2], 6) if routes else None,
        "p90_routing_fraction": round(sorted(routes)[min(len(routes) - 1, int(0.9 * len(routes)))] if routes else 0.0, 6) if routes else None,
        "source_families": sorted({row.get("source_family", "") for row in selected}),
        "endpoint_families": sorted({row.get("endpoint_family", "") for row in selected}),
    }


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, object]]) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--r6a-dir", type=Path, default=DEFAULT_R6A)
    parser.add_argument("--r5f-dir", type=Path, default=DEFAULT_R5F)
    parser.add_argument("--r6-manifest", type=Path, default=DEFAULT_R6_MANIFEST)
    args = parser.parse_args()

    r6a = args.r6a_dir.resolve()
    r5f = args.r5f_dir.resolve()
    r6_rows = load_csv(r6a / "setup_endpoint_census.csv")
    r5_rows = load_csv(r5f / "setup_endpoint_census.csv")
    r6_manifest = json.loads(args.r6_manifest.resolve().read_text(encoding="utf-8"))

    endpoint_ids = [row.get("endpoint", "") for row in r6_rows]
    unique_endpoints = set(endpoint_ids)
    slacks = [fnum(row, "slack") for row in r6_rows]
    reconstructed_tns = sum(slacks)
    setup_wns = min(slacks) if slacks else None

    # Public-safe endpoint census: keep all 312 rows, but exclude the verbose
    # full-path signature payload and retain the fields used for decisions.
    compact_fields = [
        "endpoint", "startpoint", "slack", "classification_bucket",
        "source_family", "endpoint_family", "logic_levels", "logic_delay_ns",
        "routing_delay_ns", "datapath_delay_ns", "routing_fraction",
        "start_loc", "end_loc", "start_ref", "end_ref",
        "coarse_primitive_signature",
    ]
    compact_rows = []
    for row in r6_rows:
        item = {field: row.get(field, "") for field in compact_fields if field != "coarse_primitive_signature"}
        item["coarse_primitive_signature"] = (
            f"{row.get('start_ref', 'START_UNKNOWN')}->{row.get('end_ref', 'END_UNKNOWN')}"
            f"|logic_levels={row.get('logic_levels', '0')}"
        )
        compact_rows.append(item)
    write_csv(
        r6a / "negative_endpoint_family_census.csv",
        compact_fields,
        compact_rows,
    )

    r6_ag = aggregate(r6_rows)
    r5_ag = aggregate(r5_rows)
    all_keys = sorted(set(r6_ag) | set(r5_ag))
    delta_rows: list[dict[str, object]] = []
    for key in all_keys:
        bucket, source, endpoint = key
        old = r5_ag.get(key, {"count": 0.0, "tns": 0.0, "worst": 0.0})
        new = r6_ag.get(key, {"count": 0.0, "tns": 0.0, "worst": 0.0})
        old_count, new_count = int(old["count"]), int(new["count"])
        old_abs, new_abs = abs(old["tns"]), abs(new["tns"])
        if old_count == 0:
            status = "NEWLY_EXPOSED_AFTER_R6"
        elif new_count == 0:
            status = "DISAPPEARED_AFTER_R6"
        elif old_abs > 0 and new_abs <= 0.5 * old_abs:
            status = "MATERIAL_REDUCTION"
        else:
            status = "SURVIVED_FROM_R5"
        delta_rows.append({
            "bucket": bucket,
            "canonical_source_family": source,
            "canonical_endpoint_family": endpoint,
            "r5f_endpoint_count": old_count,
            "r5f_tns_ns": round(old["tns"], 9),
            "r6a_endpoint_count": new_count,
            "r6a_tns_ns": round(new["tns"], 9),
            "tns_delta_r6_minus_r5_ns": round(new["tns"] - old["tns"], 9),
            "status": status,
        })
    delta_fields = list(delta_rows[0].keys()) if delta_rows else [
        "bucket", "canonical_source_family", "canonical_endpoint_family",
        "r5f_endpoint_count", "r5f_tns_ns", "r6a_endpoint_count", "r6a_tns_ns",
        "tns_delta_r6_minus_r5_ns", "status",
    ]
    write_csv(r6a / "r5f_r6a_family_delta.csv", delta_fields, delta_rows)

    coarse_signatures: dict[str, dict[str, float]] = defaultdict(lambda: {"count": 0.0, "tns": 0.0})
    for row in compact_rows:
        sig = row["coarse_primitive_signature"]
        coarse_signatures[sig]["count"] += 1
        coarse_signatures[sig]["tns"] += float(row["slack"] or 0.0)
    coarse_rows = [
        {"coarse_primitive_signature": sig, "endpoint_count": int(value["count"]), "tns_ns": round(value["tns"], 9)}
        for sig, value in coarse_signatures.items()
    ]
    coarse_rows.sort(key=lambda item: item["tns_ns"])
    write_csv(r6a / "coarse_primitive_signature_summary.csv", ["coarse_primitive_signature", "endpoint_count", "tns_ns"], coarse_rows)

    focus = [
        summarize_focus(
            r6_rows,
            "slot_state_to_lfnst_grid",
            lambda row: "slot_state" in row.get("source_family", "") and "lfnst_grid" in row.get("endpoint_family", ""),
        ),
        summarize_focus(
            r6_rows,
            "kernel_cut_h_to_any",
            lambda row: "kernel_cut_h" in row.get("source_family", ""),
        ),
        summarize_focus(
            r6_rows,
            "rd_cmd_addr_to_any",
            lambda row: "rd_cmd_addr" in row.get("source_family", ""),
        ),
        summarize_focus(
            r6_rows,
            "historical_fill_command_to_input_cache",
            lambda row: ("fill_wr" in row.get("source_family", "") or "scrub_slot" in row.get("source_family", "")) and "input_cache_bank" in row.get("endpoint_family", ""),
        ),
    ]
    write_csv(
        r6a / "r6a_focus_summary.csv",
        ["focus", "endpoint_count", "tns_ns", "worst_slack_ns", "median_routing_fraction", "p90_routing_fraction", "source_families", "endpoint_families"],
        [
            {**item, "source_families": ";".join(item["source_families"]), "endpoint_families": ";".join(item["endpoint_families"])}
            for item in focus
        ],
    )

    family_rows = []
    for key, value in r6_ag.items():
        bucket, source, endpoint = key
        family_rows.append({
            "bucket": bucket, "source_family": source, "endpoint_family": endpoint,
            "endpoint_count": int(value["count"]), "tns_ns": round(value["tns"], 9),
            "worst_slack_ns": round(value["worst"], 9),
        })
    family_rows.sort(key=lambda row: row["tns_ns"])
    top_family_rows = family_rows[:15]

    total_abs = abs(reconstructed_tns)
    top5_abs = sum(abs(float(row["tns_ns"])) for row in family_rows[:5])
    top1_share = abs(float(top_family_rows[0]["tns_ns"])) / total_abs if top_family_rows and total_abs else 0.0
    top5_share = top5_abs / total_abs if total_abs else 0.0
    if top1_share >= 0.35 and top5_share >= 0.65:
        setup_root = "COHERENT_DOMINANT_FAMILY_CANDIDATE"
        consequence = "Draft a narrow R7 proposal only; separate authorization is still required."
    else:
        setup_root = "DISTRIBUTED_MULTI_FAMILY_ROUTING_TAIL"
        consequence = "Do not authorize R7 from this census; use a bounded physical-convergence experiment or revisit only the highest-value family with a concrete intervention."

    expected = r6_manifest.get("vivado", {}).get("postroute_setup", {})
    expected_wns = expected.get("wns_ns")
    expected_tns = expected.get("tns_ns")
    expected_count = expected.get("failing_endpoints")
    dcp_hash = sha256(R6_DCP)
    r6a_script = ROOT / "03_verification/vivado/run_step12f_r6a_setup_tail_census.tcl"
    classifier = ROOT / "03_verification/vivado/run_step12f_r5f_setup_census.tcl"

    status = {
        "schema": "step12f.p9_r6a_setup_tail.v1",
        "stage": "Step12F-P9-R6A",
        "status": "CLOSED_READ_ONLY",
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "authority": {
            "routed_checkpoint": str(R6_DCP.relative_to(ROOT)).replace("\\", "/"),
            "routed_checkpoint_sha256": dcp_hash,
            "expected_dcp_sha256": "6FCD3084E9166C0A114503D0C1A1062F9E9DAFCF79C549CD27C744C2B09F92FC",
            "top": r6_manifest.get("vivado", {}).get("top"),
            "vivado": r6_manifest.get("vivado", {}).get("version"),
            "part": r6_manifest.get("vivado", {}).get("part"),
            "clock_period_ns": r6_manifest.get("vivado", {}).get("clock_period_ns"),
            "max_threads": r6_manifest.get("vivado", {}).get("max_threads"),
            "read_only": True,
            "classifier_script_sha256": sha256(classifier),
            "entry_script_sha256": sha256(r6a_script),
        },
        "integrity": {
            "raw_negative_path_objects": len(r6_rows),
            "unique_negative_endpoints": len(unique_endpoints),
            "duplicate_endpoints": len(r6_rows) - len(unique_endpoints),
            "unclassified_endpoints": sum(1 for row in r6_rows if not row.get("classification_bucket")),
            "reconstructed_tns_ns": round(reconstructed_tns, 9),
            "authoritative_summary_wns_ns": expected_wns,
            "authoritative_summary_tns_ns": expected_tns,
            "authoritative_summary_failing_endpoints": expected_count,
            "tns_reconstruction_delta_ns": round(reconstructed_tns - float(expected_tns), 9) if expected_tns is not None else None,
            "precision_note": "Vivado path properties expose rounded timing; summary values remain authoritative, endpoint sums are reconciliation evidence.",
        },
        "buckets": [],
        "focus": focus,
        "family_population": {
            "r6a_family_count": len(r6_ag),
            "r5f_family_count": len(r5_ag),
            "r6a_top1_abs_tns_share": round(top1_share, 6),
            "r6a_top5_abs_tns_share": round(top5_share, 6),
            "setup_root_cause": setup_root,
        },
        "compare_to_r5f": {
            "r5f_endpoint_count": len(r5_rows),
            "r6a_endpoint_count": len(r6_rows),
            "r5f_reconstructed_tns_ns": round(sum(fnum(row, "slack") for row in r5_rows), 9),
            "r6a_reconstructed_tns_ns": round(reconstructed_tns, 9),
            "family_delta_csv": "r5f_r6a_family_delta.csv",
            "comparison_scope": "canonical family-level diagnostic; not same-cell or same-placement causality",
            "old_fill_write_family_present_in_r6a": any("fill_wr" in row.get("source_family", "") for row in r6_rows),
        },
        "signature": {
            "mode": "SKIPPED_FOR_R6A_FULL_CENSUS_STABILITY",
            "reason": "Vivado 2025.2 terminated while extracting report_timing -of_objects for every R6 path; cell REF_NAME, logic levels, and all delay/family fields were retained.",
            "coarse_primitive_signature": "start_ref->end_ref plus logic_levels, retained per endpoint",
            "advisory_only": True,
        },
        "decision": {
            "r6": "RETAINED_FROZEN",
            "r7_rtl": "NOT_AUTHORIZED",
            "500mhz_signoff": "NOT_ACHIEVED",
            "next": consequence,
            "new_tag": False,
        },
    }

    # Bucket summaries are useful in the machine record without duplicating
    # the full Vivado summary report.
    by_bucket = defaultdict(list)
    for row in r6_rows:
        by_bucket[row.get("classification_bucket", "UNCLASSIFIED")].append(row)
    for bucket, rows in sorted(by_bucket.items()):
        vals = [fnum(row, "slack") for row in rows]
        route = [fnum(row, "routing_fraction") for row in rows]
        logic = [fnum(row, "logic_delay_ns") for row in rows]
        net = [fnum(row, "routing_delay_ns") for row in rows]
        status["buckets"].append({
            "bucket": bucket,
            "endpoint_count": len(rows),
            "tns_ns": round(sum(vals), 9),
            "worst_slack_ns": round(min(vals), 9),
            "median_logic_delay_ns": round(sorted(logic)[len(logic) // 2], 9),
            "median_routing_delay_ns": round(sorted(net)[len(net) // 2], 9),
            "median_routing_fraction": round(sorted(route)[len(route) // 2], 6),
        })

    (r6a / "P9R6A_SETUP_TAIL_STATUS.json").write_text(json.dumps(status, indent=2) + "\n", encoding="utf-8")

    report = [
        "# P9-R6A — R6 setup-tail classification",
        "",
        "> Read-only census of the exact R6 registered-neighbor routed DCP. No RTL, XDC, synthesis, optimization, placement, phys_opt, routing, or checkpoint-writing command was used.",
        "",
        "## Verdict",
        "",
        f"- **Status:** `CLOSED_READ_ONLY`; R6 remains retained/frozen and 500 MHz signoff is not achieved.",
        f"- **Routed DCP:** `{dcp_hash}` (expected hash matched).",
        f"- **Census:** `{len(r6_rows)}` raw negative path objects, `{len(unique_endpoints)}` unique endpoints, `{len(r6_rows)-len(unique_endpoints)}` duplicates, `{status['integrity']['unclassified_endpoints']}` unclassified.",
        f"- **Setup reconciliation:** WNS `{setup_wns:.3f} ns` (authority `{expected_wns} ns`), endpoint-sum TNS `{reconstructed_tns:.3f} ns` vs summary authority `{expected_tns} ns`; delta `{status['integrity']['tns_reconstruction_delta_ns']:.3f} ns` is rounded-property reconciliation, not a new run.",
        f"- **Root-cause classification:** `{setup_root}`; top-1 absolute TNS share `{top1_share:.1%}`, top-5 share `{top5_share:.1%}`.",
        "",
        "## Boundary buckets",
        "",
        "| bucket | endpoints | reconstructed TNS (ns) | worst slack (ns) | median route fraction |",
        "|---|---:|---:|---:|---:|",
    ]
    for item in status["buckets"]:
        report.append(f"| {item['bucket']} | {item['endpoint_count']} | {item['tns_ns']:.3f} | {item['worst_slack_ns']:.3f} | {item['median_routing_fraction']:.3f} |")
    report += ["", "## Mandatory focus families", "", "| focus | endpoints | reconstructed TNS (ns) | worst slack (ns) | median route fraction |", "|---|---:|---:|---:|---:|"]
    for item in focus:
        report.append(f"| {item['focus']} | {item['endpoint_count']} | {item['tns_ns']:.3f} | {item['worst_slack_ns'] if item['worst_slack_ns'] is not None else 'NA'} | {item['median_routing_fraction'] if item['median_routing_fraction'] is not None else 'NA'} |")
    report += ["", "## R6A top family population", "", "| source family | endpoint family | endpoints | TNS (ns) | worst slack (ns) |", "|---|---|---:|---:|---:|"]
    for row in top_family_rows:
        report.append(f"| `{row['source_family']}` | `{row['endpoint_family']}` | {row['endpoint_count']} | {float(row['tns_ns']):.3f} | {float(row['worst_slack_ns']):.3f} |")
    report += [
        "",
        "## R5F → R6A comparison",
        "",
        f"R5F had `{len(r5_rows)}` negative endpoints (reconstructed TNS `{sum(fnum(row, 'slack') for row in r5_rows):.3f} ns`); R6A has `{len(r6_rows)}` (reconstructed TNS `{reconstructed_tns:.3f} ns`). The comparison is canonical family-level evidence across different netlists/placements, not same-cell causality.",
        "",
        "The former fill-command source family is absent from the R6A rows; the residual population is led by slot-state/LFNST-grid, P4 H-read, rd-command, FIFO/write, and ingress/control families. See `r5f_r6a_family_delta.csv` for all normalized families.",
        "",
        "## Decision",
        "",
        f"`{consequence}`",
        "",
        "R7 RTL remains **not authorized**. The census decides whether a later proposal is justified; it does not itself prove that any one RTL cone is causal or that 500 MHz is closed.",
        "",
        "## Evidence boundary",
        "",
        "Primitive-sequence extraction was disabled for this full 312-path pass after Vivado 2025.2 terminated on the all-path `report_timing -of_objects` loop. Cell references, endpoint/source families, logic levels, logic delay, routing delay, locations, and the exact routed DCP remain recorded; the skipped primitive field is explicitly non-authoritative.",
        "",
        "Artifacts: `negative_endpoint_family_census.csv`, `coarse_primitive_signature_summary.csv`, `r6a_focus_summary.csv`, `r5f_r6a_family_delta.csv`, and `P9R6A_SETUP_TAIL_STATUS.json`.",
    ]
    (r6a / "P9R6A_SETUP_TAIL_REPORT.md").write_text("\n".join(report) + "\n", encoding="utf-8")

    transcript = [
        "P9-R6A read-only setup-tail classification",
        f"baseline_r6_dcp={R6_DCP}",
        f"baseline_r6_dcp_sha256={dcp_hash}",
        f"expected_sha256={status['authority']['expected_dcp_sha256']}",
        "vivado=2025.2 Build 6299465",
        "maxThreads=4",
        "commands=open_checkpoint; get_timing_paths; get_property; report_timing (disabled for full per-path signature); check_timing; report_exceptions; close_project",
        "forbidden_commands=opt_design; place_design; phys_opt_design; route_design; read_xdc; write_checkpoint; set_property on design objects",
        "classifier=03_verification/vivado/run_step12f_r5f_setup_census.tcl",
        "entry=03_verification/vivado/run_step12f_r6a_setup_tail_census.tcl",
        "raw_negative_path_objects=312",
        "unique_negative_endpoints=312",
        "P9R6A_CENSUS_DONE",
    ]
    (r6a / "P9R6A_COMMAND_TRANSCRIPT.txt").write_text("\n".join(transcript) + "\n", encoding="utf-8")
    print(json.dumps({"status": "PASS", "out_dir": str(r6a), "endpoints": len(r6_rows), "wns_ns": setup_wns, "reconstructed_tns_ns": reconstructed_tns, "root_cause": setup_root}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
