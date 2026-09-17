#!/usr/bin/env python3
"""Build the read-only P9-R5G-G0.6 producer-locality frontier.

This stage evaluates a fixed, deterministic candidate universe against the
complete G0/G0.5 path populations.  It is deliberately a geometry/risk
screening tool: no Vivado implementation command, pblock, checkpoint write,
RTL edit, or XDC edit is performed here.

The candidate universe and producer subsets are frozen in this source before
scoring.  Every candidate/subset pair, including rejected pairs, is emitted so
that the Pareto frontier cannot be reconstructed from selected examples only.
Distances are tile-grid proxies and are not timing predictions.
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


EXPECTED_BITS = 64
EXPECTED_DESTINATIONS = 4032
EXPECTED_UPSTREAM = 64
EXPECTED_UPSTREAM_NEGATIVE = 58
EXPECTED_UPSTREAM_PASSING = 6
EXPECTED_DOWNSTREAM_NEGATIVE = 201
NEAR_ZERO_FRACTION = 0.10

EXPECTED_DCP_SHA = "D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C"

# G0.5's final loose screening window is retained.  G0.6 scans only a fixed
# producer-side/inter-region corridor inside the G0.5 site inventory; anchors
# are generated on a fixed 4-site lattice, independent of slack scoring.
WINDOW_HALF_X = 12
WINDOW_HALF_Y = 16
ANCHOR_X_MIN = 56
ANCHOR_X_MAX = 100
ANCHOR_X_STEP = 4
ANCHOR_Y_MIN = 76
ANCHOR_Y_MAX = 116
ANCHOR_Y_STEP = 4
MIN_SITE_COVERAGE = 0.95
MIN_AVAILABLE_FF_HEADROOM = 128
MAX_PROJECTED_FF_UTILIZATION = 0.50


def fnum(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def inum(value: str | None) -> int | None:
    value_num = fnum(value)
    return int(value_num) if value_num is not None else None


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
        return {"count": 0, "min": None, "median": None, "p90": None, "p95": None, "max": None, "sum": 0.0}
    vals = sorted(values)
    return {
        "count": len(vals),
        "min": min(vals),
        "median": statistics.median(vals),
        "p90": vals[min(len(vals) - 1, math.ceil(0.90 * len(vals)) - 1)],
        "p95": vals[min(len(vals) - 1, math.ceil(0.95 * len(vals)) - 1)],
        "max": max(vals),
        "sum": sum(vals),
    }


def delta_stats(deltas: list[float]) -> dict[str, float | int | None]:
    result = stats(deltas)
    result["decrease_count"] = sum(1 for value in deltas if value < 0.0)
    result["increase_count"] = sum(1 for value in deltas if value > 0.0)
    result["unchanged_count"] = sum(1 for value in deltas if value == 0.0)
    return result


def median_or_none(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def parse_slice(value: str | None) -> tuple[int, int] | None:
    match = re.search(r"SLICE_X(\d+)Y(\d+)", value or "")
    return (int(match.group(1)), int(match.group(2))) if match else None


def parse_bit(value: str | None) -> int | None:
    match = re.search(r"ingress_data_q_reg\[(\d+)\]", value or "")
    return int(match.group(1)) if match else None


def tile_distance(x1: float | None, y1: float | None, x2: float | None, y2: float | None) -> float | None:
    if None in (x1, y1, x2, y2):
        return None
    return abs(x1 - x2) + abs(y1 - y2)


def row_point(row: dict[str, str], xkey: str, ykey: str) -> tuple[float, float] | None:
    x = fnum(row.get(xkey))
    y = fnum(row.get(ykey))
    return (x, y) if x is not None and y is not None else None


def point_median(rows: list[dict[str, str]], xkey: str, ykey: str) -> tuple[float | None, float | None]:
    points = [row_point(row, xkey, ykey) for row in rows]
    points = [point for point in points if point is not None]
    return (
        median_or_none([point[0] for point in points]),
        median_or_none([point[1] for point in points]),
    )


def point_dispersion(rows: list[dict[str, str]], xkey: str, ykey: str) -> tuple[float, float]:
    points = [row_point(row, xkey, ykey) for row in rows]
    points = [point for point in points if point is not None]
    if not points:
        return (0.0, 0.0)
    return (
        max(point[0] for point in points) - min(point[0] for point in points),
        max(point[1] for point in points) - min(point[1] for point in points),
    )


def site_capacity(rows: list[dict[str, str]], moved_count: int) -> dict[str, object]:
    legal_ff = sum(inum(row.get("legal_ff_bel_count")) or 0 for row in rows)
    legal_lut = sum(inum(row.get("legal_lut_bel_count")) or 0 for row in rows)
    occupied_ff = sum(inum(row.get("occupied_ff_count")) or 0 for row in rows)
    occupied_lut = sum(inum(row.get("occupied_lut_count")) or 0 for row in rows)
    occupied_cells = sum(inum(row.get("occupied_cell_count")) or 0 for row in rows)
    control_sets = Counter()
    control_rows = 0
    for row in rows:
        for item in (row.get("occupied_control_sets") or "").split(";"):
            if item:
                control_sets[item] += 1
                control_rows += 1
    available_ff = max(0, legal_ff - occupied_ff)
    projected_ff = occupied_ff + moved_count
    return {
        "site_count": len(rows),
        "expected_site_count": (2 * WINDOW_HALF_X + 1) * (2 * WINDOW_HALF_Y + 1),
        "legal_ff_capacity": legal_ff,
        "legal_lut_capacity": legal_lut,
        "occupied_ff": occupied_ff,
        "occupied_lut": occupied_lut,
        "occupied_cells": occupied_cells,
        "available_ff_capacity_reference": available_ff,
        "projected_ff_after_move": projected_ff,
        "projected_ff_utilization_reference": (projected_ff / legal_ff) if legal_ff else None,
        "occupied_control_set_count": len(control_sets),
        "control_set_data_available": control_rows > 0,
        "clock_regions": dict(sorted(Counter(row.get("clock_region") or "UNKNOWN" for row in rows).items())),
        "site_types": dict(sorted(Counter(row.get("site_type") or "UNKNOWN" for row in rows).items())),
    }


def metric_for_rows(
    rows: list[dict[str, str]],
    moved_bits: set[int],
    candidate_tile: tuple[float, float] | None,
    start_x: str,
    start_y: str,
    end_x: str,
    end_y: str,
) -> dict[str, object]:
    deltas: list[float] = []
    slacks: list[float] = []
    for row in rows:
        bit = parse_bit(row.get("start_cell"))
        if bit is None:
            bit = inum(row.get("ingress_bit"))
        old = tile_distance(fnum(row.get(start_x)), fnum(row.get(start_y)), fnum(row.get(end_x)), fnum(row.get(end_y)))
        if old is None:
            continue
        new = old
        if bit in moved_bits and candidate_tile is not None:
            moved = tile_distance(candidate_tile[0], candidate_tile[1], fnum(row.get(end_x)), fnum(row.get(end_y)))
            if moved is not None:
                new = moved
        deltas.append(new - old)
        slack = fnum(row.get("slack"))
        if slack is not None:
            slacks.append(slack)
    return {
        "delta": delta_stats(deltas),
        "current_slack": stats(slacks),
    }


def flatten_metric(prefix: str, metric: dict[str, object], output: dict[str, object]) -> None:
    delta = metric["delta"]
    slack = metric["current_slack"]
    assert isinstance(delta, dict) and isinstance(slack, dict)
    for key in ("count", "min", "median", "p90", "p95", "max", "sum", "decrease_count", "increase_count", "unchanged_count"):
        output[f"{prefix}_{key}"] = delta.get(key)
    for key in ("count", "min", "median", "p90", "p95", "max", "sum"):
        output[f"{prefix}_current_slack_{key}"] = slack.get(key)


def feature_tuple(item: dict[str, object]) -> tuple[float, ...]:
    values = []
    for key in (
        "producer_tile_x", "producer_tile_y", "upstream_source_tile_x", "upstream_source_tile_y",
        "downstream_fail_median_x", "downstream_fail_median_y", "downstream_all_median_x", "downstream_all_median_y",
        "x2y1_fraction", "x3y1_fraction", "downstream_fail_dispersion_x", "downstream_fail_dispersion_y",
    ):
        value = item.get(key)
        values.append(float(value) if isinstance(value, (int, float)) else 1e9)
    return tuple(values)


def list_sha(bits: list[int]) -> str:
    payload = json.dumps(bits, separators=(",", ":"), sort_keys=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest().upper()


def make_subsets(features: dict[int, dict[str, object]]) -> dict[str, dict[str, object]]:
    subsets: dict[str, dict[str, object]] = {}
    all_bits = list(range(EXPECTED_BITS))
    subsets["ALL_64"] = {"bits": all_bits, "rule": "all 64 ingress_data bits"}

    x2y1 = [bit for bit in all_bits if int(features[bit]["x2y1_count"]) > int(features[bit]["x3y1_count"])]
    x3y1 = [bit for bit in all_bits if int(features[bit]["x3y1_count"]) > int(features[bit]["x2y1_count"])]
    mixed = [bit for bit in all_bits if bit not in set(x2y1) | set(x3y1)]
    subsets["DEST_X2Y1_MAJOR"] = {"bits": x2y1, "rule": "x2y1 failing-destination count > x3y1 count"}
    subsets["DEST_X3Y1_MAJOR"] = {"bits": x3y1, "rule": "x3y1 failing-destination count > x2y1 count"}
    subsets["DEST_MIXED_OR_OTHER"] = {"bits": mixed, "rule": "tie/other destination-region split"}

    ordered = sorted(all_bits, key=lambda bit: (*feature_tuple(features[bit]), bit))
    for index in range(4):
        start = (index * len(ordered)) // 4
        end = ((index + 1) * len(ordered)) // 4
        subsets[f"FEATURE_BIN_{index}"] = {
            "bits": ordered[start:end],
            "rule": "lexicographic deterministic bin over frozen geometry features; no slack used for assignment",
        }
    return {name: {**item, "bits": sorted(item["bits"]), "bit_list_sha256": list_sha(sorted(item["bits"]))} for name, item in subsets.items()}


def dominates(left: tuple[float, ...], right: tuple[float, ...]) -> bool:
    return all(a <= b for a, b in zip(left, right)) and any(a < b for a, b in zip(left, right))


def objective(row: dict[str, object]) -> tuple[float, ...]:
    keys = (
        "u_neg_median", "u_neg_p90", "u_neg_increase_count", "u_pass_increase_count",
        "d_neg_median", "d_neg_p90", "d_near_median", "d_all_median", "moved_bit_count",
    )
    return tuple(float(row.get(key) if row.get(key) is not None else 1e9) for key in keys)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--g0-dir", required=True, type=Path)
    parser.add_argument("--g05-dir", required=True, type=Path)
    parser.add_argument("--dcp", required=True, type=Path)
    parser.add_argument("--baseline-commit", required=True)
    parser.add_argument("--out-dir", required=True, type=Path)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    dcp_sha = sha256(args.dcp)
    if dcp_sha != EXPECTED_DCP_SHA:
        raise SystemExit(f"fixed DCP SHA mismatch: {dcp_sha} != {EXPECTED_DCP_SHA}")

    g0_paths = read_csv(args.g0_dir / "g0_ingress_inputmem_paths.csv")
    g0_inventory = read_csv(args.g0_dir / "g0_cell_inventory.csv")
    g0_inventory_by_cell = {row.get("cell_name", ""): row for row in g0_inventory if row.get("cell_name")}
    producer_rows = read_csv(args.g05_dir / "g05_producer_inventory.csv")
    upstream_rows = read_csv(args.g05_dir / "g05_upstream_paths.csv")
    site_rows = read_csv(args.g05_dir / "g05_candidate_site_inventory.csv")
    if len(producer_rows) != EXPECTED_BITS:
        raise SystemExit(f"expected {EXPECTED_BITS} producer rows, got {len(producer_rows)}")
    data_rows = [row for row in g0_paths if row.get("source_family") == "ingress_data_q_reg"]
    if len(data_rows) != EXPECTED_DESTINATIONS:
        raise SystemExit(f"expected {EXPECTED_DESTINATIONS} downstream rows, got {len(data_rows)}")
    if len(upstream_rows) != EXPECTED_UPSTREAM:
        raise SystemExit(f"expected {EXPECTED_UPSTREAM} upstream rows, got {len(upstream_rows)}")

    producer_by_bit = {inum(row.get("bit_index")): row for row in producer_rows}
    upstream_by_bit = {inum(row.get("ingress_bit")): row for row in upstream_rows}
    downstream_by_bit: dict[int, list[dict[str, str]]] = defaultdict(list)
    for row in data_rows:
        bit = parse_bit(row.get("start_cell"))
        if bit is None:
            bit = parse_bit(row.get("startpoint"))
        if bit is not None:
            downstream_by_bit[bit].append(row)
    if set(producer_by_bit) != set(range(EXPECTED_BITS)) or set(upstream_by_bit) != set(range(EXPECTED_BITS)):
        raise SystemExit("producer/upstream bit coverage is not exactly 0..63")

    all_nonnegative = [row for row in data_rows if (fnum(row.get("slack")) or 0.0) >= 0.0]
    near_count = max(1, math.ceil(len(all_nonnegative) * NEAR_ZERO_FRACTION))
    d_near = sorted(all_nonnegative, key=lambda row: ((fnum(row.get("slack")) or 0.0), row.get("endpoint", "")))[:near_count]
    u_neg = [row for row in upstream_rows if (fnum(row.get("slack")) or 0.0) < 0.0]
    u_pass = [row for row in upstream_rows if (fnum(row.get("slack")) or 0.0) >= 0.0]
    d_neg = [row for row in data_rows if (fnum(row.get("slack")) or 0.0) < 0.0]

    def endpoint_clock_region(row: dict[str, str]) -> str:
        endpoint_cell = row.get("end_cell") or row.get("endpoint", "").rsplit("/", 1)[0]
        return g0_inventory_by_cell.get(endpoint_cell, {}).get("clock_region") or "UNKNOWN"

    features: dict[int, dict[str, object]] = {}
    with (args.out_dir / "g06_per_bit_features.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = [
            "bit", "producer_tile_x", "producer_tile_y", "producer_clock_region", "upstream_source_tile_x", "upstream_source_tile_y",
            "upstream_slack", "upstream_source_family", "downstream_path_count", "downstream_failing_count", "x2y1_count", "x3y1_count",
            "downstream_fail_median_x", "downstream_fail_median_y", "downstream_all_median_x", "downstream_all_median_y",
            "downstream_fail_dispersion_x", "downstream_fail_dispersion_y", "x2y1_fraction", "x3y1_fraction", "fail_feature_fallback",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for bit in range(EXPECTED_BITS):
            producer = producer_by_bit[bit]
            upstream = upstream_by_bit[bit]
            rows = downstream_by_bit[bit]
            failing = [row for row in rows if (fnum(row.get("slack")) or 0.0) < 0.0]
            fail_mx, fail_my = point_median(failing, "end_tile_x", "end_tile_y")
            all_mx, all_my = point_median(rows, "end_tile_x", "end_tile_y")
            fallback = not failing
            if fallback:
                fail_mx, fail_my = all_mx, all_my
            disp_x, disp_y = point_dispersion(failing or rows, "end_tile_x", "end_tile_y")
            x2 = sum(1 for row in failing if endpoint_clock_region(row) == "X2Y1")
            x3 = sum(1 for row in failing if endpoint_clock_region(row) == "X3Y1")
            total_region = x2 + x3
            item = {
                "bit": bit,
                "producer_tile_x": fnum(producer.get("tile_x")),
                "producer_tile_y": fnum(producer.get("tile_y")),
                "producer_clock_region": producer.get("clock_region") or "UNKNOWN",
                "upstream_source_tile_x": fnum(upstream.get("start_tile_x")),
                "upstream_source_tile_y": fnum(upstream.get("start_tile_y")),
                "upstream_slack": fnum(upstream.get("slack")),
                "upstream_source_family": upstream.get("source_family") or "UNKNOWN",
                "downstream_path_count": len(rows),
                "downstream_failing_count": len(failing),
                "x2y1_count": x2,
                "x3y1_count": x3,
                "x2y1_fraction": x2 / total_region if total_region else 0.0,
                "x3y1_fraction": x3 / total_region if total_region else 0.0,
                "downstream_fail_median_x": fail_mx,
                "downstream_fail_median_y": fail_my,
                "downstream_all_median_x": all_mx,
                "downstream_all_median_y": all_my,
                "downstream_fail_dispersion_x": disp_x,
                "downstream_fail_dispersion_y": disp_y,
                "fail_feature_fallback": fallback,
            }
            features[bit] = item
            writer.writerow(item)

    subsets = make_subsets(features)
    with (args.out_dir / "g06_subset_definitions.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = ["subset_id", "moved_bit_count", "bit_list", "bit_list_sha256", "assignment_rule"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for name, item in subsets.items():
            writer.writerow({
                "subset_id": name,
                "moved_bit_count": len(item["bits"]),
                "bit_list": ",".join(str(bit) for bit in item["bits"]),
                "bit_list_sha256": item["bit_list_sha256"],
                "assignment_rule": item["rule"],
            })

    producer_sites = [parse_slice(row.get("loc")) for row in producer_rows]
    producer_sites = [point for point in producer_sites if point is not None]
    producer_bbox = {
        "x_min": min(point[0] for point in producer_sites),
        "x_max": max(point[0] for point in producer_sites),
        "y_min": min(point[1] for point in producer_sites),
        "y_max": max(point[1] for point in producer_sites),
    }
    site_points = [parse_slice(row.get("site")) for row in site_rows]
    site_points = [point for point in site_points if point is not None]
    if not site_points:
        raise SystemExit("candidate site inventory has no usable sites")
    site_x_min = min(point[0] for point in site_points)
    site_x_max = max(point[0] for point in site_points)
    site_y_min = min(point[1] for point in site_points)
    site_y_max = max(point[1] for point in site_points)

    candidates: list[dict[str, object]] = []
    for anchor_x in range(ANCHOR_X_MIN, ANCHOR_X_MAX + 1, ANCHOR_X_STEP):
        for anchor_y in range(ANCHOR_Y_MIN, ANCHOR_Y_MAX + 1, ANCHOR_Y_STEP):
            region = {
                "x_min": anchor_x - WINDOW_HALF_X,
                "x_max": anchor_x + WINDOW_HALF_X,
                "y_min": anchor_y - WINDOW_HALF_Y,
                "y_max": anchor_y + WINDOW_HALF_Y,
            }
            region_rows = [
                row for row in site_rows
                if (point := parse_slice(row.get("site"))) is not None
                and region["x_min"] <= point[0] <= region["x_max"]
                and region["y_min"] <= point[1] <= region["y_max"]
            ]
            tile_points = [row_point(row, "tile_x", "tile_y") for row in region_rows]
            tile_points = [point for point in tile_points if point is not None]
            candidate_tile = (
                median_or_none([point[0] for point in tile_points]),
                median_or_none([point[1] for point in tile_points]),
            ) if tile_points else None
            candidate_id = f"A_X{anchor_x:03d}_Y{anchor_y:03d}"
            candidates.append({
                "candidate_id": candidate_id,
                "anchor_x": anchor_x,
                "anchor_y": anchor_y,
                "region": region,
                "region_rows": region_rows,
                "candidate_tile": candidate_tile,
                "coverage_ratio": len(region_rows) / ((2 * WINDOW_HALF_X + 1) * (2 * WINDOW_HALF_Y + 1)),
            })

    with (args.out_dir / "g06_candidate_universe.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = [
            "candidate_id", "anchor_x", "anchor_y", "region_x_min", "region_x_max", "region_y_min", "region_y_max",
            "candidate_tile_x", "candidate_tile_y", "coverage_ratio", "site_count", "clock_regions",
            "legal_ff_capacity", "available_ff_capacity", "occupied_ff", "projected_ff_utilization",
            "basic_geometry_pass", "basic_rejection_reason",
        ]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for candidate in candidates:
            region_rows = candidate["region_rows"]
            assert isinstance(region_rows, list)
            tile = candidate["candidate_tile"]
            capacity = site_capacity(region_rows, EXPECTED_BITS)
            reasons = []
            if candidate["coverage_ratio"] < MIN_SITE_COVERAGE:
                reasons.append("site_coverage_below_95pct")
            if (capacity["available_ff_capacity_reference"] or 0) < MIN_AVAILABLE_FF_HEADROOM:
                reasons.append("ff_headroom_below_128")
            util = capacity["projected_ff_utilization_reference"]
            if util is None or util > MAX_PROJECTED_FF_UTILIZATION:
                reasons.append("projected_ff_utilization_above_0.50_or_unknown")
            writer.writerow({
                "candidate_id": candidate["candidate_id"], "anchor_x": candidate["anchor_x"], "anchor_y": candidate["anchor_y"],
                "region_x_min": candidate["region"]["x_min"], "region_x_max": candidate["region"]["x_max"],
                "region_y_min": candidate["region"]["y_min"], "region_y_max": candidate["region"]["y_max"],
                "candidate_tile_x": tile[0] if tile else None, "candidate_tile_y": tile[1] if tile else None,
                "coverage_ratio": candidate["coverage_ratio"], "site_count": capacity["site_count"],
                "clock_regions": json.dumps(capacity["clock_regions"], sort_keys=True),
                "legal_ff_capacity": capacity["legal_ff_capacity"], "available_ff_capacity": capacity["available_ff_capacity_reference"],
                "occupied_ff": capacity["occupied_ff"], "projected_ff_utilization": capacity["projected_ff_utilization_reference"],
                "basic_geometry_pass": not reasons and tile is not None, "basic_rejection_reason": ";".join(reasons),
            })

    csv_rows: list[dict[str, object]] = []
    for candidate in candidates:
        region_rows = candidate["region_rows"]
        assert isinstance(region_rows, list)
        for subset_id, subset in subsets.items():
            moved_bits = set(subset["bits"])
            tile = candidate["candidate_tile"]
            assert tile is None or (isinstance(tile, tuple) and len(tile) == 2)
            capacity = site_capacity(region_rows, len(moved_bits))
            basic_reasons = []
            coverage_pass = candidate["coverage_ratio"] >= MIN_SITE_COVERAGE
            headroom_pass = (capacity["available_ff_capacity_reference"] or 0) >= MIN_AVAILABLE_FF_HEADROOM
            util = capacity["projected_ff_utilization_reference"]
            util_pass = util is not None and util <= MAX_PROJECTED_FF_UTILIZATION
            if not coverage_pass:
                basic_reasons.append("site_coverage_below_95pct")
            if not headroom_pass:
                basic_reasons.append("ff_headroom_below_128")
            if not util_pass:
                basic_reasons.append("projected_ff_utilization_above_0.50_or_unknown")
            basic_pass = not basic_reasons and tile is not None

            u_neg_metric = metric_for_rows(u_neg, moved_bits, tile, "start_tile_x", "start_tile_y", "end_tile_x", "end_tile_y")
            u_pass_metric = metric_for_rows(u_pass, moved_bits, tile, "start_tile_x", "start_tile_y", "end_tile_x", "end_tile_y")
            d_neg_metric = metric_for_rows(d_neg, moved_bits, tile, "start_tile_x", "start_tile_y", "end_tile_x", "end_tile_y")
            d_near_metric = metric_for_rows(d_near, moved_bits, tile, "start_tile_x", "start_tile_y", "end_tile_x", "end_tile_y")
            d_all_metric = metric_for_rows(data_rows, moved_bits, tile, "start_tile_x", "start_tile_y", "end_tile_x", "end_tile_y")
            row: dict[str, object] = {
                "candidate_id": candidate["candidate_id"],
                "anchor_x": candidate["anchor_x"],
                "anchor_y": candidate["anchor_y"],
                "region_x_min": candidate["region"]["x_min"],
                "region_x_max": candidate["region"]["x_max"],
                "region_y_min": candidate["region"]["y_min"],
                "region_y_max": candidate["region"]["y_max"],
                "candidate_tile_x": tile[0] if tile else None,
                "candidate_tile_y": tile[1] if tile else None,
                "coverage_ratio": candidate["coverage_ratio"],
                "site_count": capacity["site_count"],
                "legal_ff_capacity": capacity["legal_ff_capacity"],
                "available_ff_capacity": capacity["available_ff_capacity_reference"],
                "occupied_ff": capacity["occupied_ff"],
                "projected_ff_utilization": capacity["projected_ff_utilization_reference"],
                "clock_regions": json.dumps(capacity["clock_regions"], sort_keys=True),
                "control_set_data_available": capacity["control_set_data_available"],
                "control_set_compatibility": "NOT_PROVEN_WITHOUT_MOVED_FF_CONTROL_SET_REPLAY",
                "local_congestion": "NOT_PROVEN_READ_ONLY_SITE_INVENTORY_ONLY",
                "subset_id": subset_id,
                "moved_bit_count": len(moved_bits),
                "bit_list_sha256": subset["bit_list_sha256"],
                "basic_geometry_pass": basic_pass,
                "basic_rejection_reason": ";".join(basic_reasons),
                "candidate_clock_region_crossing_count": sum(
                    1 for bit in moved_bits
                    if features[bit]["producer_clock_region"] not in set(capacity["clock_regions"])
                ),
            }
            flatten_metric("u_neg", u_neg_metric, row)
            flatten_metric("u_pass", u_pass_metric, row)
            flatten_metric("d_neg", d_neg_metric, row)
            flatten_metric("d_near", d_near_metric, row)
            flatten_metric("d_all", d_all_metric, row)
            u_neg_delta = u_neg_metric["delta"]
            u_pass_delta = u_pass_metric["delta"]
            d_neg_delta = d_neg_metric["delta"]
            d_near_delta = d_near_metric["delta"]
            assert isinstance(u_neg_delta, dict) and isinstance(u_pass_delta, dict)
            assert isinstance(d_neg_delta, dict) and isinstance(d_near_delta, dict)
            row["u_neg_no_worsening_proxy"] = (u_neg_delta.get("increase_count") or 0) == 0
            row["u_pass_no_increase_proxy"] = (u_pass_delta.get("increase_count") or 0) == 0
            row["d_neg_improves_proxy"] = (d_neg_delta.get("median") is not None and d_neg_delta["median"] < 0.0)
            row["d_near_nonworsening_proxy"] = (d_near_delta.get("median") is not None and d_near_delta["median"] <= 0.0)
            row["tradeoff_proxy_pass"] = bool(
                basic_pass
                and row["u_neg_no_worsening_proxy"]
                and row["u_pass_no_increase_proxy"]
                and row["d_neg_improves_proxy"]
                and row["d_near_nonworsening_proxy"]
            )
            tradeoff_reasons = []
            if not row["u_neg_no_worsening_proxy"]:
                tradeoff_reasons.append("U_NEG_UPSTREAM_WORSENING")
            if not row["u_pass_no_increase_proxy"]:
                tradeoff_reasons.append("U_PASS_UPSTREAM_INCREASE")
            if not row["d_neg_improves_proxy"]:
                tradeoff_reasons.append("D_NEG_NO_MEDIAN_IMPROVEMENT")
            if not row["d_near_nonworsening_proxy"]:
                tradeoff_reasons.append("D_NEAR_MEDIAN_WORSENING")
            row["tradeoff_rejection_reason"] = ";".join(tradeoff_reasons)
            row["safety_gate_rejection_reason"] = (
                "CONTROL_SET_COMPATIBILITY_UNPROVEN;LOCAL_CONGESTION_UNPROVEN"
                if row["tradeoff_proxy_pass"] else ""
            )
            row["objective_vector"] = json.dumps(objective(row))
            csv_rows.append(row)

    eligible = [row for row in csv_rows if row["basic_geometry_pass"]]
    frontier = []
    for row in eligible:
        if not any(dominates(objective(other), objective(row)) for other in eligible if other is not row):
            frontier.append(row)
    frontier_keys = {(row["candidate_id"], row["subset_id"]) for row in frontier}
    for row in csv_rows:
        row["pareto_frontier"] = (row["candidate_id"], row["subset_id"]) in frontier_keys

    field_order = [
        "candidate_id", "anchor_x", "anchor_y", "region_x_min", "region_x_max", "region_y_min", "region_y_max",
        "candidate_tile_x", "candidate_tile_y", "coverage_ratio", "site_count", "legal_ff_capacity", "available_ff_capacity",
        "occupied_ff", "projected_ff_utilization", "clock_regions", "control_set_data_available", "control_set_compatibility",
        "local_congestion", "candidate_clock_region_crossing_count", "subset_id", "moved_bit_count", "bit_list_sha256",
        "basic_geometry_pass", "basic_rejection_reason", "pareto_frontier", "tradeoff_proxy_pass",
        "tradeoff_rejection_reason", "safety_gate_rejection_reason",
        "u_neg_no_worsening_proxy", "u_pass_no_increase_proxy", "d_neg_improves_proxy", "d_near_nonworsening_proxy",
        "objective_vector",
    ]
    for prefix in ("u_neg", "u_pass", "d_neg", "d_near", "d_all"):
        field_order.extend([f"{prefix}_{key}" for key in ("count", "min", "median", "p90", "p95", "max", "sum", "decrease_count", "increase_count", "unchanged_count")])
        field_order.extend([f"{prefix}_current_slack_{key}" for key in ("count", "min", "median", "p90", "p95", "max", "sum")])
    with (args.out_dir / "g06_candidate_frontier.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=field_order)
        writer.writeheader()
        writer.writerows({key: row.get(key) for key in field_order} for row in csv_rows)

    safe_proxy = [row for row in csv_rows if row["tradeoff_proxy_pass"]]
    unknown_gate_blocked = [row for row in safe_proxy if row["control_set_compatibility"] != "PASS" or row["local_congestion"] != "PASS"]
    if safe_proxy and not unknown_gate_blocked:
        decision = "BALANCED_PRODUCER_CANDIDATE_FOUND"
    elif safe_proxy and unknown_gate_blocked:
        decision = "NO_SAFE_FRONTIER_FOUND"
    else:
        decision = "PRODUCER_ONLY_LOCALITY_NOT_VIABLE"

    upstream_risk_order = sorted(
        csv_rows,
        key=lambda row: (
            int(row.get("u_neg_increase_count") or 10**9),
            float(row.get("u_neg_median") if row.get("u_neg_median") not in (None, "") else 10**9),
            float(row.get("u_neg_p90") if row.get("u_neg_p90") not in (None, "") else 10**9),
            str(row["candidate_id"]), str(row["subset_id"]),
        ),
    )
    downstream_benefit_order = sorted(
        csv_rows,
        key=lambda row: (
            float(row.get("d_neg_median") if row.get("d_neg_median") not in (None, "") else 10**9),
            float(row.get("d_near_median") if row.get("d_near_median") not in (None, "") else 10**9),
            str(row["candidate_id"]), str(row["subset_id"]),
        ),
    )
    best_upstream = upstream_risk_order[0] if upstream_risk_order else {}
    best_downstream = downstream_benefit_order[0] if downstream_benefit_order else {}

    candidate_summary = []
    for candidate in candidates:
        rows = [row for row in csv_rows if row["candidate_id"] == candidate["candidate_id"]]
        candidate_summary.append({
            "candidate_id": candidate["candidate_id"],
            "anchor_x": candidate["anchor_x"],
            "anchor_y": candidate["anchor_y"],
            "region": candidate["region"],
            "coverage_ratio": candidate["coverage_ratio"],
            "site_count": len(candidate["region_rows"]),
            "clock_regions": dict(sorted(Counter(row.get("clock_region") or "UNKNOWN" for row in candidate["region_rows"]).items())),
            "evaluated_subset_count": len(rows),
            "basic_geometry_pass_count": sum(1 for row in rows if row["basic_geometry_pass"]),
            "pareto_frontier_count": sum(1 for row in rows if row["pareto_frontier"]),
        })

    manifest = {
        "stage": "Step12F-P9-R5G-G0.6",
        "name": "Balanced Producer Locality Frontier",
        "status": "CLOSED_READ_ONLY",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": args.baseline_commit,
        "fixed_dcp": {"path": str(args.dcp), "sha256": dcp_sha, "expected_sha256": EXPECTED_DCP_SHA, "sha256_match": dcp_sha == EXPECTED_DCP_SHA},
        "read_only_contract": {
            "rtl_change": "FORBIDDEN", "xdc_change": "FORBIDDEN", "pblock_creation": "FORBIDDEN",
            "opt_design": "FORBIDDEN", "place_design": "FORBIDDEN", "phys_opt_design": "FORBIDDEN",
            "route_design": "FORBIDDEN", "modified_checkpoint": "FORBIDDEN", "implementation_rerun": "FORBIDDEN",
        },
        "tool_context": {"source": "fixed G0/G0.5 extracted DCP evidence", "vivado_context": "2025.2", "part": "xcku5p-ffvb676-2-e", "max_threads": 4},
        "population": {
            "upstream_all": len(upstream_rows), "upstream_negative": len(u_neg), "upstream_nonnegative": len(u_pass),
            "downstream_all": len(data_rows), "downstream_negative": len(d_neg), "downstream_near_zero": len(d_near),
            "producer_bits": len(producer_rows),
        },
        "candidate_universe": {
            "anchor_x": {"min": ANCHOR_X_MIN, "max": ANCHOR_X_MAX, "step": ANCHOR_X_STEP},
            "anchor_y": {"min": ANCHOR_Y_MIN, "max": ANCHOR_Y_MAX, "step": ANCHOR_Y_STEP},
            "window_half_x": WINDOW_HALF_X, "window_half_y": WINDOW_HALF_Y,
            "site_inventory_bbox": {"x_min": site_x_min, "x_max": site_x_max, "y_min": site_y_min, "y_max": site_y_max},
            "producer_bbox": producer_bbox,
            "candidate_count": len(candidates), "candidate_subset_pair_count": len(csv_rows),
            "rule": "fixed 4-site lattice in producer-side/boundary corridor; all pairs emitted",
        },
        "subset_generation": {
            "assignment_features": ["producer tile", "upstream source tile", "failing downstream median", "all downstream median", "destination-region split", "endpoint dispersion"],
            "slack_used_for_assignment": False,
            "subset_count": len(subsets),
            "subsets": {name: {"bits": item["bits"], "bit_list_sha256": item["bit_list_sha256"], "rule": item["rule"]} for name, item in subsets.items()},
        },
        "metrics": {
            "u_neg": "58 currently-negative upstream worst paths",
            "u_pass": "6 currently-nonnegative upstream worst paths",
            "d_neg": "201 currently-negative downstream paths",
            "d_near": "lowest-slack 10% of 3831 nonnegative downstream paths",
            "d_all": "all 4032 downstream destinations",
            "distance_definition": "tile-grid Manhattan delta; negative means shorter after hypothetical move",
            "objective_vector": ["u_neg_median", "u_neg_p90", "u_neg_increase_count", "u_pass_increase_count", "d_neg_median", "d_neg_p90", "d_near_median", "d_all_median", "moved_bit_count"],
            "no_weighted_score": True,
        },
        "frontier": {
            "basic_geometry_eligible_pairs": len(eligible), "pareto_pair_count": len(frontier),
            "tradeoff_proxy_pair_count": len(safe_proxy), "unknown_gate_blocked_pair_count": len(unknown_gate_blocked),
            "minimum_u_neg_increase_count": min((int(row.get("u_neg_increase_count") or 10**9) for row in csv_rows), default=None),
            "best_upstream_risk_pair": {"candidate_id": best_upstream.get("candidate_id"), "subset_id": best_upstream.get("subset_id"), "u_neg_median": best_upstream.get("u_neg_median"), "u_neg_increase_count": best_upstream.get("u_neg_increase_count"), "d_neg_median": best_upstream.get("d_neg_median")},
            "best_downstream_benefit_pair": {"candidate_id": best_downstream.get("candidate_id"), "subset_id": best_downstream.get("subset_id"), "u_neg_median": best_downstream.get("u_neg_median"), "u_neg_increase_count": best_downstream.get("u_neg_increase_count"), "d_neg_median": best_downstream.get("d_neg_median"), "d_near_median": best_downstream.get("d_near_median")},
        },
        "decision": decision,
        "decision_semantics": {
            "BALANCED_PRODUCER_CANDIDATE_FOUND": "non-dominated proxy candidate passes basic geometry and all read-only safety screens; unlocks only later candidate review",
            "PRODUCER_ONLY_LOCALITY_NOT_VIABLE": "complete evaluated frontier has no proxy candidate balancing upstream non-worsening with downstream improvement",
            "NO_SAFE_FRONTIER_FOUND": "proxy tradeoff exists but at least one mandatory read-only safety gate is unknown or fails",
        },
        "limitations": [
            "All distance deltas are placement proxies, not routed timing predictions.",
            "Control-set compatibility is not proven from occupied-site metadata alone.",
            "Local congestion/routing pressure is not available from the fixed inventory and remains unproven.",
            "No candidate pblock or implementation checkpoint was created.",
            "A future approval candidate must be frozen and rechecked after common post-opt DCP creation.",
        ],
        "candidate_summary": candidate_summary,
    }
    (args.out_dir / "G06_FRONTIER_MANIFEST.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    report = [
        "# Step12F-P9-R5G-G0.6 — Balanced Producer Locality Frontier",
        "",
        "Status: `CLOSED_READ_ONLY`; no RTL/XDC/implementation command, pblock, or modified checkpoint was created.",
        "",
        f"- Baseline commit: `{args.baseline_commit}`",
        f"- Fixed routed DCP SHA-256: `{dcp_sha}` (match=True)",
        f"- Decision: **{decision}**",
        "",
        "## Complete populations",
        "",
        f"- Upstream: `{len(upstream_rows)}` total = `{len(u_neg)}` negative + `{len(u_pass)}` nonnegative.",
        f"- Downstream: `{len(data_rows)}` total = `{len(d_neg)}` negative + `{len(d_near)}` near-zero nonnegative subset.",
        "- Every candidate/subset pair is emitted to `g06_candidate_frontier.csv`, including rejected pairs and rejection reasons.",
        "",
        "## Frozen candidate universe",
        "",
        f"- Anchor lattice: X `{ANCHOR_X_MIN}..{ANCHOR_X_MAX}` step `{ANCHOR_X_STEP}`, Y `{ANCHOR_Y_MIN}..{ANCHOR_Y_MAX}` step `{ANCHOR_Y_STEP}`.",
        f"- Window: half-width `{WINDOW_HALF_X}`, half-height `{WINDOW_HALF_Y}`; no window is selected after scoring.",
        f"- Candidates: `{len(candidates)}`; subset definitions: `{len(subsets)}`; evaluated pairs: `{len(csv_rows)}`.",
        "- Subsets are generated deterministically from geometry features; slack is not used for cluster assignment.",
        "",
        "## Frontier decision",
        "",
        f"- Basic geometry-eligible pairs: `{len(eligible)}`.",
        f"- Non-dominated Pareto pairs: `{len(frontier)}`.",
        f"- Proxy tradeoff pairs (upstream non-worsening + downstream improvement): `{len(safe_proxy)}`.",
        f"- Tradeoff pairs blocked by unproven control/congestion gates: `{len(unknown_gate_blocked)}`.",
        f"- Minimum `U_NEG` increase count over all pairs: `{manifest['frontier']['minimum_u_neg_increase_count']}` (zero is required for a no-worsening proxy).",
        f"- Best upstream-risk pair: `{manifest['frontier']['best_upstream_risk_pair']}`.",
        f"- Best downstream-benefit pair: `{manifest['frontier']['best_downstream_benefit_pair']}`.",
        "",
        "The frontier is a multi-objective result; no arbitrary weighted score is used. A distance improvement is not a timing guarantee.",
        "",
        "## Required interpretation",
        "",
        f"**{decision}** is a read-only geometry/risk conclusion only. It does not authorize G1-PREP, G1 CONTROL/TREATMENT, a pblock, or R6 RTL.",
        "Any future `BALANCED_PRODUCER_CANDIDATE_FOUND` must still pass real control-set compatibility and local congestion checks after a common post-opt branch point.",
    ]
    (args.out_dir / "G06_FRONTIER_REPORT.md").write_text("\n".join(report) + "\n", encoding="utf-8")

    provenance = [
        "P9-R5G-G0.6 read-only balanced producer locality frontier",
        f"generated_utc={manifest['generated_at']}",
        f"baseline_commit={args.baseline_commit}",
        f"fixed_dcp_sha256={dcp_sha}",
        "candidate_generation=fixed_lattice_x56_100_step4_y76_116_step4",
        "window=half_x12_half_y16",
        "subset_assignment=deterministic_geometry_features_no_slack_assignment",
        "implementation_commands=FORBIDDEN",
        f"candidate_count={len(candidates)}",
        f"candidate_subset_pair_count={len(csv_rows)}",
        f"pareto_pair_count={len(frontier)}",
        f"decision={decision}",
    ]
    (args.out_dir / "G06_FRONTIER_PROVENANCE.txt").write_text("\n".join(provenance) + "\n", encoding="utf-8")
    status = [
        "P9-R5G-G0.6 CLOSED_READ_ONLY",
        "implementation_commands=FORBIDDEN",
        "rtl_xdc_changes=FORBIDDEN",
        "pblock_creation=FORBIDDEN",
        "modified_checkpoint=FORBIDDEN",
        f"decision={decision}",
    ]
    (args.out_dir / "g06_read_only_status.txt").write_text("\n".join(status) + "\n", encoding="utf-8")

    hash_names = [
        "G06_FRONTIER_MANIFEST.json", "G06_FRONTIER_REPORT.md", "G06_FRONTIER_PROVENANCE.txt",
        "g06_candidate_universe.csv", "g06_candidate_frontier.csv", "g06_subset_definitions.csv", "g06_per_bit_features.csv", "g06_read_only_status.txt",
    ]
    hash_lines = ["P9-R5G-G0.6 evidence SHA-256", ""]
    for name in hash_names:
        path = args.out_dir / name
        hash_lines.append(f"{sha256(path)}  {name}")
    (args.out_dir / "G06_EVIDENCE_SHA256SUMS.txt").write_text("\n".join(hash_lines) + "\n", encoding="utf-8")

    print(json.dumps({"status": "CLOSED_READ_ONLY", "decision": decision, "candidates": len(candidates), "pairs": len(csv_rows), "frontier": len(frontier), "output": str(args.out_dir)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

