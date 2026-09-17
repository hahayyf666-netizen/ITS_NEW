#!/usr/bin/env python3
"""Step12F P9-R5G-G0.6R1 corrected, read-only locality frontier.

This program consumes placement/timing evidence extracted from one fixed routed
DCP.  It never creates a pblock or predicts routed timing.  It is deliberately
separate from the RTL and from the Vivado extraction Tcl.

The R1 implementation fixes the G0.6 upstream orientation bug, keeps a
no-move regression point, evaluates per-bit candidate sites instead of one
region centre, and uses affected-path statistics for subset gates.  If the
provided site inventory does not cover the frozen R1 envelope (for example an
old G0.5 inventory), the report is explicitly INVALID_OR_INCOMPLETE and no
engineering candidate is accepted.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import shutil
import statistics
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path


EXPECTED_DCP_SHA = "D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C"
EXPECTED_BITS = 64
EXPECTED_DESTINATIONS = 4032
EXPECTED_UPSTREAM = 64

# Frozen R1 site/candidate envelope.  Site inventory must be freshly extracted
# from the fixed routed DCP over this envelope; no old narrower inventory is
# silently accepted as complete evidence.
SITE_X_MIN = 40
SITE_X_MAX = 112
SITE_Y_MIN = 55
SITE_Y_MAX = 180
ANCHOR_X_MIN = 40
ANCHOR_X_MAX = 112
ANCHOR_Y_MIN = 56
ANCHOR_Y_MAX = 164
ANCHOR_STEP = 4
WINDOW_HALF_X = 12
WINDOW_HALF_Y = 16
MIN_SITE_COVERAGE = 0.95
MIN_FF_HEADROOM_PER_MOVED_BIT = 2
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


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def parse_bit(row: dict[str, str]) -> int | None:
    for key in ("ingress_bit", "bit_index"):
        value = inum(row.get(key))
        if value is not None:
            return value
    for key in ("start_cell", "startpoint", "endpoint_d", "end_cell", "endpoint"):
        value = row.get(key) or ""
        match = re.search(r"ingress_data_q_reg\[(\d+)\]", value)
        if match:
            return int(match.group(1))
    return None


def parse_site(value: str | None) -> tuple[int, int] | None:
    if not value:
        return None
    match = re.search(r"SLICE_X(\d+)Y(\d+)", value)
    return (int(match.group(1)), int(match.group(2))) if match else None


def tile_point(row: dict[str, str], prefix: str = "") -> tuple[float, float] | None:
    x = fnum(row.get(f"{prefix}tile_x"))
    y = fnum(row.get(f"{prefix}tile_y"))
    if x is not None and y is not None:
        return (x, y)
    tile = row.get(f"{prefix}tile") or row.get(f"{prefix}start_tile") or row.get(f"{prefix}end_tile")
    if tile:
        match = re.search(r"X(\d+)Y(\d+)", tile)
        if match:
            return (float(match.group(1)), float(match.group(2)))
    return None


def distance(a: tuple[float, float] | None, b: tuple[float, float] | None) -> float | None:
    if a is None or b is None:
        return None
    return abs(a[0] - b[0]) + abs(a[1] - b[1])


def delta_stats(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "improved_count": 0,
            "worsened_count": 0,
            "unchanged_count": 0,
            "sum": 0.0,
            "min": None,
            "median": None,
            "p90": None,
            "max": None,
            "worst_increase": 0.0,
        }
    vals = sorted(values)
    return {
        "count": len(vals),
        "improved_count": sum(v < 0 for v in vals),
        "worsened_count": sum(v > 0 for v in vals),
        "unchanged_count": sum(v == 0 for v in vals),
        "sum": sum(vals),
        "min": min(vals),
        "median": statistics.median(vals),
        "p90": vals[min(len(vals) - 1, math.ceil(0.90 * len(vals)) - 1)],
        "max": max(vals),
        "worst_increase": max(0.0, max(vals)),
    }


def delta_stats_fast(values: list[float]) -> dict[str, float | int | None]:
    """Counts/sum for all pairs; quantiles are filled only for viable pairs."""
    if not values:
        return {
            "count": 0, "improved_count": 0, "worsened_count": 0,
            "unchanged_count": 0, "sum": 0.0, "min": None,
            "median": None, "p90": None, "max": None, "worst_increase": 0.0,
        }
    return {
        "count": len(values),
        "improved_count": sum(v < 0 for v in values),
        "worsened_count": sum(v > 0 for v in values),
        "unchanged_count": sum(v == 0 for v in values),
        "sum": sum(values),
        "min": min(values),
        "median": None,
        "p90": None,
        "max": max(values),
        "worst_increase": max(0.0, max(values)),
    }


def scalar_stats(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"count": 0, "min": None, "median": None, "p90": None, "max": None}
    vals = sorted(values)
    return {
        "count": len(vals),
        "min": min(vals),
        "median": statistics.median(vals),
        "p90": vals[min(len(vals) - 1, math.ceil(0.90 * len(vals)) - 1)],
        "max": max(vals),
    }


def list_sha(bits: list[int]) -> str:
    payload = json.dumps(bits, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest().upper()


def site_capacity(rows: list[dict[str, str]], moved_count: int) -> dict[str, object]:
    legal_ff = sum(inum(row.get("legal_ff_bel_count")) or 0 for row in rows)
    occupied_ff = sum(inum(row.get("occupied_ff_count")) or 0 for row in rows)
    available_ff = max(0, legal_ff - occupied_ff)
    projected_ff = occupied_ff + moved_count
    return {
        "site_count": len(rows),
        "legal_ff_capacity": legal_ff,
        "occupied_ff": occupied_ff,
        "available_ff_capacity": available_ff,
        "projected_ff": projected_ff,
        "projected_ff_utilization": projected_ff / legal_ff if legal_ff else None,
        "clock_regions": sorted({row.get("clock_region") or "UNKNOWN" for row in rows}),
        "control_set_data_available": any(row.get("occupied_control_sets") for row in rows),
    }


def path_delta(row: dict[str, str], candidate: tuple[float, float], role: str) -> float | None:
    """Return correct moved-point tile delta for one path.

    Upstream: ingress is the endpoint, therefore source -> candidate.
    Downstream: ingress is the startpoint, therefore candidate -> endpoint.
    """
    start = tile_point(row, "start_")
    end = tile_point(row, "end_")
    old = distance(start, end)
    if old is None:
        return None
    if role == "upstream":
        new = distance(start, candidate)
    elif role == "downstream":
        new = distance(candidate, end)
    else:
        raise ValueError(f"unknown path role {role}")
    return new - old if new is not None else None


def metric(rows: list[dict[str, str]], moved_bits: set[int], assignments: dict[int, tuple[float, float]], role: str) -> dict[str, object]:
    affected: list[float] = []
    global_deltas: list[float] = []
    missing_bits: set[int] = set()
    for row in rows:
        bit = parse_bit(row)
        if bit in moved_bits:
            candidate = assignments.get(bit)
            if candidate is None:
                missing_bits.add(bit if bit is not None else -1)
                continue
            delta = path_delta(row, candidate, role)
            if delta is None:
                continue
            affected.append(delta)
            global_deltas.append(delta)
        else:
            # Unmoved paths have zero hypothetical geometry delta.
            global_deltas.append(0.0)
    return {
        "affected": delta_stats(affected),
        "global": delta_stats(global_deltas),
        "missing_bits": sorted(x for x in missing_bits if x >= 0),
    }


def objective_tuple(item: dict[str, object]) -> tuple[float, ...]:
    def value(key: str) -> float:
        v = item.get(key)
        return float(v) if isinstance(v, (int, float)) else 0.0

    return (
        value("u_neg_delta"),
        value("u_pass_delta"),
        value("d_neg_median"),
        value("d_near_median"),
        value("d_neg_sum"),
        value("site_x"),
        value("site_y"),
    )


def risk_objective_tuple(item: dict[str, object]) -> tuple[float, ...]:
    """Risk-only Pareto objective; site coordinates are not risk dimensions."""
    def value(key: str) -> float:
        v = item.get(key)
        return float(v) if isinstance(v, (int, float)) else 0.0

    return (
        value("u_neg_delta"),
        value("u_pass_delta"),
        value("d_neg_median"),
        value("d_near_median"),
        value("d_neg_sum"),
    )


def dominates(left: tuple[float, ...], right: tuple[float, ...]) -> bool:
    return all(a <= b for a, b in zip(left, right)) and any(a < b for a, b in zip(left, right))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--g0-dir", required=True, type=Path)
    parser.add_argument("--g05-dir", required=True, type=Path)
    parser.add_argument("--dcp", required=True, type=Path)
    parser.add_argument("--site-inventory", required=True, type=Path)
    parser.add_argument("--inventory-source", required=True)
    parser.add_argument("--baseline-commit", required=True)
    parser.add_argument("--out-dir", required=True, type=Path)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    dcp_sha = sha256(args.dcp)
    if dcp_sha != EXPECTED_DCP_SHA:
        raise SystemExit(f"fixed DCP SHA mismatch: {dcp_sha} != {EXPECTED_DCP_SHA}")

    g0_paths = read_csv(args.g0_dir / "g0_ingress_inputmem_paths.csv")
    producer_rows = read_csv(args.g05_dir / "g05_producer_inventory.csv")
    upstream_rows = read_csv(args.g05_dir / "g05_upstream_paths.csv")
    site_rows = read_csv(args.site_inventory)
    vivado_executable = shutil.which("vivado") or shutil.which("vivado.bat")
    data_rows = [row for row in g0_paths if row.get("source_family") == "ingress_data_q_reg"]
    if len(data_rows) != EXPECTED_DESTINATIONS:
        raise SystemExit(f"expected {EXPECTED_DESTINATIONS} downstream rows, got {len(data_rows)}")
    if len(producer_rows) != EXPECTED_BITS or len(upstream_rows) != EXPECTED_UPSTREAM:
        raise SystemExit("producer/upstream population mismatch")

    producer_by_bit = {inum(row.get("bit_index")): row for row in producer_rows}
    upstream_by_bit = {parse_bit(row): row for row in upstream_rows}
    downstream_by_bit: dict[int, list[dict[str, str]]] = defaultdict(list)
    for row in data_rows:
        bit = parse_bit(row)
        if bit is not None:
            downstream_by_bit[bit].append(row)

    d_neg = [row for row in data_rows if (fnum(row.get("slack")) or 0.0) < 0.0]
    d_pass = [row for row in data_rows if (fnum(row.get("slack")) or 0.0) >= 0.0]
    d_near = sorted(d_pass, key=lambda row: (fnum(row.get("slack")) or 0.0, row.get("endpoint", "")))[: max(1, math.ceil(len(d_pass) * 0.10))]
    u_neg = [row for row in upstream_rows if (fnum(row.get("slack")) or 0.0) < 0.0]
    u_pass = [row for row in upstream_rows if (fnum(row.get("slack")) or 0.0) >= 0.0]

    producer_points: dict[int, tuple[float, float]] = {}
    producer_sites: dict[int, tuple[int, int] | None] = {}
    for bit, row in producer_by_bit.items():
        if bit is None:
            continue
        point = tile_point(row)
        if point is not None:
            producer_points[bit] = point
        producer_sites[bit] = parse_site(row.get("site") or row.get("loc"))

    site_by_name: dict[str, dict[str, str]] = {}
    for row in site_rows:
        site = row.get("site") or row.get("loc") or ""
        if site:
            site_by_name[site] = row
    site_rows = list(site_by_name.values())
    site_points = {row.get("site", ""): tile_point(row) for row in site_rows}
    site_points = {name: point for name, point in site_points.items() if point is not None}
    site_sitepoints = {row.get("site", ""): parse_site(row.get("site") or row.get("loc")) for row in site_rows}
    site_sitepoints = {name: point for name, point in site_sitepoints.items() if point is not None}

    inv_x = [p[0] for p in site_sitepoints.values()]
    inv_y = [p[1] for p in site_sitepoints.values()]
    inventory_bbox = {
        "x_min": min(inv_x) if inv_x else None,
        "x_max": max(inv_x) if inv_x else None,
        "y_min": min(inv_y) if inv_y else None,
        "y_max": max(inv_y) if inv_y else None,
    }
    required_bbox = {"x_min": SITE_X_MIN, "x_max": SITE_X_MAX, "y_min": SITE_Y_MIN, "y_max": SITE_Y_MAX}
    inventory_complete = bool(inv_x and inv_y) and all(
        inventory_bbox[key] <= required_bbox[key] if key.endswith("min") else inventory_bbox[key] >= required_bbox[key]
        for key in required_bbox
    )
    producer_bbox = {
        "x_min": min((p[0] for p in producer_sites.values() if p), default=None),
        "x_max": max((p[0] for p in producer_sites.values() if p), default=None),
        "y_min": min((p[1] for p in producer_sites.values() if p), default=None),
        "y_max": max((p[1] for p in producer_sites.values() if p), default=None),
    }
    producer_bbox_covered = bool(inv_x and inv_y) and all(
        inventory_bbox[key] <= producer_bbox[key] if key.endswith("min") else inventory_bbox[key] >= producer_bbox[key]
        for key in producer_bbox
    )

    # Run the mandatory direction regressions before any expensive frontier
    # enumeration.  If an old/narrow inventory is supplied, emit an explicit
    # incomplete audit and stop here; do not spend time producing a partial
    # frontier that could be mistaken for the final R1 result.
    early_no_move_checks: list[dict[str, object]] = []
    early_no_move_pass = True
    for bit in range(EXPECTED_BITS):
        row = upstream_by_bit.get(bit)
        old = producer_points.get(bit)
        if row is None or old is None:
            early_no_move_pass = False
            continue
        up = path_delta(row, old, "upstream")
        drows = downstream_by_bit.get(bit, [])
        downstream_deltas = [path_delta(item, old, "downstream") for item in drows]
        values = [v for v in [up, *downstream_deltas] if v is not None]
        ok = all(v == 0.0 for v in values)
        early_no_move_pass = early_no_move_pass and ok
        early_no_move_checks.append({"bit": bit, "upstream_delta": up, "downstream_count": len(downstream_deltas), "downstream_nonzero_count": sum(v != 0.0 for v in downstream_deltas if v is not None), "pass": ok})
    early_bit62_check: dict[str, object] = {"pass": False}
    bit62_row = upstream_by_bit.get(62)
    if bit62_row is not None and 62 in producer_points:
        test_candidate = (243.0, 128.0)
        old_dist = distance(tile_point(bit62_row, "start_"), producer_points[62])
        new_dist = distance(tile_point(bit62_row, "start_"), test_candidate)
        delta = new_dist - old_dist if old_dist is not None and new_dist is not None else None
        early_bit62_check = {"old_distance": old_dist, "new_distance": new_dist, "delta": delta, "expected_delta": 12.0, "pass": delta == 12.0}
    early_regression_pass = early_no_move_pass and bool(early_bit62_check.get("pass"))

    if not inventory_complete or not producer_bbox_covered:
        early_manifest = {
            "stage": "Step12F-P9-R5G-G0.6R1",
            "status": "CLOSED_READ_ONLY",
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "baseline_commit": args.baseline_commit,
            "fixed_dcp": {"path": str(args.dcp), "sha256": dcp_sha, "expected_sha256": EXPECTED_DCP_SHA, "sha256_match": True},
            "inventory": {"source": args.inventory_source, "path": str(args.site_inventory), "site_count": len(site_rows), "bbox": inventory_bbox, "required_bbox": required_bbox, "complete_for_r1_envelope": inventory_complete, "producer_bbox": producer_bbox, "producer_bbox_covered": producer_bbox_covered, "fresh_vivado_reextraction_required": True, "vivado_executable_found": bool(vivado_executable), "vivado_executable": vivado_executable},
            "read_only_contract": {"rtl_change": "FORBIDDEN", "xdc_change": "FORBIDDEN", "pblock_creation": "FORBIDDEN", "opt_place_physopt_route": "FORBIDDEN", "modified_checkpoint": "FORBIDDEN"},
            "population": {"upstream_all": len(upstream_rows), "upstream_negative": len(u_neg), "upstream_nonnegative": len(u_pass), "downstream_all": len(data_rows), "downstream_negative": len(d_neg), "downstream_near_zero": len(d_near), "producer_bits": len(producer_rows)},
            "candidate_universe": {"frozen_anchor_x": [ANCHOR_X_MIN, ANCHOR_X_MAX, ANCHOR_STEP], "frozen_anchor_y": [ANCHOR_Y_MIN, ANCHOR_Y_MAX, ANCHOR_STEP], "window_half": [WINDOW_HALF_X, WINDOW_HALF_Y], "enumeration": "NOT_RUN_BECAUSE_REQUIRED_INVENTORY_INCOMPLETE"},
            "regressions": {"no_move": {"pass": early_no_move_pass, "checks": early_no_move_checks}, "bit62": early_bit62_check, "all_pass": early_regression_pass},
            "subset_generation": {"status": "NOT_RUN_BECAUSE_REQUIRED_INVENTORY_INCOMPLETE"},
            "geometry_model": {"per_bit_candidate_site_metrics": "NOT_RUN", "candidate_site_status": "GEOMETRIC_PROXY_NOT_PROVEN_LEGAL_PLACEMENT"},
            "frontier": {"status": "NOT_RUN", "pair_count": 0},
            "decision": "R1_INVALID_OR_INCOMPLETE",
            "decision_semantics": {"R1_INVALID_OR_INCOMPLETE": "required expanded site inventory is unavailable or does not cover the frozen R1 envelope"},
            "limitations": ["legacy G0.5 inventory was intentionally not treated as R1 evidence", "fresh Vivado extraction over SLICE_X40..X112/Y55..Y180 is required", "no implementation command was run"],
        }
        out = args.out_dir
        (out / "G06R1_FRONTIER_MANIFEST.json").write_text(json.dumps(early_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (out / "G06R1_FRONTIER_REPORT.md").write_text("\n".join([
            "# Step12F-P9-R5G-G0.6R1 — Corrected Balanced Producer Locality Frontier", "",
            "Status: `CLOSED_READ_ONLY`; decision: **R1_INVALID_OR_INCOMPLETE**", "",
            f"- Fixed DCP SHA-256: `{dcp_sha}` (match=True)",
            f"- Inventory source: `{args.inventory_source}`",
            f"- Inventory bbox: `{inventory_bbox}`; required bbox: `{required_bbox}`",
            f"- Inventory complete: `{inventory_complete}`; producer bbox covered: `{producer_bbox_covered}`",
            f"- Vivado executable available for fresh extraction: `{bool(vivado_executable)}`",
            f"- NO_MOVE_REFERENCE regression: `{early_no_move_pass}`",
            f"- bit 62 (+12 tiles) regression: `{early_bit62_check.get('pass')}` (observed `{early_bit62_check.get('delta')}`)",
            "",
            "No frontier was generated because the supplied inventory is the legacy G0.5 range and does not cover the frozen R1 envelope. Run the read-only Vivado extraction Tcl, then rerun this script with the fresh inventory.",
        ]) + "\n", encoding="utf-8")
        (out / "G06R1_READ_ONLY_STATUS.txt").write_text("\n".join([
            "status=CLOSED_READ_ONLY", "decision=R1_INVALID_OR_INCOMPLETE", f"dcp_sha256={dcp_sha}", f"inventory_complete={inventory_complete}", f"producer_bbox_covered={producer_bbox_covered}", f"regression_pass={early_regression_pass}", "fresh_vivado_reextraction=REQUIRED", f"vivado_executable_found={bool(vivado_executable)}", "rtl_changes=FORBIDDEN", "xdc_changes=FORBIDDEN", "implementation_commands=FORBIDDEN", "g1=NOT_AUTHORIZED", "r6=NOT_AUTHORIZED",
        ]) + "\n", encoding="utf-8")
        (out / "g06r1_no_move_checks.json").write_text(json.dumps(early_no_move_checks, indent=2) + "\n", encoding="utf-8")
        (out / "g06r1_bit62_regression.json").write_text(json.dumps(early_bit62_check, indent=2) + "\n", encoding="utf-8")
        return 0

    # Candidate regions are a fixed lattice, not selected after scoring.
    candidates: list[dict[str, object]] = [{
        "candidate_id": "NO_MOVE_REFERENCE",
        "anchor_x": None,
        "anchor_y": None,
        "region": None,
        "site_rows": [],
        "center_tile": None,
    }]
    expected_window_sites = (2 * WINDOW_HALF_X + 1) * (2 * WINDOW_HALF_Y + 1)
    for anchor_x in range(ANCHOR_X_MIN, ANCHOR_X_MAX + 1, ANCHOR_STEP):
        for anchor_y in range(ANCHOR_Y_MIN, ANCHOR_Y_MAX + 1, ANCHOR_STEP):
            region = {
                "site_x_min": anchor_x - WINDOW_HALF_X,
                "site_x_max": anchor_x + WINDOW_HALF_X,
                "site_y_min": anchor_y - WINDOW_HALF_Y,
                "site_y_max": anchor_y + WINDOW_HALF_Y,
            }
            members = [row for row in site_rows if (point := parse_site(row.get("site") or row.get("loc"))) and region["site_x_min"] <= point[0] <= region["site_x_max"] and region["site_y_min"] <= point[1] <= region["site_y_max"]]
            points = [tile_point(row) for row in members]
            points = [p for p in points if p is not None]
            center = (statistics.median([p[0] for p in points]), statistics.median([p[1] for p in points])) if points else None
            candidates.append({
                "candidate_id": f"R1_X{anchor_x:03d}_Y{anchor_y:03d}",
                "anchor_x": anchor_x,
                "anchor_y": anchor_y,
                "region": region,
                "site_rows": members,
                "center_tile": center,
                "coverage_ratio": len(members) / expected_window_sites,
            })

    # Corrected per-bit site metrics.  All values are geometric proxies.
    site_metrics: dict[int, dict[str, dict[str, object]]] = defaultdict(dict)
    for bit in range(EXPECTED_BITS):
        urow = upstream_by_bit.get(bit)
        drows = downstream_by_bit.get(bit, [])
        for site_name, candidate in site_points.items():
            up_point = tile_point(urow, "start_") if urow else None
            old_point = producer_points.get(bit)
            site_item = {"site": site_name, "site_x": site_sitepoints[site_name][0], "site_y": site_sitepoints[site_name][1]}
            up_delta = (distance(up_point, candidate) - distance(up_point, old_point)) if distance(up_point, candidate) is not None and distance(up_point, old_point) is not None else None
            d_deltas = [path_delta(row, candidate, "downstream") for row in drows]
            d_deltas = [d for d in d_deltas if d is not None]
            d_neg_deltas = [path_delta(row, candidate, "downstream") for row in drows if (fnum(row.get("slack")) or 0.0) < 0.0]
            d_neg_deltas = [d for d in d_neg_deltas if d is not None]
            d_near_deltas = [path_delta(row, candidate, "downstream") for row in drows if row in d_near]
            d_near_deltas = [d for d in d_near_deltas if d is not None]
            up_pass_delta = None
            if urow and (fnum(urow.get("slack")) or 0.0) >= 0.0:
                up_pass_delta = up_delta
            site_item.update({
                "u_neg_delta": up_delta if urow and (fnum(urow.get("slack")) or 0.0) < 0.0 else 0.0,
                "u_pass_delta": up_pass_delta if up_pass_delta is not None else 0.0,
                "d_neg_median": statistics.median(d_neg_deltas) if d_neg_deltas else 0.0,
                "d_neg_sum": sum(d_neg_deltas),
                "d_near_median": statistics.median(d_near_deltas) if d_near_deltas else 0.0,
                "d_all_median": statistics.median(d_deltas) if d_deltas else 0.0,
                "d_neg_metric": delta_stats(d_neg_deltas),
                "d_near_metric": delta_stats(d_near_deltas),
                # Keep raw per-bit values so pair evaluation does not repeat
                # the same 201/384 path-distance loops for every subset.
                "_d_neg_values": d_neg_deltas,
                "_d_near_values": d_near_deltas,
                "_d_all_values": d_deltas,
                "safe_site_proxy": bool(
                    up_delta is not None
                    and up_delta <= 0.0
                    and (up_pass_delta is None or up_pass_delta <= 0.0)
                    and d_neg_deltas
                    and sum(d_neg_deltas) < 0.0
                    and all(d <= 0.0 for d in d_near_deltas)
                ),
            })
            site_metrics[bit][site_name] = site_item

        # Mark geometric Pareto sites for this bit.
        items = list(site_metrics[bit].values())
        # Collapse duplicate risk vectors before the dominance test.  All
        # sites sharing a non-dominated vector remain Pareto members, while
        # avoiding an unnecessary O(number_of_sites^2) comparison explosion
        # on the regular SLICE lattice.
        vector_to_items: dict[tuple[float, ...], list[dict[str, object]]] = defaultdict(list)
        for item in items:
            vector_to_items[risk_objective_tuple(item)].append(item)
        vectors = list(vector_to_items)
        non_dominated_vectors = {
            vector for vector in vectors
            if not any(dominates(other, vector) for other in vectors if other != vector)
        }
        for vector, vector_items in vector_to_items.items():
            for item in vector_items:
                item["pareto_member"] = vector in non_dominated_vectors

    # Frozen deterministic subsets derived from per-bit site evidence.
    subset_specs: dict[str, list[int]] = {
        "ALL_64": list(range(EXPECTED_BITS)),
        "SAFE_BITS_ANY_SITE": sorted(bit for bit in range(EXPECTED_BITS) if any(item["safe_site_proxy"] for item in site_metrics[bit].values())),
        "PARETO_BITS_ANY_SITE": sorted(bit for bit in range(EXPECTED_BITS) if any(item["pareto_member"] for item in site_metrics[bit].values())),
    }
    for bit in range(EXPECTED_BITS):
        subset_specs[f"BIT_{bit:02d}_SINGLETON"] = [bit]
    # The singleton set plus the per-bit-derived aggregate sets are the
    # bounded R1 subset search.  Region membership is still evaluated for
    # every candidate/bit assignment; emitting every distinct region bitset
    # would create an unbounded cartesian product without adding evidence
    # beyond the singleton and aggregate checks.

    # Precompute the deterministic best site per candidate-region/bit once.
    # Without this cache, re-scanning every site for every subset would make
    # the read-only census needlessly quadratic in the number of pairs.
    best_site_by_candidate: dict[str, dict[int, dict[str, object]]] = {}
    for candidate in candidates:
        cid = str(candidate["candidate_id"])
        region_sites = {row.get("site", ""): row for row in candidate["site_rows"]}
        best_site_by_candidate[cid] = {}
        if cid == "NO_MOVE_REFERENCE":
            continue
        for bit in range(EXPECTED_BITS):
            eligible = [item for site, item in site_metrics[bit].items() if site in region_sites]
            if eligible:
                best_site_by_candidate[cid][bit] = min(eligible, key=objective_tuple)

    # Evaluate candidate/subset pairs with the cached per-bit assignments.
    def aggregate_assigned(kind: str, moved: set[int], assignment_sites: dict[int, str]) -> tuple[list[float], list[int]]:
        values: list[float] = []
        missing: list[int] = []
        for bit in sorted(moved):
            site_name = assignment_sites.get(bit)
            if site_name is None or site_name not in site_metrics[bit]:
                missing.append(bit)
                continue
            item = site_metrics[bit][site_name]
            if kind == "u_neg":
                if bit in u_neg_bits:
                    values.append(float(item["u_neg_delta"]))
            elif kind == "u_pass":
                if bit in u_pass_bits:
                    values.append(float(item["u_pass_delta"]))
            elif kind == "d_neg":
                values.extend(float(v) for v in item["_d_neg_values"])
            elif kind == "d_near":
                values.extend(float(v) for v in item["_d_near_values"])
        return values, missing

    u_neg_bits = {parse_bit(row) for row in u_neg}
    u_pass_bits = {parse_bit(row) for row in u_pass}
    pair_rows: list[dict[str, object]] = []
    pair_assignments: list[dict[str, object]] = []
    for candidate in candidates:
        cid = str(candidate["candidate_id"])
        region_sites = {row.get("site", ""): row for row in candidate["site_rows"]}
        center = candidate.get("center_tile")
        for subset_id, bits in subset_specs.items():
            moved = set(bits)
            assignments: dict[int, tuple[float, float]] = {}
            assignment_sites: dict[int, str] = {}
            if cid == "NO_MOVE_REFERENCE":
                for bit in moved:
                    if bit in producer_points:
                        assignments[bit] = producer_points[bit]
                        assignment_sites[bit] = "CURRENT_PRODUCER"
            else:
                for bit in moved:
                    chosen = best_site_by_candidate[cid].get(bit)
                    if chosen is not None:
                        site_name = str(chosen["site"])
                        assignments[bit] = site_points[site_name]
                        assignment_sites[bit] = site_name
            assignment_payload = [f"{bit}:{assignment_sites.get(bit, 'MISSING')}" for bit in sorted(moved)]
            assignment_sha = hashlib.sha256("|".join(assignment_payload).encode("utf-8")).hexdigest().upper()
            u_neg_values, u_neg_missing = aggregate_assigned("u_neg", moved, assignment_sites)
            u_pass_values, u_pass_missing = aggregate_assigned("u_pass", moved, assignment_sites)
            d_neg_values, d_neg_missing = aggregate_assigned("d_neg", moved, assignment_sites)
            d_near_values, d_near_missing = aggregate_assigned("d_near", moved, assignment_sites)
            u_neg_aff = delta_stats_fast(u_neg_values)
            u_pass_aff = delta_stats_fast(u_pass_values)
            d_neg_aff = delta_stats_fast(d_neg_values)
            d_near_aff = delta_stats_fast(d_near_values)
            missing = sorted(set(u_neg_missing + u_pass_missing + d_neg_missing + d_near_missing))
            cap = site_capacity(list(region_sites.values()), len(moved))
            coverage = float(candidate.get("coverage_ratio", 1.0 if cid == "NO_MOVE_REFERENCE" else 0.0))
            basic_pass = cid == "NO_MOVE_REFERENCE" or (
                inventory_complete
                and coverage >= MIN_SITE_COVERAGE
                and (cap["available_ff_capacity"] or 0) >= MIN_FF_HEADROOM_PER_MOVED_BIT * len(moved)
                and (cap["projected_ff_utilization"] is not None and cap["projected_ff_utilization"] <= MAX_PROJECTED_FF_UTILIZATION)
                and not missing
            )
            safety_pass = (
                not missing
                and int(u_neg_aff["worsened_count"] or 0) == 0
                and int(u_pass_aff["worsened_count"] or 0) == 0
                and int(d_neg_aff["worsened_count"] or 0) == 0
                and (cid == "NO_MOVE_REFERENCE" or int(d_neg_aff["improved_count"] or 0) > 0)
                and int(d_near_aff["worsened_count"] or 0) == 0
            )
            # Quantiles are audit fields, but sorting hundreds of paths for
            # every rejected pair is wasteful.  Compute them after the cheap
            # affected-population gates; rejected/incomplete pairs retain an
            # explicit null quantile rather than silently using a global zero.
            if basic_pass and safety_pass:
                u_neg_aff = delta_stats(u_neg_values)
                u_pass_aff = delta_stats(u_pass_values)
                d_neg_aff = delta_stats(d_neg_values)
                d_near_aff = delta_stats(d_near_values)
            global_u_neg = delta_stats_fast(u_neg_values + [0.0] * max(0, len(u_neg) - len(u_neg_values)))
            global_d_neg = delta_stats_fast(d_neg_values + [0.0] * max(0, len(d_neg) - len(d_neg_values)))
            global_d_near = delta_stats_fast(d_near_values + [0.0] * max(0, len(d_near) - len(d_near_values)))
            if basic_pass and safety_pass:
                global_u_neg = delta_stats(u_neg_values + [0.0] * max(0, len(u_neg) - len(u_neg_values)))
                global_d_neg = delta_stats(d_neg_values + [0.0] * max(0, len(d_neg) - len(d_neg_values)))
                global_d_near = delta_stats(d_near_values + [0.0] * max(0, len(d_near) - len(d_near_values)))
            intervention_pass = cid != "NO_MOVE_REFERENCE" and basic_pass and safety_pass
            row = {
                "candidate_id": cid,
                "subset_id": subset_id,
                "moved_bit_count": len(moved),
                "bit_list_sha256": list_sha(sorted(moved)),
                "candidate_center_tile_x": center[0] if center else None,
                "candidate_center_tile_y": center[1] if center else None,
                "coverage_ratio": coverage,
                "inventory_complete": inventory_complete,
                "producer_bbox_covered": producer_bbox_covered,
                "assigned_site_count": len(assignments),
                "missing_assignment_count": len(missing),
                "assignment_sha256": assignment_sha,
                "basic_geometry_pass": basic_pass,
                "affected_u_neg": u_neg_aff,
                "affected_u_pass": u_pass_aff,
                "affected_d_neg": d_neg_aff,
                "affected_d_near": d_near_aff,
                "global_u_neg": global_u_neg,
                "global_d_neg": global_d_neg,
                "global_d_near": global_d_near,
                "safety_gate_pass": safety_pass,
                "intervention_pass": intervention_pass,
                "rejection_reason": "" if intervention_pass else ";".join([
                    reason for reason, failed in (
                        ("INVENTORY_INCOMPLETE", not inventory_complete and cid != "NO_MOVE_REFERENCE"),
                        ("MISSING_PER_BIT_ASSIGNMENT", bool(missing)),
                        ("U_NEG_WORSENING", int(u_neg_aff["worsened_count"] or 0) > 0),
                        ("U_PASS_WORSENING", int(u_pass_aff["worsened_count"] or 0) > 0),
                        ("D_NEG_WORSENING", int(d_neg_aff["worsened_count"] or 0) > 0),
                        ("D_NEG_NO_AFFECTED_IMPROVEMENT", cid != "NO_MOVE_REFERENCE" and int(d_neg_aff["improved_count"] or 0) == 0),
                        ("D_NEAR_WORSENING", int(d_near_aff["worsened_count"] or 0) > 0),
                        ("NO_MOVE_REFERENCE", cid == "NO_MOVE_REFERENCE"),
                    ) if failed
                ]),
            }
            pair_rows.append(row)
            if intervention_pass or cid == "NO_MOVE_REFERENCE":
                pair_assignments.append({"candidate_id": cid, "subset_id": subset_id, "assignments": assignment_payload, "assignment_sha256": assignment_sha})

    # Direction/unit regressions are mandatory and run independently of the
    # incomplete inventory status.
    no_move_pass = True
    no_move_checks: list[dict[str, object]] = []
    for bit in range(EXPECTED_BITS):
        row = upstream_by_bit.get(bit)
        old = producer_points.get(bit)
        if row is None or old is None:
            no_move_pass = False
            continue
        up = path_delta(row, old, "upstream")
        drows = downstream_by_bit.get(bit, [])
        downstream_deltas = [path_delta(item, old, "downstream") for item in drows]
        values = [v for v in [up, *downstream_deltas] if v is not None]
        ok = all(v == 0.0 for v in values)
        no_move_pass = no_move_pass and ok
        no_move_checks.append({"bit": bit, "upstream_delta": up, "downstream_count": len(downstream_deltas), "downstream_nonzero_count": sum(v != 0.0 for v in downstream_deltas if v is not None), "pass": ok})

    bit62 = upstream_by_bit.get(62)
    bit62_check: dict[str, object] = {"pass": False}
    if bit62 is not None and 62 in producer_points:
        candidate = (243.0, 128.0)
        old_dist = distance(tile_point(bit62, "start_"), producer_points[62])
        new_dist = distance(tile_point(bit62, "start_"), candidate)
        delta = new_dist - old_dist if old_dist is not None and new_dist is not None else None
        bit62_check = {"old_distance": old_dist, "new_distance": new_dist, "delta": delta, "expected_delta": 12.0, "pass": delta == 12.0}
    regression_pass = no_move_pass and bool(bit62_check.get("pass"))

    if not regression_pass or not inventory_complete or not producer_bbox_covered:
        decision = "R1_INVALID_OR_INCOMPLETE"
    elif any(bool(row["intervention_pass"]) for row in pair_rows):
        decision = "BALANCED_PRODUCER_CANDIDATE_FOUND"
    else:
        decision = "NO_BALANCED_CANDIDATE_IN_FROZEN_R1_SEARCH_SPACE"

    valid_pairs = [row for row in pair_rows if row["candidate_id"] != "NO_MOVE_REFERENCE"]
    safe_pairs = [row for row in valid_pairs if row["intervention_pass"]]
    manifest = {
        "stage": "Step12F-P9-R5G-G0.6R1",
        "status": "CLOSED_READ_ONLY",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": args.baseline_commit,
        "fixed_dcp": {"path": str(args.dcp), "sha256": dcp_sha, "expected_sha256": EXPECTED_DCP_SHA, "sha256_match": dcp_sha == EXPECTED_DCP_SHA},
        "inventory": {
            "source": args.inventory_source,
            "path": str(args.site_inventory),
            "site_count": len(site_rows),
            "bbox": inventory_bbox,
            "required_bbox": required_bbox,
            "complete_for_r1_envelope": inventory_complete,
            "producer_bbox": producer_bbox,
            "producer_bbox_covered": producer_bbox_covered,
            "fresh_vivado_reextraction_required": True,
        },
        "read_only_contract": {
            "rtl_change": "FORBIDDEN",
            "xdc_change": "FORBIDDEN",
            "pblock_creation": "FORBIDDEN",
            "opt_place_physopt_route": "FORBIDDEN",
            "modified_checkpoint": "FORBIDDEN",
        },
        "population": {
            "upstream_all": len(upstream_rows), "upstream_negative": len(u_neg), "upstream_nonnegative": len(u_pass),
            "downstream_all": len(data_rows), "downstream_negative": len(d_neg), "downstream_near_zero": len(d_near), "producer_bits": len(producer_rows),
        },
        "candidate_universe": {
            "anchor_x": [ANCHOR_X_MIN, ANCHOR_X_MAX, ANCHOR_STEP],
            "anchor_y": [ANCHOR_Y_MIN, ANCHOR_Y_MAX, ANCHOR_STEP],
            "window_half": [WINDOW_HALF_X, WINDOW_HALF_Y],
            "candidate_count_including_no_move": len(candidates),
            "candidate_count_excluding_no_move": len(candidates) - 1,
            "pair_count": len(pair_rows),
            "no_move_reference_included": True,
        },
        "regressions": {"no_move": {"pass": no_move_pass, "checks": no_move_checks}, "bit62": bit62_check, "all_pass": regression_pass},
        "subset_generation": {
            "count": len(subset_specs),
            "slack_numeric_value_not_used_for_cluster_ranking": True,
            "slack_sign_used_to_define_critical_populations": True,
            "subsets": {name: {"bits": bits, "sha256": list_sha(bits)} for name, bits in subset_specs.items()},
        },
        "geometry_model": {
            "per_bit_candidate_site_metrics": True,
            "per_bit_geometric_pareto": True,
            "candidate_site_status": "GEOMETRIC_PROXY_NOT_PROVEN_LEGAL_PLACEMENT",
            "center_point_proxy_retained_for_comparison": True,
        },
        "frontier": {
            "all_pairs": len(pair_rows),
            "safe_proxy_pairs": len(safe_pairs),
            "inventory_complete": inventory_complete,
            "regression_pass": regression_pass,
        },
        "decision": decision,
        "decision_semantics": {
            "BALANCED_PRODUCER_CANDIDATE_FOUND": "at least one non-NO_MOVE pair passes corrected affected-path gates and complete R1 inventory",
            "NO_BALANCED_CANDIDATE_IN_FROZEN_R1_SEARCH_SPACE": "complete corrected R1 search space has no passing pair; not a global impossibility proof",
            "R1_INVALID_OR_INCOMPLETE": "mandatory regression or required expanded inventory is unavailable/failed",
        },
        "limitations": [
            "tile distance is a placement proxy, not routed timing",
            "candidate sites are geometric proxy sites, not proven legal moved-FF placements",
            "control-set compatibility requires later common post-opt replay",
            "local congestion suitability requires later implementation evidence",
            "no RTL/XDC/implementation command was run",
        ],
    }

    out = args.out_dir
    (out / "G06R1_FRONTIER_MANIFEST.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    with (out / "g06r1_candidate_frontier.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = ["candidate_id", "subset_id", "moved_bit_count", "bit_list_sha256", "candidate_center_tile_x", "candidate_center_tile_y", "coverage_ratio", "inventory_complete", "producer_bbox_covered", "assigned_site_count", "missing_assignment_count", "assignment_sha256", "basic_geometry_pass", "safety_gate_pass", "intervention_pass", "rejection_reason"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in pair_rows:
            writer.writerow({field: row.get(field) for field in fields})
    with (out / "g06r1_pair_assignments.jsonl").open("w", encoding="utf-8") as handle:
        for item in pair_assignments:
            handle.write(json.dumps(item, sort_keys=True) + "\n")
    with (out / "g06r1_per_bit_site_metrics.csv").open("w", newline="", encoding="utf-8") as handle:
        fields = ["bit", "site", "site_x", "site_y", "u_neg_delta", "u_pass_delta", "d_neg_median", "d_neg_sum", "d_near_median", "d_all_median", "safe_site_proxy", "pareto_member"]
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for bit in range(EXPECTED_BITS):
            for item in site_metrics[bit].values():
                writer.writerow({field: item.get(field) for field in fields} | {"bit": bit})
    (out / "g06r1_no_move_checks.json").write_text(json.dumps(no_move_checks, indent=2) + "\n", encoding="utf-8")
    (out / "g06r1_bit62_regression.json").write_text(json.dumps(bit62_check, indent=2) + "\n", encoding="utf-8")
    (out / "G06R1_FRONTIER_REPORT.md").write_text(
        "\n".join([
            "# Step12F-P9-R5G-G0.6R1 — Corrected Balanced Producer Locality Frontier",
            "",
            f"Status: `CLOSED_READ_ONLY`; decision: **{decision}**",
            f"Baseline: `{args.baseline_commit}`",
            f"Fixed DCP SHA-256: `{dcp_sha}` (match=True)",
            "",
            "## Mandatory regressions",
            "",
            f"- NO_MOVE_REFERENCE: `{no_move_pass}`",
            f"- bit 62 source→candidate regression (+12 tiles): `{bit62_check.get('pass')}`; observed delta `{bit62_check.get('delta')}`",
            f"- all regression gates: `{regression_pass}`",
            "",
            "## Population and inventory",
            "",
            f"- Upstream: `{len(upstream_rows)}` total = `{len(u_neg)}` negative + `{len(u_pass)}` nonnegative.",
            f"- Downstream: `{len(data_rows)}` total = `{len(d_neg)}` negative + `{len(d_near)}` near-zero.",
            f"- Site inventory source: `{args.inventory_source}`.",
            f"- Inventory bbox: `{inventory_bbox}`; required R1 bbox: `{required_bbox}`.",
            f"- Inventory complete: `{inventory_complete}`; producer bbox covered: `{producer_bbox_covered}`.",
            "",
            "## Evidence boundary",
            "",
            "Upstream uses source→candidate; downstream uses candidate→destination. Subset gates use affected-path populations. Per-bit assignments use geometric proxy Pareto sites; they are not proven legal placement sites. No implementation command was run.",
            "",
            f"Because inventory completeness and regression status are mandatory, this run cannot authorize G1/R6. Final R1 verdict: `{decision}`.",
        ]) + "\n", encoding="utf-8")
    (out / "G06R1_READ_ONLY_STATUS.txt").write_text("\n".join([
        "status=CLOSED_READ_ONLY",
        f"decision={decision}",
        f"dcp_sha256={dcp_sha}",
        f"inventory_source={args.inventory_source}",
        f"inventory_complete={inventory_complete}",
        f"producer_bbox_covered={producer_bbox_covered}",
        f"regression_pass={regression_pass}",
        "rtl_changes=FORBIDDEN",
        "xdc_changes=FORBIDDEN",
        "implementation_commands=FORBIDDEN",
        "g1=NOT_AUTHORIZED",
        "r6=NOT_AUTHORIZED",
    ]) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
