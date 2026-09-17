#!/usr/bin/env python3
"""Build the read-only P9-R5G-G0.5 geometry/risk evidence.

The fixed R5E routed DCP is queried by Vivado, while this helper combines the
result with the already published G0 full destination population.  No
implementation is performed here.  The candidate pblock is a deterministic
*hypothetical* rectangle used only for geometry/capacity prediction; it is not
created or loaded into Vivado.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


EXPECTED_DCP_SHA = "D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C"
EXPECTED_PRODUCERS = 64
EXPECTED_DESTINATIONS = 4032
NEAR_ZERO_FRACTION = 0.10

# These are pre-registered geometry rules.  They are deliberately broad
# enough to leave placement freedom while still creating a meaningful locality
# intervention in G1.  G0.5 only predicts against this rectangle.
# The first extraction used 8/12 and produced a geometry-dependent false
# rejection (only 31/46 active bits fit).  Use a pre-registered loose window
# with enough margin to test a single-region hypothesis without making it a
# whole-device constraint.
REGION_HALF_X = 12
REGION_HALF_Y = 16
MIN_AVAILABLE_FF_HEADROOM = 2 * EXPECTED_PRODUCERS
MAX_PROJECTED_FF_UTILIZATION = 0.50


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


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def stats(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "min": None, "median": None, "p90": None, "p95": None, "max": None}
    vals = sorted(values)
    return {
        "count": len(vals),
        "min": min(vals),
        "median": statistics.median(vals),
        "p90": vals[min(len(vals) - 1, math.ceil(0.90 * len(vals)) - 1)],
        "p95": vals[min(len(vals) - 1, math.ceil(0.95 * len(vals)) - 1)],
        "max": max(vals),
    }


def median_or_none(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def weighted_median(points: list[tuple[float, float]], weights: list[float]) -> float | None:
    if not points or len(points) != len(weights):
        return None
    pairs = sorted(zip(points, weights), key=lambda item: item[0])
    total = sum(max(0.0, w) for _, w in pairs)
    if total <= 0:
        return median_or_none([p[0] for p in points])
    acc = 0.0
    for point, weight in pairs:
        acc += max(0.0, weight)
        if acc >= total / 2.0:
            return point[0]
    return pairs[-1][0][0]


def coord_median(rows: list[dict[str, str]], xkey: str, ykey: str) -> dict[str, float | None]:
    xs = [float(inum(row.get(xkey))) for row in rows if inum(row.get(xkey)) is not None]
    ys = [float(inum(row.get(ykey))) for row in rows if inum(row.get(ykey)) is not None]
    return {"x": median_or_none(xs), "y": median_or_none(ys)}


def weighted_coord_median(rows: list[dict[str, str]], xkey: str, ykey: str) -> dict[str, float | None]:
    valid = [row for row in rows if inum(row.get(xkey)) is not None and inum(row.get(ykey)) is not None]
    xs = [(float(inum(row[xkey])), 0.0) for row in valid]
    ys = [(float(inum(row[ykey])), 0.0) for row in valid]
    weights = [abs(fnum(row.get("slack")) or 0.0) for row in valid]
    return {
        "x": weighted_median(xs, weights),
        "y": weighted_median(ys, weights),
    }


def parse_slice(loc: str | None) -> tuple[int, int] | None:
    if not loc:
        return None
    match = re.search(r"SLICE_X(\d+)Y(\d+)", loc)
    return (int(match.group(1)), int(match.group(2))) if match else None


def parse_bit(cell: str | None) -> int | None:
    if not cell:
        return None
    match = re.search(r"ingress_data_q_reg\[(\d+)\]", cell)
    return int(match.group(1)) if match else None


def tile_distance(x1: float | None, y1: float | None, x2: float | None, y2: float | None) -> float | None:
    if None in (x1, y1, x2, y2):
        return None
    return abs(x1 - x2) + abs(y1 - y2)


def delta_stats(deltas: list[float]) -> dict[str, float | int | None]:
    result = stats(deltas)
    result["decrease_count"] = sum(1 for d in deltas if d < 0)
    result["increase_count"] = sum(1 for d in deltas if d > 0)
    result["unchanged_count"] = sum(1 for d in deltas if d == 0)
    return result


def family_from_source(cell: str | None) -> str:
    value = cell or ""
    if "lfnst_grid_reg" in value:
        return "lfnst_grid"
    if "kernel_vector_q_reg" in value:
        return "kernel_vector"
    if "kernel_stage_q_reg" in value:
        return "kernel_stage"
    if "kernel_" in value and "_q_reg" in value:
        return "kernel_control"
    if "boundary" in value:
        return "boundary"
    if "input_mem_reg" in value:
        return "input_mem"
    return "other"


def source_cell_key(cell: str) -> str:
    # Keep original producer bits separate; normalize physical replicas only
    # for source-family reporting in later G1 runs.
    return re.sub(r"_replica(?:_[0-9]+)?", "_replica", cell or "")


def site_capacity(site_rows: list[dict[str, str]]) -> dict[str, object]:
    legal_ff = sum(inum(row.get("legal_ff_bel_count")) or 0 for row in site_rows)
    legal_lut = sum(inum(row.get("legal_lut_bel_count")) or 0 for row in site_rows)
    occupied_ff = sum(inum(row.get("occupied_ff_count")) or 0 for row in site_rows)
    occupied_lut = sum(inum(row.get("occupied_lut_count")) or 0 for row in site_rows)
    occupied_cells = sum(inum(row.get("occupied_cell_count")) or 0 for row in site_rows)
    control_sets = Counter()
    control_set_rows = 0
    for row in site_rows:
        for item in (row.get("occupied_control_sets") or "").split(";"):
            if item:
                control_sets[item] += 1
                control_set_rows += 1
    available_ff = max(0, legal_ff - occupied_ff)
    projected_ff = occupied_ff + EXPECTED_PRODUCERS
    return {
        "site_count": len(site_rows),
        "legal_ff_capacity": legal_ff,
        "legal_lut_capacity": legal_lut,
        "occupied_ff": occupied_ff,
        "occupied_lut": occupied_lut,
        "occupied_cells": occupied_cells,
        "available_ff_capacity_reference": available_ff,
        "projected_ff_after_64": projected_ff,
        "projected_ff_utilization_reference": (projected_ff / legal_ff) if legal_ff else None,
        "occupied_control_set_count": len(control_sets),
        "control_set_data_available": control_set_rows > 0,
        "clock_regions": dict(sorted(Counter(row.get("clock_region") or "UNKNOWN" for row in site_rows).items())),
        "site_types": dict(sorted(Counter(row.get("site_type") or "UNKNOWN" for row in site_rows).items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--g0-dir", required=True, type=Path)
    parser.add_argument("--g05-dir", required=True, type=Path)
    parser.add_argument("--dcp", required=True, type=Path)
    parser.add_argument("--r5e-manifest", required=True, type=Path)
    parser.add_argument("--baseline-commit", required=True)
    args = parser.parse_args()
    args.g05_dir.mkdir(parents=True, exist_ok=True)

    g0_paths = read_csv(args.g0_dir / "g0_ingress_inputmem_paths.csv")
    g0_inventory = read_csv(args.g0_dir / "g0_cell_inventory.csv")
    producer_inventory = read_csv(args.g05_dir / "g05_producer_inventory.csv")
    upstream_rows = read_csv(args.g05_dir / "g05_upstream_paths.csv")
    site_rows = read_csv(args.g05_dir / "g05_candidate_site_inventory.csv")
    g0_inventory_by_cell = {row.get("cell_name", ""): row for row in g0_inventory if row.get("cell_name")}

    def endpoint_clock_region(row: dict[str, str]) -> str:
        return g0_inventory_by_cell.get(row.get("end_cell", ""), {}).get("clock_region") or "UNKNOWN"

    # G0's ingress-data population is one max-delay path per destination.  It
    # is the complete 4032-destination population used for the geometry proxy.
    data_paths = [
        row for row in g0_paths
        if row.get("source_family") == "ingress_data_q_reg"
        and (row.get("endpoint", "").endswith("/D") or not row.get("endpoint"))
    ]
    if len(data_paths) != EXPECTED_DESTINATIONS:
        # Keep the full rows if an older G0 CSV omitted pin suffixes.
        data_paths = [row for row in g0_paths if row.get("source_family") == "ingress_data_q_reg"]

    failing = [row for row in data_paths if (fnum(row.get("slack")) or 0.0) < 0.0]
    passing = [row for row in data_paths if (fnum(row.get("slack")) or 0.0) >= 0.0]
    if len(data_paths) != EXPECTED_DESTINATIONS:
        raise SystemExit(f"expected {EXPECTED_DESTINATIONS} ingress-data destinations, got {len(data_paths)}")

    primary_center_tile = coord_median(failing, "end_tile_x", "end_tile_y")
    weighted_center_tile = weighted_coord_median(failing, "end_tile_x", "end_tile_y")
    # G0 does not carry parsed LOC coordinates, so derive them from end_loc.
    end_loc_points = []
    for row in failing:
        point = parse_slice(row.get("end_loc"))
        if point:
            end_loc_points.append((point[0], point[1], row))
    primary_center_slice = {
        "x": median_or_none([float(x) for x, _, _ in end_loc_points]),
        "y": median_or_none([float(y) for _, y, _ in end_loc_points]),
    }
    weighted_center_slice = {
        "x": weighted_median([(float(x), 0.0) for x, _, _ in end_loc_points], [abs(fnum(r.get("slack")) or 0.0) for _, _, r in end_loc_points]),
        "y": weighted_median([(float(y), 0.0) for _, y, _ in end_loc_points], [abs(fnum(r.get("slack")) or 0.0) for _, _, r in end_loc_points]),
    }

    producer_sites = [parse_slice(row.get("loc")) for row in producer_inventory]
    producer_sites = [p for p in producer_sites if p]
    producer_bbox = {
        "x_min": min((x for x, _ in producer_sites), default=None),
        "x_max": max((x for x, _ in producer_sites), default=None),
        "y_min": min((y for _, y in producer_sites), default=None),
        "y_max": max((y for _, y in producer_sites), default=None),
    }

    if primary_center_slice["x"] is None or primary_center_slice["y"] is None:
        raise SystemExit("failing endpoints did not provide usable SLICE locations")
    center_x = int(round(primary_center_slice["x"]))
    center_y = int(round(primary_center_slice["y"]))
    region = {
        "site_x_min": center_x - REGION_HALF_X,
        "site_x_max": center_x + REGION_HALF_X,
        "site_y_min": center_y - REGION_HALF_Y,
        "site_y_max": center_y + REGION_HALF_Y,
        "rule": f"primary failing-endpoint SLICE median, half-width={REGION_HALF_X}, half-height={REGION_HALF_Y}",
    }
    region_sites = []
    for row in site_rows:
        point = parse_slice(row.get("site"))
        if point and region["site_x_min"] <= point[0] <= region["site_x_max"] and region["site_y_min"] <= point[1] <= region["site_y_max"]:
            region_sites.append(row)
    capacity = site_capacity(region_sites)
    capacity["headroom_gate_pass"] = (
        (capacity["available_ff_capacity_reference"] or 0) >= MIN_AVAILABLE_FF_HEADROOM
        and (capacity["projected_ff_utilization_reference"] is None or capacity["projected_ff_utilization_reference"] <= MAX_PROJECTED_FF_UTILIZATION)
    )

    # Use the median tile coordinate of legal sites as the hypothetical source
    # position.  This is a proxy only; actual placement is intentionally not
    # performed in G0.5.
    region_tiles = [(inum(row.get("tile_x")), inum(row.get("tile_y"))) for row in region_sites]
    region_tiles = [(x, y) for x, y in region_tiles if x is not None and y is not None]
    candidate_tile = {
        "x": median_or_none([float(x) for x, _ in region_tiles]),
        "y": median_or_none([float(y) for _, y in region_tiles]),
    }

    def predicted_deltas(rows: list[dict[str, str]]) -> list[float]:
        result = []
        for row in rows:
            old = tile_distance(
                fnum(row.get("start_tile_x")), fnum(row.get("start_tile_y")),
                fnum(row.get("end_tile_x")), fnum(row.get("end_tile_y")),
            )
            new = tile_distance(
                candidate_tile["x"], candidate_tile["y"],
                fnum(row.get("end_tile_x")), fnum(row.get("end_tile_y")),
            )
            if old is not None and new is not None:
                result.append(new - old)
        return result

    failing_delta = predicted_deltas(failing)
    passing_delta = predicted_deltas(passing)
    near_zero_count = max(1, math.ceil(len(passing) * NEAR_ZERO_FRACTION))
    near_zero = sorted(passing, key=lambda row: ((fnum(row.get("slack")) or 0.0), row.get("endpoint", "")))[:near_zero_count]
    near_zero_delta = predicted_deltas(near_zero)

    # Per-bit downstream clustering and per-family upstream summary.
    per_bit = {}
    by_bit = defaultdict(list)
    for row in data_paths:
        bit = parse_bit(row.get("start_cell"))
        if bit is not None:
            by_bit[bit].append(row)
    for bit in range(EXPECTED_PRODUCERS):
        rows = by_bit.get(bit, [])
        neg = [row for row in rows if (fnum(row.get("slack")) or 0.0) < 0.0]
        nonneg = [row for row in rows if (fnum(row.get("slack")) or 0.0) >= 0.0]
        points = [parse_slice(row.get("end_loc")) for row in neg]
        points = [p for p in points if p]
        per_bit[str(bit)] = {
            "path_count": len(rows),
            "failing_count": len(neg),
            "passing_count": len(nonneg),
            "failing_endpoint_median_slice": {
                "x": median_or_none([float(x) for x, _ in points]),
                "y": median_or_none([float(y) for _, y in points]),
            },
            "failing_endpoint_slice_dispersion": {
                "x": stats([float(x) for x, _ in points]),
                "y": stats([float(y) for _, y in points]),
            },
            "x2y1_count": sum(1 for row in neg if endpoint_clock_region(row) == "X2Y1"),
            "x3y1_count": sum(1 for row in neg if endpoint_clock_region(row) == "X3Y1"),
            "other_region_count": sum(1 for row in neg if endpoint_clock_region(row) not in {"X2Y1", "X3Y1"}),
        }

    upstream_by_family = defaultdict(list)
    for row in upstream_rows:
        upstream_by_family[row.get("source_family") or family_from_source(row.get("start_cell"))].append(row)
    upstream_summary = {}
    for family, rows in sorted(upstream_by_family.items()):
        slacks = [fnum(row.get("slack")) for row in rows]
        slacks = [x for x in slacks if x is not None]
        logic = [fnum(row.get("logic_delay_ns")) for row in rows]
        logic = [x for x in logic if x is not None]
        route = [fnum(row.get("routing_delay_ns")) for row in rows]
        route = [x for x in route if x is not None]
        data_delay = [fnum(row.get("datapath_delay_ns")) for row in rows]
        data_delay = [x for x in data_delay if x and x > 0]
        distances = [tile_distance(fnum(row.get("start_tile_x")), fnum(row.get("start_tile_y")), fnum(row.get("end_tile_x")), fnum(row.get("end_tile_y"))) for row in rows]
        distances = [x for x in distances if x is not None]
        upstream_delta = []
        for row in rows:
            old = tile_distance(fnum(row.get("start_tile_x")), fnum(row.get("start_tile_y")), fnum(row.get("end_tile_x")), fnum(row.get("end_tile_y")))
            new = tile_distance(fnum(row.get("start_tile_x")), fnum(row.get("start_tile_y")), candidate_tile["x"], candidate_tile["y"])
            if old is not None and new is not None:
                upstream_delta.append(new - old)
        upstream_summary[family] = {
            "endpoint_count": len(rows),
            "failing_count": sum(1 for x in slacks if x < 0),
            "wns_ns": min(slacks) if slacks else None,
            "tns_ns": sum(x for x in slacks if x < 0),
            "slack": stats(slacks),
            "logic_delay_ns": stats(logic),
            "routing_delay_ns": stats(route),
            "routing_fraction": stats([r / d for r, d in zip(route, data_delay)]) if len(route) == len(data_delay) else {},
            "tile_distance": stats(distances),
            "source_cells": sorted({row.get("start_cell", "") for row in rows}),
            "source_clock_regions": dict(sorted(Counter(row.get("start_clock_region") or "UNKNOWN" for row in rows).items())),
            "candidate_distance_delta": delta_stats(upstream_delta),
        }

    active_bits = [item for item in per_bit.values() if item["failing_count"] > 0]
    coherent_bits = [item for item in active_bits if item["failing_endpoint_median_slice"]["x"] is not None and region["site_x_min"] <= item["failing_endpoint_median_slice"]["x"] <= region["site_x_max"] and region["site_y_min"] <= item["failing_endpoint_median_slice"]["y"] <= region["site_y_max"]]
    coherence_ratio = (len(coherent_bits) / len(active_bits)) if active_bits else None

    upstream_negative_delta = [
        delta
        for row in upstream_rows
        if (fnum(row.get("slack")) or 0.0) < 0.0
        for delta in [
            (tile_distance(fnum(row.get("start_tile_x")), fnum(row.get("start_tile_y")), candidate_tile["x"], candidate_tile["y"]) - tile_distance(fnum(row.get("start_tile_x")), fnum(row.get("start_tile_y")), fnum(row.get("end_tile_x")), fnum(row.get("end_tile_y"))))
        ]
        if delta is not None
    ]

    # Deterministic, conservative read-only verdict.  A1 is approved only if
    # the single-region hypothesis is coherent, the region has headroom, and
    # the hypothetical move does not worsen the already-negative upstream
    # paths.  Timing itself remains a G1 measurement, never a G0.5 claim.
    if len(producer_inventory) != EXPECTED_PRODUCERS or not upstream_rows:
        decision = "NO_SAFE_GEOMETRY_FOUND"
    elif coherence_ratio is not None and coherence_ratio < 0.75:
        decision = "NO_COHERENT_SINGLE_REGION"
    elif not capacity["headroom_gate_pass"]:
        decision = "NO_SAFE_GEOMETRY_FOUND"
    elif upstream_negative_delta and median_or_none(upstream_negative_delta) is not None and median_or_none(upstream_negative_delta) > 5.0:
        decision = "A1_GEOMETRY_REJECTED_UPSTREAM_RISK"
    elif median_or_none(failing_delta) is None or median_or_none(failing_delta) >= -10.0:
        decision = "NO_SAFE_GEOMETRY_FOUND"
    else:
        decision = "A1_GEOMETRY_APPROVED"

    r5e_manifest = {}
    try:
        r5e_manifest = json.loads(args.r5e_manifest.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass

    result = {
        "stage": "Step12F-P9-R5G-G0.5",
        "status": "CLOSED_READ_ONLY",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": args.baseline_commit,
        "fixed_dcp": {
            "path": str(args.dcp),
            "sha256": sha256(args.dcp),
            "expected_sha256": EXPECTED_DCP_SHA,
            "sha256_match": sha256(args.dcp) == EXPECTED_DCP_SHA,
        },
        "tool": {"vivado": "2025.2", "part": "xcku5p-ffvb676-2-e", "max_threads": 4},
        "read_only_contract": {
            "implementation_commands": "FORBIDDEN",
            "pblock_creation": "FORBIDDEN",
            "rtl_xdc_changes": "FORBIDDEN",
            "write_checkpoint": "FORBIDDEN",
        },
        "population": {
            "producer_cells_expected": EXPECTED_PRODUCERS,
            "producer_cells_found": len(producer_inventory),
            "destination_paths_expected": EXPECTED_DESTINATIONS,
            "destination_paths_found": len(data_paths),
            "failing_destination_count": len(failing),
            "passing_destination_count": len(passing),
            "near_zero_passing_count": len(near_zero),
        },
        "centers": {
            "failing_endpoint_primary_tile": primary_center_tile,
            "failing_endpoint_slack_weighted_tile": weighted_center_tile,
            "failing_endpoint_primary_slice": primary_center_slice,
            "failing_endpoint_slack_weighted_slice": weighted_center_slice,
            "current_producer_slice_bbox": producer_bbox,
            "candidate_tile_representative": candidate_tile,
        },
        "candidate_geometry": {
            "region": region,
            "capacity": capacity,
            "region_tile_population": len(region_tiles),
            "region_clock_regions": dict(sorted(Counter(row.get("clock_region") or "UNKNOWN" for row in region_sites).items())),
        },
        "downstream_impact_proxy": {
            "failing_201": delta_stats(failing_delta),
            "passing_3831": delta_stats(passing_delta),
            "near_zero_passing_10pct": {
                "count": len(near_zero),
                "current_slack": stats([fnum(row.get("slack")) for row in near_zero if fnum(row.get("slack")) is not None]),
                "predicted_distance_delta": delta_stats(near_zero_delta),
                "source_bits": dict(sorted(Counter(str(parse_bit(row.get("start_cell"))) for row in near_zero).items())),
                "destination_regions": dict(sorted(Counter(endpoint_clock_region(row) for row in near_zero).items())),
            },
        },
        "per_bit_destination_clustering": per_bit,
        "active_bit_coherence": {
            "active_bits": len(active_bits),
            "coherent_bits_in_candidate_region": len(coherent_bits),
            "coherence_ratio": coherence_ratio,
            "rule": "at least 75% of active bits have failing-endpoint median inside the primary candidate region",
        },
        "upstream_to_ingress_data": {
            "endpoint_cells": len({row.get("endpoint_d", "") for row in upstream_rows}),
            "path_rows": len(upstream_rows),
            "coverage_complete": len({row.get("endpoint_d", "") for row in upstream_rows}) == EXPECTED_PRODUCERS,
            "by_source_family": upstream_summary,
            "negative_path_candidate_delta": delta_stats(upstream_negative_delta),
        },
        "decision": decision,
        "decision_rules": {
            "coherence_min_ratio": 0.75,
            "min_available_ff_headroom": MIN_AVAILABLE_FF_HEADROOM,
            "max_projected_ff_utilization_reference": MAX_PROJECTED_FF_UTILIZATION,
            "upstream_negative_median_distance_increase_reject_tiles": 5.0,
            "failing_median_distance_improvement_min_tiles": 10.0,
            "near_zero_passing_definition": "lowest-slack 10% of all non-negative destinations",
        },
        "limitations": [
            "Tile/site distance is a geometry proxy, not a timing prediction.",
            "G0.5 does not create a pblock or run implementation.",
            "Clock-region labels are context only; clock-skew change is not predicted.",
            "Reference occupancy/capacity comes from the routed DCP; G1-PREP must recheck after common opt_design.",
            "Phys-opt replica lineage is not present in this pre-implementation audit and must be counted in G1.",
            "A/B causality is not established until a common post-opt DCP is used for CONTROL/TREATMENT.",
        ],
        "r5e_context": r5e_manifest.get("authoritative_run", {}),
    }

    (args.g05_dir / "G05_GEOMETRY_MANIFEST.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    # Compact per-bit CSV for audit review.
    with (args.g05_dir / "g05_per_bit_clustering.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = ["bit", "path_count", "failing_count", "passing_count", "median_x", "median_y", "x2y1_count", "x3y1_count", "other_region_count"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for bit, item in per_bit.items():
            writer.writerow({
                "bit": bit,
                "path_count": item["path_count"],
                "failing_count": item["failing_count"],
                "passing_count": item["passing_count"],
                "median_x": item["failing_endpoint_median_slice"]["x"],
                "median_y": item["failing_endpoint_median_slice"]["y"],
                "x2y1_count": item["x2y1_count"],
                "x3y1_count": item["x3y1_count"],
                "other_region_count": item["other_region_count"],
            })

    report = [
        "# Step12F-P9-R5G-G0.5 — Producer Geometry / Risk Qualification",
        "",
        "Status: `CLOSED_READ_ONLY`; no opt/place/phys_opt/route, pblock creation, RTL/XDC change, or modified checkpoint.",
        "",
        f"- Baseline commit: `{args.baseline_commit}`",
        f"- Fixed routed DCP SHA-256: `{result['fixed_dcp']['sha256']}` (match={result['fixed_dcp']['sha256_match']})",
        f"- Decision: **{decision}**",
        "",
        "## Population and centers",
        "",
        f"- Producer cells: `{len(producer_inventory)}/{EXPECTED_PRODUCERS}`",
        f"- Downstream destinations: `{len(data_paths)}/{EXPECTED_DESTINATIONS}`; failing `{len(failing)}`, passing/zero `{len(passing)}`",
        f"- Primary failing endpoint tile center: `{primary_center_tile}`",
        f"- Slack-weighted failing endpoint tile center: `{weighted_center_tile}`",
        f"- Current producer SLICE bbox: `{producer_bbox}`",
        "",
        "## Candidate geometry (hypothetical; not created)",
        "",
        f"- Rule: `{region['rule']}`",
        f"- Candidate SLICE rectangle: `{region}`",
        f"- Representative candidate tile: `{candidate_tile}`",
        f"- Legal site/capacity summary: `{capacity}`",
        "",
        "## Downstream distance impact proxy",
        "",
        f"- Failing 201: `{result['downstream_impact_proxy']['failing_201']}`",
        f"- Passing 3831: `{result['downstream_impact_proxy']['passing_3831']}`",
        f"- Near-zero passing 10%: `{result['downstream_impact_proxy']['near_zero_passing_10pct']}`",
        "",
        "## Per-bit and upstream risk",
        "",
        f"- Active-bit coherence: `{result['active_bit_coherence']}`",
        f"- Upstream summary: `{result['upstream_to_ingress_data']}`",
        "",
        "## Interpretation",
        "",
        "The geometry decision is a pre-implementation screening result. Distance deltas do not predict routed slack, and the reference-DCP capacity must be rechecked after the common post-opt branch point in G1-PREP.",
        "",
        "Only `A1_GEOMETRY_APPROVED` can unlock G1-PREP. A1 remains a single producer-only pblock experiment; no input_mem, ingress_group, upstream LUT, or whole-kernel cells may be added.",
    ]
    (args.g05_dir / "G05_GEOMETRY_REPORT.md").write_text("\n".join(report) + "\n", encoding="utf-8")

    provenance = [
        "P9-R5G-G0.5 read-only producer geometry/risk qualification",
        f"generated_utc={result['generated_at']}",
        f"baseline_commit={args.baseline_commit}",
        f"dcp_sha256={result['fixed_dcp']['sha256']}",
        "vivado=2025.2",
        "maxThreads=4",
        "implementation_commands=FORBIDDEN",
        "pblock_creation=FORBIDDEN",
        "rtl_xdc_changes=FORBIDDEN",
        f"decision={decision}",
    ]
    (args.g05_dir / "G05_GEOMETRY_PROVENANCE.txt").write_text("\n".join(provenance) + "\n", encoding="utf-8")
    # Hash the emitted evidence artifacts (excluding this hash list itself) so
    # the public mirror can be checked without trusting filenames alone.
    hash_names = [
        "G05_GEOMETRY_MANIFEST.json",
        "G05_GEOMETRY_REPORT.md",
        "G05_GEOMETRY_PROVENANCE.txt",
        "g05_per_bit_clustering.csv",
        "g05_producer_inventory.csv",
        "g05_upstream_paths.csv",
        "g05_candidate_site_inventory.csv",
        "g05_read_only_status.txt",
        "g05_vivado.log",
        "g05_vivado.jou",
    ]
    hash_lines = ["P9-R5G-G0.5 evidence SHA-256", ""]
    for name in hash_names:
        path = args.g05_dir / name
        if path.exists():
            hash_lines.append(f"{sha256(path)}  {name}")
    (args.g05_dir / "G05_EVIDENCE_SHA256SUMS.txt").write_text("\n".join(hash_lines) + "\n", encoding="utf-8")
    print(json.dumps({"status": result["status"], "decision": decision, "output": str(args.g05_dir)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

