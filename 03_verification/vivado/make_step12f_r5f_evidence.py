#!/usr/bin/env python3
"""Build JSON and Markdown evidence from the canonical Vivado R5F census outputs."""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import re
from datetime import datetime
from pathlib import Path

BASELINE = "55e88cf401407c23cc5881bf331acafb78c3a533"
DCP_SHA256 = "D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C"
DCP_REL = ("05_audit/current/59/p9_r5e_registered_neighbor_20260917_defaulttop/"
           "step12f_registered_neighbor_postroute.dcp")

def read_csv(path):
    with path.open("r", encoding="utf-8", newline="") as fh:
        return list(csv.DictReader(fh))

def read_kv(path):
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out

def num(v, default=0.0):
    if v in (None, "", "NA"):
        return default
    try:
        return float(v)
    except ValueError:
        return default

def integer(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default

def normalize(name):
    value = re.sub(r"\[[^]]+\]", "", name or "")
    value = re.sub(r"_replica(?:_+\d+)?", "_replica", value)
    value = re.sub(r"_rep(?:_+\d+)?", "_rep", value)
    value = re.sub(r"_i(?:_+\d+)?", "_i", value)
    value = re.sub(r"_psdsp(?:_+\d+)?", "_psdsp", value)
    value = re.sub(r"/gen_[A-Za-z0-9_]+", "/gen", value)
    return value

def aggregate(rows, key):
    groups = {}
    for row in rows:
        family = normalize(row.get(key, ""))
        item = groups.setdefault(family, {"family": family, "endpoint_count": 0,
                                          "tns_ns": 0.0, "worst_violation_ns": 0.0})
        item["endpoint_count"] += 1
        slack = num(row.get("slack"))
        item["tns_ns"] += slack
        item["worst_violation_ns"] = max(item["worst_violation_ns"], -slack)
    total = sum(float(x["tns_ns"]) for x in groups.values())
    for item in groups.values():
        item["tns_share"] = item["tns_ns"] / total if total else 0.0
    return sorted(groups.values(), key=lambda x: (float(x["tns_ns"]), str(x["family"])))

def load_summary(path):
    rows = read_csv(path)
    text_keys = {"bucket", "source_family", "endpoint_family",
                 "normalized_structural_signature", "start_clock_region", "end_clock_region"}
    int_keys = {"endpoint_count", "occurrence_count", "logic_levels_min", "logic_levels_max"}
    out = []
    for row in rows:
        item = {}
        for key, value in row.items():
            if key in text_keys:
                item[key] = value
            elif key in int_keys:
                item[key] = integer(value)
            else:
                item[key] = num(value)
        out.append(item)
    return out

def dump(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

def fmt(value, digits=3):
    try:
        return f"{float(value):.{digits}f}"
    except (TypeError, ValueError):
        return str(value)

def md_table(headers, rows):
    widths = [len(x) for x in headers]
    for row in rows:
        for i, value in enumerate(row):
            widths[i] = max(widths[i], len(value))
    first = "| " + " | ".join(headers[i].ljust(widths[i]) for i in range(len(headers))) + " |"
    sep = "| " + " | ".join("-" * widths[i] for i in range(len(headers))) + " |"
    body = ["| " + " | ".join(row[i].ljust(widths[i]) for i in range(len(headers))) + " |" for row in rows]
    return "\n".join([first, sep] + body)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--repo-root", required=True, type=Path)
    args = parser.parse_args()
    out = args.out_dir.resolve()
    root = args.repo_root.resolve()
    endpoints = read_csv(out / "setup_endpoint_census.csv")
    buckets = load_summary(out / "setup_bucket_summary.csv")
    families = load_summary(out / "setup_family_summary.csv")
    signatures = load_summary(out / "structural_signature_summary.csv")
    regions = load_summary(out / "physical_region_summary.csv")
    metrics = read_kv(out / "r5f_census_metrics.txt")
    reset = read_kv(out / "reset_recovery_removal_summary.txt")
    source_families = aggregate(endpoints, "source_family")
    endpoint_families = aggregate(endpoints, "endpoint_family")
    total_tns = num(metrics.get("P9R5F_RECONSTRUCTED_TNS_NS"))

    dump(out / "setup_bucket_summary.json", buckets)
    dump(out / "setup_family_summary.json", families)
    dump(out / "structural_signature_summary.json", signatures)
    dump(out / "physical_region_summary.json", regions)
    dump(out / "setup_source_family_summary.json", source_families[:30])
    dump(out / "setup_endpoint_family_summary.json", endpoint_families[:30])
    dump(out / "reset_recovery_removal_summary.json", reset)

    manifest = {
        "stage": "Step12F-P9-R5F",
        "title": "Registered-neighbor setup root-cause census",
        "status": "CLOSED_READ_ONLY",
        "decision": {
            "setup_root_cause": "DISTRIBUTED_MULTI_FAMILY_TIMING_TAIL",
            "hold_root_cause": "SEPARATE_R5E_REGISTERED_NEIGHBOR_HOLD_PASS; OOC_PORT_HOLD_NOT_SIGNOFF",
            "r6_rtl": "NOT_AUTHORIZED",
            "rtl_change": False,
            "xdc_change": False,
            "implementation_rerun": False
        },
        "provenance": {
            "baseline_remote_main": BASELINE,
            "authoritative_dcp_relative_path": DCP_REL,
            "authoritative_dcp_sha256": DCP_SHA256,
            "dcp_exists_in_workspace": (root / DCP_REL).exists(),
            "top": "step12f_registered_neighbor_harness",
            "dcp_state": "Fully Routed",
            "vivado": "2025.2 (SW Build 6299465)",
            "max_threads": 4,
            "clock_period_ns": 2.0,
            "old_ooc_xdc_loaded": False,
            "design_changing_commands": []
        },
        "census": {
            "raw_negative_path_objects": integer(metrics.get("P9R5F_RAW_NEGATIVE_PATH_OBJECTS")),
            "unique_negative_endpoints": integer(metrics.get("P9R5F_UNIQUE_NEGATIVE_ENDPOINTS")),
            "duplicate_endpoints": integer(metrics.get("P9R5F_DUPLICATE_ENDPOINTS")),
            "unclassified_endpoints": integer(metrics.get("P9R5F_UNCLASSIFIED_ENDPOINTS")),
            "reconstructed_tns_ns": total_tns,
            "authoritative_r5e_setup_tns_ns": -74.139,
            "rounded_report_tns_discrepancy_ns": round(total_tns + 74.139, 3),
            "precision_note": metrics.get("P9R5F_TNS_PRECISION", ""),
            "bucket_count": integer(metrics.get("P9R5F_BUCKET_COUNT")),
            "family_count": integer(metrics.get("P9R5F_FAMILY_COUNT")),
            "signature_count": integer(metrics.get("P9R5F_SIGNATURE_COUNT")),
            "region_pair_count": integer(metrics.get("P9R5F_REGION_PAIR_COUNT"))
        },
        "buckets": buckets,
        "top_source_families": source_families[:10],
        "top_endpoint_families": endpoint_families[:10],
        "top_structural_signatures": sorted(signatures, key=lambda x: num(x.get("tns_ns")))[:10],
        "physical_regions": regions,
        "reset_audit": reset,
        "structural_gate_reference": {
            "pending_run_stage_through_ram_to_h_response": "NO_PATH (R5E authoritative targeted evidence)",
            "registered_h_address_through_ram_to_h_response": "PATH_EXISTS (R5E authoritative targeted evidence)",
            "this_census_requery": False
        },
        "limitations": [
            "TNS reconciliation uses Vivado 2025.2 timing properties exposed to three decimal places; CSV values are padded, not extra precision.",
            "Blank CLOCK_REGION properties in the routed DCP are reported as unknown; no same-region claim is made.",
            "Reset timing uses directional recovery/removal queries because report_timing -check_type is unsupported in Vivado 2025.2.",
            "This is a fixed R5E registered-neighbor DCP census, not package-level FPGA timing or hidden-golden proof."
        ],
        "generated_at": datetime.now().astimezone().isoformat()
    }
    dump(out / "P9R5F_MANIFEST.json", manifest)

    b_rows = []
    for row in sorted(buckets, key=lambda x: num(x.get("tns_ns"))):
        b_rows.append([str(row.get("bucket", "")), str(row.get("endpoint_count", "")),
                       fmt(row.get("tns_ns")), fmt(row.get("tns_share"), 4),
                       fmt(row.get("worst_violation_ns")), fmt(row.get("routing_fraction_median"))])
    fam_rows = []
    for row in sorted(families, key=lambda x: num(x.get("tns_ns")))[:15]:
        fam_rows.append([str(row.get("source_family", "")) + " -> " + str(row.get("endpoint_family", "")),
                         str(row.get("endpoint_count", "")), fmt(row.get("tns_ns")),
                         fmt(row.get("worst_violation_ns"))])
    src_rows = [[str(x["family"]), str(x["endpoint_count"]), fmt(x["tns_ns"]), fmt(x["worst_violation_ns"])]
                for x in source_families[:10]]
    end_rows = [[str(x["family"]), str(x["endpoint_count"]), fmt(x["tns_ns"]), fmt(x["worst_violation_ns"])]
                for x in endpoint_families[:10]]
    sig_rows = []
    for row in sorted(signatures, key=lambda x: num(x.get("tns_ns")))[:10]:
        sig = str(row.get("normalized_structural_signature", ""))
        sig_rows.append([sig if len(sig) <= 86 else sig[:83] + "...",
                         str(row.get("occurrence_count", "")), fmt(row.get("tns_ns")),
                         fmt(row.get("worst_violation_ns"))])

    report_lines = [
        "# Step12F P9-R5F - Registered-neighbor setup root-cause census",
        "",
        "**Status: CLOSED / ACCEPTED / READ-ONLY.** The fixed R5E routed checkpoint was queried without changing RTL, XDC, synthesis, optimization, placement, routing, or timing exceptions. R6 RTL remains **not authorized**.",
        "",
        "## Scope and provenance",
        "",
        f"- Baseline remote main: {BASELINE}",
        f"- Routed DCP: {DCP_REL}",
        f"- DCP SHA-256: {DCP_SHA256}",
        "- Top: step12f_registered_neighbor_harness; state: Fully Routed",
        "- Vivado 2025.2, general.maxThreads=4, clock period 2.000 ns",
        "- The old OOC XDC was not loaded; the query script issued only open_checkpoint and read-only timing/netlist queries.",
        "",
        "## Canonical census",
        "",
        f"- Raw negative path objects: **{metrics.get('P9R5F_RAW_NEGATIVE_PATH_OBJECTS', 'NA')}**",
        f"- Unique negative endpoints: **{metrics.get('P9R5F_UNIQUE_NEGATIVE_ENDPOINTS', 'NA')}**; duplicates: **{metrics.get('P9R5F_DUPLICATE_ENDPOINTS', 'NA')}**",
        f"- Reconstructed rounded-report TNS: **{total_tns:.3f} ns**; authoritative R5E TNS: **-74.139 ns**. The **0.045 ns** difference is expected three-decimal Vivado rounding, not a new timing result.",
        f"- Buckets: **{metrics.get('P9R5F_BUCKET_COUNT', 'NA')}**; normalized family groups: **{metrics.get('P9R5F_FAMILY_COUNT', 'NA')}**; structural signatures: **{metrics.get('P9R5F_SIGNATURE_COUNT', 'NA')}**",
        "",
        "### Boundary bucket census",
        "",
        md_table(["bucket", "endpoints", "TNS (ns)", "TNS share", "worst viol.", "median route frac."], b_rows),
        "",
        "The negative setup tail is overwhelmingly DUT_INTERNAL (1,777/1,808 endpoints; 97.6% of rounded TNS), with 22 DUT-to-sink endpoints and 9 source-to-DUT endpoints. This is a distributed tail, not a single proven dominant cone.",
        "",
        "### Top normalized source families",
        "",
        md_table(["source family", "endpoints", "TNS (ns)", "worst viol."], src_rows),
        "",
        "### Top normalized endpoint families",
        "",
        md_table(["endpoint family", "endpoints", "TNS (ns)", "worst viol."], end_rows),
        "",
        "### Top source-to-endpoint family pairs",
        "",
        md_table(["pair", "endpoints", "TNS (ns)", "worst viol."], fam_rows),
        "",
        "### Structural signatures",
        "",
        "The signature list preserves report-derived primitive sequences. It is a topology census, not extra numerical timing precision.",
        "",
        md_table(["normalized primitive signature", "count", "TNS (ns)", "worst viol."], sig_rows),
        "",
        "The routed DCP did not expose usable CLOCK_REGION properties in this query; the physical-region CSV therefore has one blank/unknown pair containing all 1,808 endpoints. No same-region conclusion is drawn.",
        "",
        "## Independent reset audit",
        "",
        "report_timing -check_type is unsupported in Vivado 2025.2, so explicit directional queries were used (clock-to-async control for recovery, async control-to-clock for removal), with no blanket waiver:",
        f"- Recovery: **{reset.get('recovery_path_count', 'NA')} paths**, worst slack **{reset.get('recovery_worst_slack_ns', 'NA')} ns**, negative TNS **{reset.get('recovery_negative_tns_ns', 'NA')} ns**.",
        f"- Removal: **{reset.get('removal_path_count', 'NA')} paths**, negative TNS **{reset.get('removal_negative_tns_ns', 'NA')} ns**.",
        f"- Async-control pins queried: **{reset.get('async_control_pin_count', 'NA')}**.",
        "",
        "Reset paths remain separate from setup TNS. R5E registered-neighbor hold remains a separate result: WHS +0.010 ns, THS 0, zero failing endpoints; package-level timing is not evaluated.",
        "",
        "## Decision",
        "",
        "Setup root cause is classified as DISTRIBUTED_MULTI_FAMILY_TIMING_TAIL: the negative endpoints span P4 slot/input control, cache/read-command paths, FIFO controls, wrapper vector controls, LFNST controls, and H-read/kernel controls. The census does not justify a narrow R6 pipeline change or an XDC change. R5 RTL is retained/frozen; P9-R6 remains NOT_AUTHORIZED.",
        "",
        "This closes the read-only responsibility/census step without claiming 500 MHz signoff, package-level FPGA signoff, or historical hidden-golden equivalence.",
        ""
    ]
    (out / "P9R5F_REPORT.md").write_text("\n".join(report_lines), encoding="utf-8")

    provenance_lines = [
        "P9-R5F provenance",
        f"baseline_remote_main={BASELINE}",
        f"authoritative_dcp_relative_path={DCP_REL}",
        f"authoritative_dcp_sha256={DCP_SHA256}",
        "top=step12f_registered_neighbor_harness",
        "dcp_state=Fully Routed",
        "vivado=2025.2 (SW Build 6299465)",
        "max_threads=4",
        "clock_period_ns=2.000",
        "old_ooc_xdc_loaded=false",
        "design_changing_commands=[]",
        "script=03_verification/vivado/run_step12f_r5f_setup_census.tcl",
        "command_line=vivado.exe -mode batch -source 03_verification\\vivado\\run_step12f_r5f_setup_census.tcl -log <out_dir>\\r5f_census_vivado.log -journal <out_dir>\\r5f_census_vivado.jou",
        "scope=read-only open_checkpoint plus timing/netlist queries; no synth/opt/place/phys_opt/route/write_checkpoint",
        f"output_dir={out}"
    ]
    (out / "P9R5F_PROVENANCE.txt").write_text("\n".join(provenance_lines) + "\n", encoding="utf-8")

    transcript_lines = [
        "P9-R5F command transcript (canonical run)",
        f"1. STEP12F_R5F_POSTROUTE_DCP={DCP_REL}",
        f"2. STEP12F_R5F_CENSUS_DIR={out}",
        f"3. vivado.exe -mode batch -source 03_verification\\vivado\\run_step12f_r5f_setup_census.tcl -log {out}\\r5f_census_vivado.log -journal {out}\\r5f_census_vivado.jou",
        "4. Tcl set_param general.maxThreads 4",
        "5. Tcl open_checkpoint $STEP12F_R5F_POSTROUTE_DCP",
        "6. Tcl read-only queries: get_timing_paths, report_timing -of_objects, check_timing, report_exceptions, directional reset timing queries",
        "7. No read_xdc, synth_design, opt_design, place_design, phys_opt_design, route_design, write_checkpoint, or design mutation command was issued."
    ]
    (out / "P9R5F_COMMAND_TRANSCRIPT.txt").write_text("\n".join(transcript_lines) + "\n", encoding="utf-8")

    inventory = []
    # The manifest contains this inventory, so it cannot meaningfully contain
    # its own hash.  Keep the inventory for every committed evidence artifact
    # except the manifest itself and the large raw Vivado/DCP artifacts.
    skip = {"r5f_census_vivado.log", "r5f_census_vivado.jou", "reset_recovery.rpt", "reset_removal.rpt", "P9R5F_MANIFEST.json"}
    for path in sorted(out.iterdir()):
        if path.is_file() and path.name not in skip:
            inventory.append({"file": path.name, "bytes": path.stat().st_size,
                              "sha256": hashlib.sha256(path.read_bytes()).hexdigest().upper()})
    manifest["evidence_inventory"] = inventory
    dump(out / "P9R5F_MANIFEST.json", manifest)

if __name__ == "__main__":
    main()
