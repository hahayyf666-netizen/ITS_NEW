#!/usr/bin/env python3
"""Summarize the read-only P9-R5G G0 Vivado locality extraction.

The input DCP is never modified by this helper.  It joins the Vivado-emitted
cell/tile inventory with the positive-and-negative ingress->input_mem path
population and emits machine-readable evidence for the conditional G1
decision.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


def fnum(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def inum(value: str | None) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def quantile(values: list[float], q: float) -> float | None:
    if not values:
        return None
    vals = sorted(values)
    if len(vals) == 1:
        return vals[0]
    pos = (len(vals) - 1) * q
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return vals[lo]
    return vals[lo] + (vals[hi] - vals[lo]) * (pos - lo)


def stats(values: list[float]) -> dict[str, float | int | None]:
    return {
        "count": len(values),
        "min": min(values) if values else None,
        "median": statistics.median(values) if values else None,
        "p90": quantile(values, 0.90),
        "p95": quantile(values, 0.95),
        "max": max(values) if values else None,
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def tile_distance(row: dict[str, str]) -> int | None:
    sx, sy = inum(row.get("start_tile_x")), inum(row.get("start_tile_y"))
    ex, ey = inum(row.get("end_tile_x")), inum(row.get("end_tile_y"))
    if None in (sx, sy, ex, ey):
        return None
    return abs(sx - ex) + abs(sy - ey)


def bbox(rows: list[dict[str, str]], xkey: str = "tile_x", ykey: str = "tile_y") -> dict[str, int | None]:
    xs = [inum(r.get(xkey)) for r in rows]
    ys = [inum(r.get(ykey)) for r in rows]
    xs = [x for x in xs if x is not None]
    ys = [y for y in ys if y is not None]
    return {
        "x_min": min(xs) if xs else None,
        "x_max": max(xs) if xs else None,
        "y_min": min(ys) if ys else None,
        "y_max": max(ys) if ys else None,
        "coordinate_count": len(xs),
    }


def load_json_if(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--g0-dir", required=True, type=Path)
    parser.add_argument("--dcp", required=True, type=Path)
    parser.add_argument("--r5e-manifest", required=True, type=Path)
    args = parser.parse_args()

    out_dir = args.g0_dir
    inventory_path = out_dir / "g0_cell_inventory.csv"
    path_path = out_dir / "g0_ingress_inputmem_paths.csv"
    if not inventory_path.exists() or not path_path.exists():
        raise SystemExit("missing Vivado G0 CSV output")

    with inventory_path.open(newline="", encoding="utf-8-sig") as handle:
        inventory = list(csv.DictReader(handle))
    with path_path.open(newline="", encoding="utf-8-sig") as handle:
        paths = list(csv.DictReader(handle))

    inventory_by_cell = {row["cell_name"]: row for row in inventory if row.get("cell_name")}
    path_stats = {}
    for family in sorted({row.get("source_family", "") for row in paths}):
        family_rows = [row for row in paths if row.get("source_family") == family]
        negative = [row for row in family_rows if (fnum(row.get("slack")) or 0.0) < 0.0]
        nonnegative = [row for row in family_rows if (fnum(row.get("slack")) or 0.0) >= 0.0]

        def summarize(subset: list[dict[str, str]]) -> dict:
            distances = [float(d) for row in subset if (d := tile_distance(row)) is not None]
            route_fracs = []
            for row in subset:
                route = fnum(row.get("routing_delay_ns"))
                data = fnum(row.get("datapath_delay_ns"))
                if route is not None and data and data > 0:
                    route_fracs.append(route / data)
            slacks = [fnum(row.get("slack")) for row in subset]
            slacks = [s for s in slacks if s is not None]
            negative_tns = sum(s for s in slacks if s < 0.0)
            return {
                "path_count": len(subset),
                "negative_path_count": sum(1 for s in slacks if s < 0.0),
                "negative_tns_ns": negative_tns,
                "distance": stats(distances),
                "routing_fraction": stats(route_fracs),
                "logic_levels": stats([float(v) for row in subset if (v := inum(row.get("logic_levels"))) is not None]),
            }

        path_stats[family] = {
            "all": summarize(family_rows),
            "failing": summarize(negative),
            "passing_or_zero": summarize(nonnegative),
            "failing_minus_passing_median_tile_distance": (
                summarize(negative)["distance"]["median"] - summarize(nonnegative)["distance"]["median"]
                if summarize(negative)["distance"]["median"] is not None
                and summarize(nonnegative)["distance"]["median"] is not None
                else None
            ),
        }

    population = {}
    for family in sorted({row.get("family", "") for row in inventory}):
        rows = [row for row in inventory if row.get("family") == family]
        sites = {row.get("site") for row in rows if row.get("site")}
        tiles = {row.get("tile") for row in rows if row.get("tile")}
        fanouts = [inum(row.get("fanout")) for row in rows]
        fanouts = [v for v in fanouts if v is not None]
        population[family] = {
            "cell_count": len(rows),
            "unique_site_count": len(sites),
            "unique_tile_count": len(tiles),
            "tile_bbox": bbox(rows),
            "site_types": dict(Counter(row.get("site_type", "") for row in rows)),
            "fanout": stats([float(v) for v in fanouts]),
        }

    # Link the negative R5F census to the complete DCP cell population.
    r5f_path = args.r5e_manifest.parent.parent / "p9_r5f_setup_census_20260917_final" / "setup_endpoint_census.csv"
    negative_pairs = []
    if r5f_path.exists():
        with r5f_path.open(newline="", encoding="utf-8-sig") as handle:
            for row in csv.DictReader(handle):
                if row.get("source_family") in {
                    "u_dut/u_unified_p4_kernel/ingress_group_q_reg",
                    "u_dut/u_unified_p4_kernel/ingress_data_q_reg",
                } and row.get("endpoint_family") == "u_dut/u_unified_p4_kernel/input_mem_reg":
                    negative_pairs.append(row)

    negative_population = defaultdict(set)
    for row in negative_pairs:
        negative_population["source:" + row.get("source_family", "")].add(row.get("start_cell", ""))
        negative_population["endpoint:input_mem_reg"].add(row.get("end_cell", ""))

    r5e_manifest = load_json_if(args.r5e_manifest)
    authoritative = r5e_manifest.get("authoritative_run", {})

    # G0 decision is deliberately conditional: locality is strongly indicated
    # for the ingress/input_mem pair, but no pblock geometry is authorized by
    # this read-only report.  G1 still needs a frozen intervention chosen from
    # the extracted bounding boxes and capacity data.
    group = path_stats.get("ingress_group_q_reg", {})
    data = path_stats.get("ingress_data_q_reg", {})
    group_delta = group.get("failing_minus_passing_median_tile_distance")
    data_delta = data.get("failing_minus_passing_median_tile_distance")
    locality_indicated = (
        group_delta is not None and data_delta is not None and group_delta >= 10 and data_delta >= 10
    )
    decision = "A_OR_B_CANDIDATE_REQUIRES_GEOMETRY_SELECTION" if locality_indicated else "NO_BOUNDED_LOCALITY_INTERVENTION_JUSTIFIED"

    result = {
        "stage": "Step12F-P9-R5G-G0",
        "status": "CLOSED_READ_ONLY",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": r5e_manifest.get("baseline_commit", "UNKNOWN"),
        "fixed_dcp": {
            "path": str(args.dcp),
            "sha256": sha256(args.dcp),
            "expected_sha256": "D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C",
            "sha256_match": sha256(args.dcp) == "D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C",
        },
        "tool": {
            "vivado": "2025.2",
            "part": "xcku5p-ffvb676-2-e",
            "max_threads": 4,
            "implementation_commands": "FORBIDDEN",
            "rtl_xdc_changes": "FORBIDDEN",
        },
        "authoritative_r5e": {
            "setup": authoritative.get("setup", {}),
            "hold": authoritative.get("hold", {}),
            "route_status": authoritative.get("route_status", {}),
        },
        "inventory": population,
        "negative_r5f_population": {key: len(value) for key, value in sorted(negative_population.items())},
        "targeted_path_population": path_stats,
        "g0_decision": decision,
        "g0_interpretation": {
            "locality_hypothesis": "STRONGLY_INDICATED" if locality_indicated else "NOT_ESTABLISHED",
            "evidence": "Failing ingress->input_mem paths are materially farther in tile coordinates than passing paths for both control and data source families." if locality_indicated else "Failing-vs-passing distance separation did not meet the predeclared indication rule.",
            "limitations": [
                "Tile Manhattan distance is a placement proxy, not a timing proof.",
                "SLICE/DSP/RAM resource indices are not directly comparable; tile GRID_POINT coordinates are used.",
                "G0 does not authorize a pblock or any implementation command.",
                "G1 must use one common postsynth DCP and a matched CONTROL/TREATMENT A/B.",
            ],
        },
    }

    (out_dir / "G0_LOCALITY_MANIFEST.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    summary_rows = []
    for family, item in path_stats.items():
        for status, data_item in item.items():
            if status not in {"all", "failing", "passing_or_zero"}:
                continue
            summary_rows.append({
                "source_family": family,
                "population": status,
                "path_count": data_item["path_count"],
                "negative_path_count": data_item["negative_path_count"],
                "negative_tns_ns": f'{data_item["negative_tns_ns"]:.6f}',
                "tile_distance_median": data_item["distance"]["median"],
                "tile_distance_p90": data_item["distance"]["p90"],
                "tile_distance_max": data_item["distance"]["max"],
                "routing_fraction_median": data_item["routing_fraction"]["median"],
                "routing_fraction_p90": data_item["routing_fraction"]["p90"],
            })
    with (out_dir / "g0_path_population_summary.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = list(summary_rows[0].keys()) if summary_rows else ["source_family", "population"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(summary_rows)

    with (out_dir / "g0_population_summary.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = ["family", "cell_count", "unique_site_count", "unique_tile_count", "tile_bbox", "fanout_median", "fanout_p90", "fanout_max"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for family, item in population.items():
            writer.writerow({
                "family": family,
                "cell_count": item["cell_count"],
                "unique_site_count": item["unique_site_count"],
                "unique_tile_count": item["unique_tile_count"],
                "tile_bbox": json.dumps(item["tile_bbox"], sort_keys=True),
                "fanout_median": item["fanout"]["median"],
                "fanout_p90": item["fanout"]["p90"],
                "fanout_max": item["fanout"]["max"],
            })

    report = []
    report.append("# Step12F-P9-R5G G0 — Physical Locality Qualification")
    report.append("")
    report.append("Status: `CLOSED_READ_ONLY`; no RTL/XDC/implementation command was executed.")
    report.append("")
    report.append(f"- Fixed routed DCP SHA-256: `{result['fixed_dcp']['sha256']}`")
    report.append("- Vivado 2025.2, xcku5p-ffvb676-2-e, maxThreads=4")
    report.append(f"- G0 decision: **{decision}**")
    report.append("")
    report.append("## Complete-cell inventory")
    report.append("")
    report.append("| Family | Cells | Sites | Tiles | Tile bbox |")
    report.append("|---|---:|---:|---:|---|")
    for family in sorted(population):
        item = population[family]
        report.append(f"| `{family}` | {item['cell_count']} | {item['unique_site_count']} | {item['unique_tile_count']} | `{item['tile_bbox']}` |")
    report.append("")
    report.append("## Failing-versus-passing path population")
    report.append("")
    report.append("Distances are tile-grid Manhattan proxies; they are not timing guarantees.")
    report.append("")
    report.append("| Source family | Population | Paths | Negative TNS | Median distance | P90 distance |")
    report.append("|---|---|---:|---:|---:|---:|")
    for family in sorted(path_stats):
        for status, label in (("failing", "failing"), ("passing_or_zero", "passing/zero")):
            item = path_stats[family][status]
            report.append(f"| `{family}` | {label} | {item['path_count']} | {item['negative_tns_ns']:.3f} | {item['distance']['median']:.1f} | {item['distance']['p90']:.1f} |")
    report.append("")
    report.append("## Decision")
    report.append("")
    report.append(result["g0_interpretation"]["evidence"])
    report.append("")
    report.append("This read-only result does not choose pblock coordinates. If G1 is run, it must use one common postsynth DCP and matched CONTROL/TREATMENT flows with exactly one locality constraint in TREATMENT.")
    (out_dir / "G0_LOCALITY_REPORT.md").write_text("\n".join(report) + "\n", encoding="utf-8")

    provenance = [
        "P9-R5G G0 read-only locality qualification",
        f"generated_utc={result['generated_at']}",
        f"dcp_sha256={result['fixed_dcp']['sha256']}",
        f"vivado=2025.2",
        "maxThreads=4",
        "rtl_changes=FORBIDDEN",
        "xdc_changes=FORBIDDEN",
        "synthesis_implementation=FORBIDDEN",
        f"decision={decision}",
    ]
    (out_dir / "G0_LOCALITY_PROVENANCE.txt").write_text("\n".join(provenance) + "\n", encoding="utf-8")
    print(json.dumps({"status": "CLOSED_READ_ONLY", "decision": decision, "output": str(out_dir)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
