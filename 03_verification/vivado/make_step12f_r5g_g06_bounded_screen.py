#!/usr/bin/env python3
"""Finite producer-only locality screening for Step12F P9-R5G.

This is intentionally smaller than the historical G0.6 frontier search.  It
uses the fixed R5E routed-DCP timing census and the freshly extracted site
inventory, evaluates four predeclared boundary corridors and eight
predeclared bit subsets, and emits a go/no-go recommendation for one real
CONTROL/TREATMENT implementation experiment.  It never edits RTL/XDC and
never runs Vivado implementation commands.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import re
import statistics
from collections import OrderedDict, defaultdict
from datetime import datetime, timezone
from pathlib import Path


EXPECTED_DCP_SHA = "D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C"
EXPECTED_BITS = 64
EXPECTED_DOWNSTREAM = 4032
EXPECTED_UPSTREAM = 64

# Frozen, deliberately small corridor set near the X2Y2/X2Y1 boundary.  The
# coordinates are SLICE coordinates; the anchor tile is read from the fresh
# inventory, never inferred from a virtual placer.
REGIONS = [
    {"id": "BOUNDARY_X068_Y116", "anchor_x": 68, "anchor_y": 116, "x_min": 56, "x_max": 80, "y_min": 100, "y_max": 132},
    {"id": "BOUNDARY_X072_Y112", "anchor_x": 72, "anchor_y": 112, "x_min": 60, "x_max": 84, "y_min": 96, "y_max": 128},
    {"id": "BOUNDARY_X072_Y116", "anchor_x": 72, "anchor_y": 116, "x_min": 60, "x_max": 84, "y_min": 100, "y_max": 132},
    {"id": "BOUNDARY_X076_Y116", "anchor_x": 76, "anchor_y": 116, "x_min": 64, "x_max": 88, "y_min": 100, "y_max": 132},
]

# These subsets are the deterministic G0.6 definitions.  They are reused as
# a fixed screening set; no subset is selected from the new timing results.
SUBSETS = OrderedDict(
    [
        ("ALL_64", list(range(64))),
        ("DEST_X2Y1_MAJOR", [1, 3, 5, 7, 11, 14, 16, 17, 19, 25, 28, 42, 43, 44, 45, 47, 48, 54, 56, 57, 59, 62]),
        ("DEST_X3Y1_MAJOR", [0, 2, 8, 10, 13, 15, 24, 26, 27, 30, 33, 34, 39, 41, 46, 49, 50, 51, 60, 61]),
        ("DEST_MIXED_OR_OTHER", [4, 6, 9, 12, 18, 20, 21, 22, 23, 29, 31, 32, 35, 36, 37, 38, 40, 52, 53, 55, 58, 63]),
        ("FEATURE_BIN_0", [2, 5, 12, 14, 18, 20, 22, 31, 32, 34, 36, 44, 46, 49, 50, 54]),
        ("FEATURE_BIN_1", [0, 1, 3, 8, 9, 13, 16, 21, 28, 30, 33, 38, 43, 48, 53, 61]),
        ("FEATURE_BIN_2", [10, 11, 15, 17, 25, 26, 27, 35, 37, 40, 41, 45, 47, 51, 58, 63]),
        ("FEATURE_BIN_3", [4, 6, 7, 19, 23, 24, 29, 39, 42, 52, 55, 56, 57, 59, 60, 62]),
    ]
)

# Screening thresholds are fixed before scoring.  They are deliberately
# conservative enough to reject the old whole-64 relocation while allowing a
# low-risk subset to justify exactly one real implementation A/B run.
THRESHOLDS = {
    "u_neg_increase_count_max": 4,
    "u_neg_worst_increase_max": 8.0,
    "u_pass_increase_count_max": 1,
    "u_pass_worst_increase_max": 8.0,
    "d_neg_sum_max": -500.0,
    "d_neg_increase_count_max": 0,
    "d_neg_decrease_count_min": 24,
    "d_near_sum_max": -1000.0,
    "d_near_increase_count_max": 0,
    "d_near_decrease_count_min": 50,
    "max_projected_ff_utilization": 0.50,
    "ff_headroom_per_moved_bit": 2,
}


def fnum(value: str | None) -> float | None:
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def inum(value: str | None) -> int | None:
    number = fnum(value)
    return int(number) if number is not None else None


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


def site_xy(row: dict[str, str]) -> tuple[int, int] | None:
    value = row.get("site") or row.get("loc") or ""
    match = re.search(r"SLICE_X(\d+)Y(\d+)", value)
    return (int(match.group(1)), int(match.group(2))) if match else None


def tile_xy(row: dict[str, str], prefix: str = "") -> tuple[float, float] | None:
    x = fnum(row.get(f"{prefix}tile_x"))
    y = fnum(row.get(f"{prefix}tile_y"))
    if x is not None and y is not None:
        return (x, y)
    tile = row.get(f"{prefix}tile") or ""
    match = re.search(r"X(\d+)Y(\d+)", tile)
    return (float(match.group(1)), float(match.group(2))) if match else None


def distance(left: tuple[float, float] | None, right: tuple[float, float] | None) -> float | None:
    if left is None or right is None:
        return None
    return abs(left[0] - right[0]) + abs(left[1] - right[1])


def stats(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {
            "count": 0,
            "increase_count": 0,
            "decrease_count": 0,
            "unchanged_count": 0,
            "sum": 0.0,
            "median": None,
            "p90": None,
            "max": None,
        }
    ordered = sorted(values)
    return {
        "count": len(values),
        "increase_count": sum(value > 0 for value in values),
        "decrease_count": sum(value < 0 for value in values),
        "unchanged_count": sum(value == 0 for value in values),
        "sum": sum(values),
        "median": statistics.median(ordered),
        "p90": ordered[min(len(ordered) - 1, math.ceil(0.90 * len(ordered)) - 1)],
        "max": max(values),
    }


def bit_hash(bits: list[int]) -> str:
    payload = ",".join(str(bit) for bit in bits).encode("ascii")
    return hashlib.sha256(payload).hexdigest().upper()


def row_delta(row: dict[str, str], current: tuple[float, float], candidate: tuple[float, float], prefix: str) -> float:
    endpoint = tile_xy(row, prefix)
    old_distance = distance(endpoint, current)
    new_distance = distance(endpoint, candidate)
    if old_distance is None or new_distance is None:
        return 0.0
    return new_distance - old_distance


def region_info(region: dict[str, int], site_rows: list[dict[str, str]], moved_count: int) -> dict[str, object]:
    selected = []
    for row in site_rows:
        xy = site_xy(row)
        if xy is None:
            continue
        if region["x_min"] <= xy[0] <= region["x_max"] and region["y_min"] <= xy[1] <= region["y_max"]:
            selected.append(row)
    anchor_name = f"SLICE_X{region['anchor_x']}Y{region['anchor_y']}"
    anchor = next((row for row in selected if (row.get("site") or "") == anchor_name), None)
    if anchor is None:
        anchor = next((row for row in site_rows if (row.get("site") or "") == anchor_name), None)
    center = tile_xy(anchor or {}) if anchor else None
    if center is None:
        points = [tile_xy(row) for row in selected]
        points = [point for point in points if point is not None]
        center = (statistics.median(point[0] for point in points), statistics.median(point[1] for point in points)) if points else None
    legal_ff = sum(inum(row.get("legal_ff_bel_count")) or 0 for row in selected)
    occupied_ff = sum(inum(row.get("occupied_ff_count")) or 0 for row in selected)
    available_ff = legal_ff - occupied_ff
    projected_ff = occupied_ff + moved_count * THRESHOLDS["ff_headroom_per_moved_bit"]
    projected_utilization = projected_ff / legal_ff if legal_ff else 1.0
    return {
        "region_id": region["id"],
        "anchor_site": anchor_name,
        "anchor_tile_x": center[0] if center else None,
        "anchor_tile_y": center[1] if center else None,
        "x_min": region["x_min"],
        "x_max": region["x_max"],
        "y_min": region["y_min"],
        "y_max": region["y_max"],
        "site_count": len(selected),
        "legal_ff_capacity": legal_ff,
        "occupied_ff": occupied_ff,
        "available_ff": available_ff,
        "projected_ff_with_headroom": projected_ff,
        "projected_ff_utilization": projected_utilization,
        "capacity_pass": bool(center) and available_ff >= moved_count * THRESHOLDS["ff_headroom_per_moved_bit"] and projected_utilization <= THRESHOLDS["max_projected_ff_utilization"],
        "center": center,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True, type=Path)
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
    site_rows = read_csv(args.inventory)
    g0_rows = [row for row in read_csv(args.g0_dir / "g0_ingress_inputmem_paths.csv") if row.get("source_family") == "ingress_data_q_reg"]
    upstream_rows = read_csv(args.g05_dir / "g05_upstream_paths.csv")
    producer_rows = read_csv(args.g05_dir / "g05_producer_inventory.csv")
    if len(site_rows) < 1:
        raise SystemExit("empty site inventory")
    if len(g0_rows) != EXPECTED_DOWNSTREAM or len(upstream_rows) != EXPECTED_UPSTREAM or len(producer_rows) != EXPECTED_BITS:
        raise SystemExit(f"population mismatch: downstream={len(g0_rows)} upstream={len(upstream_rows)} producer={len(producer_rows)}")

    producer_by_bit = {parse_bit(row): row for row in producer_rows}
    current_points = {bit: tile_xy(row) for bit, row in producer_by_bit.items() if bit is not None}
    if len(current_points) != EXPECTED_BITS or any(point is None for point in current_points.values()):
        raise SystemExit("producer inventory does not contain all current tile points")

    upstream_by_bit = {parse_bit(row): row for row in upstream_rows}
    if set(upstream_by_bit) != set(range(EXPECTED_BITS)):
        raise SystemExit("upstream inventory does not contain exactly bits 0..63")
    d_pass = [row for row in g0_rows if (fnum(row.get("slack")) or 0.0) >= 0.0]
    near_count = max(1, math.ceil(len(d_pass) * 0.10))
    d_near = sorted(d_pass, key=lambda row: (fnum(row.get("slack")) or 0.0, row.get("endpoint", "")))[:near_count]
    d_neg = [row for row in g0_rows if (fnum(row.get("slack")) or 0.0) < 0.0]
    u_neg = [row for row in upstream_rows if (fnum(row.get("slack")) or 0.0) < 0.0]
    u_pass = [row for row in upstream_rows if (fnum(row.get("slack")) or 0.0) >= 0.0]

    inv_points = [site_xy(row) for row in site_rows]
    inv_points = [point for point in inv_points if point is not None]
    inventory_bbox = {
        "x_min": min(point[0] for point in inv_points),
        "x_max": max(point[0] for point in inv_points),
        "y_min": min(point[1] for point in inv_points),
        "y_max": max(point[1] for point in inv_points),
    }
    inventory_complete = inventory_bbox == {"x_min": 40, "x_max": 112, "y_min": 55, "y_max": 180}

    rows_out: list[dict[str, object]] = []
    region_cache = {region["id"]: region_info(region, site_rows, 64) for region in REGIONS}
    for region in REGIONS:
        for subset_id, bits in SUBSETS.items():
            info = region_cache[region["id"]]
            # Recompute capacity with the actual moved subset size.
            info = region_info(region, site_rows, len(bits))
            center = info["center"]
            if center is None:
                raise SystemExit(f"missing anchor/candidate tile for {region['id']}")

            def moved_delta(row: dict[str, str], prefix: str) -> float:
                bit = parse_bit(row)
                if bit not in bits:
                    return 0.0
                return row_delta(row, current_points[bit], center, prefix)

            u_neg_stats = stats([moved_delta(row, "start_") for row in u_neg])
            u_pass_stats = stats([moved_delta(row, "start_") for row in u_pass])
            d_neg_stats = stats([moved_delta(row, "end_") for row in d_neg])
            d_near_stats = stats([moved_delta(row, "end_") for row in d_near])
            reasons = []
            if not info["capacity_pass"]:
                reasons.append("capacity")
            if u_neg_stats["increase_count"] > THRESHOLDS["u_neg_increase_count_max"]:
                reasons.append("u_neg_increase_count")
            if (u_neg_stats["max"] or 0.0) > THRESHOLDS["u_neg_worst_increase_max"]:
                reasons.append("u_neg_worst_increase")
            if u_pass_stats["increase_count"] > THRESHOLDS["u_pass_increase_count_max"]:
                reasons.append("u_pass_increase_count")
            if (u_pass_stats["max"] or 0.0) > THRESHOLDS["u_pass_worst_increase_max"]:
                reasons.append("u_pass_worst_increase")
            if (d_neg_stats["sum"] or 0.0) > THRESHOLDS["d_neg_sum_max"]:
                reasons.append("d_neg_not_clear")
            if d_neg_stats["increase_count"] > THRESHOLDS["d_neg_increase_count_max"]:
                reasons.append("d_neg_increase")
            if d_neg_stats["decrease_count"] < THRESHOLDS["d_neg_decrease_count_min"]:
                reasons.append("d_neg_too_few_improved")
            if (d_near_stats["sum"] or 0.0) > THRESHOLDS["d_near_sum_max"]:
                reasons.append("d_near_not_clear")
            if d_near_stats["increase_count"] > THRESHOLDS["d_near_increase_count_max"]:
                reasons.append("d_near_increase")
            if d_near_stats["decrease_count"] < THRESHOLDS["d_near_decrease_count_min"]:
                reasons.append("d_near_too_few_improved")
            row = {
                "region_id": region["id"],
                "subset_id": subset_id,
                "moved_bit_count": len(bits),
                "bit_list": ",".join(str(bit) for bit in bits),
                "bit_list_sha256": bit_hash(bits),
                "region_x_min": region["x_min"],
                "region_x_max": region["x_max"],
                "region_y_min": region["y_min"],
                "region_y_max": region["y_max"],
                "candidate_tile_x": center[0],
                "candidate_tile_y": center[1],
                "site_count": info["site_count"],
                "legal_ff_capacity": info["legal_ff_capacity"],
                "occupied_ff": info["occupied_ff"],
                "available_ff": info["available_ff"],
                "projected_ff_utilization": info["projected_ff_utilization"],
                "capacity_pass": info["capacity_pass"],
                "u_neg_increase_count": u_neg_stats["increase_count"],
                "u_neg_worst_increase": u_neg_stats["max"],
                "u_neg_sum": u_neg_stats["sum"],
                "u_neg_decrease_count": u_neg_stats["decrease_count"],
                "u_pass_increase_count": u_pass_stats["increase_count"],
                "u_pass_worst_increase": u_pass_stats["max"],
                "u_pass_sum": u_pass_stats["sum"],
                "d_neg_sum": d_neg_stats["sum"],
                "d_neg_decrease_count": d_neg_stats["decrease_count"],
                "d_neg_increase_count": d_neg_stats["increase_count"],
                "d_neg_median": d_neg_stats["median"],
                "d_near_sum": d_near_stats["sum"],
                "d_near_decrease_count": d_near_stats["decrease_count"],
                "d_near_increase_count": d_near_stats["increase_count"],
                "d_near_median": d_near_stats["median"],
                "pass": not reasons,
                "rejection_reasons": ";".join(reasons),
            }
            rows_out.append(row)

    passing = [row for row in rows_out if row["pass"]]
    passing.sort(key=lambda row: (
        int(row["u_neg_increase_count"]),
        float(row["u_neg_worst_increase"]),
        int(row["u_pass_increase_count"]),
        float(row["u_pass_worst_increase"]),
        float(row["d_neg_sum"]),
        float(row["d_near_sum"]),
    ))
    chosen = passing[0] if passing else None
    decision = "BOUNDED_CANDIDATE_FOR_G1" if chosen else "NO_PRODUCER_ONLY_CANDIDATE_IN_BOUNDED_SCREEN"

    csv_path = args.out_dir / "bounded_screen_candidates.csv"
    fields = list(rows_out[0].keys()) if rows_out else []
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows_out)

    manifest = {
        "stage": "Step12F-P9-R5G bounded producer-only screening",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "baseline_commit": args.baseline_commit,
        "decision": decision,
        "decision_semantics": {
            "BOUNDED_CANDIDATE_FOR_G1": "one fixed corridor/subset passes all bounded geometric risk gates and may justify one real CONTROL/TREATMENT run",
            "NO_PRODUCER_ONLY_CANDIDATE_IN_BOUNDED_SCREEN": "the fixed finite screen found no candidate; this is not a proof that every producer-only placement is impossible, but it is sufficient to stop expanding this line and return to R5F distributed timing-tail work",
        },
        "inputs": {
            "fixed_dcp": {"path": str(args.dcp), "sha256": dcp_sha, "expected_sha256": EXPECTED_DCP_SHA, "sha256_match": True},
            "inventory": {"path": str(args.inventory), "sha256": sha256(args.inventory), "site_count": len(site_rows), "bbox": inventory_bbox, "complete_for_expanded_envelope": inventory_complete},
            "g0_paths": {"path": str(args.g0_dir / "g0_ingress_inputmem_paths.csv"), "sha256": sha256(args.g0_dir / "g0_ingress_inputmem_paths.csv"), "rows": len(g0_rows)},
            "upstream_paths": {"path": str(args.g05_dir / "g05_upstream_paths.csv"), "sha256": sha256(args.g05_dir / "g05_upstream_paths.csv"), "rows": len(upstream_rows)},
        },
        "population": {"producer_bits": len(producer_rows), "upstream_all": len(upstream_rows), "upstream_negative": len(u_neg), "upstream_nonnegative": len(u_pass), "downstream_all": len(g0_rows), "downstream_negative": len(d_neg), "downstream_near_zero": len(d_near)},
        "screening_contract": {
            "regions": REGIONS,
            "subsets": {name: bits for name, bits in SUBSETS.items()},
            "thresholds": THRESHOLDS,
            "implementation_commands": "FORBIDDEN",
            "rtl_changes": "FORBIDDEN",
            "xdc_changes": "FORBIDDEN",
            "virtual_placer": "NOT_USED",
            "exhaustive_pareto": "NOT_USED",
        },
        "evaluated_pairs": len(rows_out),
        "passing_pairs": len(passing),
        "chosen_candidate": chosen,
        "all_candidate_regions": region_cache,
        "next_action": "freeze exact subset/region and run one common-post-opt CONTROL/TREATMENT A/B" if chosen else "stop expanding producer-only locality; return to R5F distributed timing-tail census",
    }
    (args.out_dir / "BOUNDED_SCREEN_MANIFEST.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    report_lines = [
        "# Step12F-P9-R5G bounded producer-only screening",
        "",
        f"Decision: **{decision}**",
        "",
        f"- Baseline commit: `{args.baseline_commit}`",
        f"- Fixed routed DCP SHA-256: `{dcp_sha}` (match=True)",
        f"- Fresh inventory: `{len(site_rows)}` rows; bbox `{inventory_bbox}`; complete=`{inventory_complete}`",
        f"- Evaluated pairs: `{len(rows_out)}` (4 fixed corridors × 8 fixed subsets)",
        f"- Passing pairs: `{len(passing)}`",
        "",
        "## Fixed gates",
        "",
        "The gates were fixed before scoring: bounded upstream-negative/pass risk, clear aggregate improvement for negative downstream paths, no downstream increases in the negative/near-zero sets, and two-FF-per-moved-bit capacity headroom. This is a geometric proxy, not a timing guarantee.",
        "",
    ]
    if chosen:
        report_lines.extend([
            "## Candidate to test once",
            "",
            f"- Region: `{chosen['region_id']}` = SLICE_X{chosen['region_x_min']}..X{chosen['region_x_max']} / Y{chosen['region_y_min']}..Y{chosen['region_y_max']}",
            f"- Candidate tile anchor: `({chosen['candidate_tile_x']}, {chosen['candidate_tile_y']})`",
            f"- Subset: `{chosen['subset_id']}` ({chosen['moved_bit_count']} bits)",
            f"- Bit list: `{chosen['bit_list']}`",
            f"- Upstream negative: `{chosen['u_neg_increase_count']}` increases, worst `+{chosen['u_neg_worst_increase']}` tiles, sum `{chosen['u_neg_sum']}`",
            f"- Upstream passing: `{chosen['u_pass_increase_count']}` increases, worst `+{chosen['u_pass_worst_increase']}` tiles",
            f"- Downstream negative: sum `{chosen['d_neg_sum']}`, decreases `{chosen['d_neg_decrease_count']}`, increases `{chosen['d_neg_increase_count']}`",
            f"- Downstream near-zero: sum `{chosen['d_near_sum']}`, decreases `{chosen['d_near_decrease_count']}`, increases `{chosen['d_near_increase_count']}`",
            "",
            "This result only authorizes one real CONTROL/TREATMENT A/B from a common post-opt DCP. It does not authorize R6 RTL, a broad pblock, strategy search, or a timing claim.",
        ])
    else:
        report_lines.extend([
            "## Result",
            "",
            "No fixed producer-only corridor/subset passed the bounded gates. This is not a proof that every producer-only placement is impossible; do not expand the virtual search, and return to the R5F timing census/physical-convergence path.",
        ])
    (args.out_dir / "BOUNDED_SCREEN_REPORT.md").write_text("\n".join(report_lines) + "\n", encoding="utf-8")
    (args.out_dir / "BOUNDED_SCREEN_STATUS.txt").write_text(
        "\n".join([
            "status=CLOSED_READ_ONLY",
            f"decision={decision}",
            f"evaluated_pairs={len(rows_out)}",
            f"passing_pairs={len(passing)}",
            f"inventory_complete={inventory_complete}",
            "implementation_commands=FORBIDDEN",
            "rtl_changes=FORBIDDEN",
            "xdc_changes=FORBIDDEN",
            "R6=NOT_AUTHORIZED",
        ]) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
