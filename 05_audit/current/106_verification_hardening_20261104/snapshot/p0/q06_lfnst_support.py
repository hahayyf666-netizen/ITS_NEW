"""P0-C: Q06 - square 4x4/8x8 LFNST input-support rule (8 terms vs 16 terms).

The frozen model uses only the first 8 entries of LFNST_INPUT_SCAN for (4,4)
and (8,8), and 16 for every other shape. This script:
  1. builds a discriminating input that is nonzero ONLY at scan position 8..15,
  2. runs both rules on the same raw input,
  3. compares final SAT10 output beats.

It also reports, for the existing corpus cases of those shapes, whether the
corpus even contains nonzero values in scan positions 8..15 (otherwise the
corpus cannot distinguish the two rules).
"""
from __future__ import annotations
import json, sys
from pathlib import Path

REPO = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\its_push")
ENG = REPO / "03_verification/step12d_engineering"
sys.path.insert(0, str(ENG))

from validate_gate_c_model import (Descriptor, CANONICAL, load_json, inverse_2d,  # noqa: E402
                                   output_beats, round_clip, LFNST_INPUT_SCAN,
                                   lfnst_output_scan)
from generate_gate_c_hdl_vectors import full_engineering_cases, sparse_entries  # noqa: E402
from verify_full_spatial_reference import image  # noqa: E402

OUT = Path(r"C:\Users\Fine\Documents\deepseek-harness\default-workspace\closure_audit\p0")
MAX_RANGE = 15


def apply_lfnst_variant(coeff, width, height, set_idx, lfnst_idx, canonical, nonzero):
    """Mirror of validate_gate_c_model.apply_lfnst with the support count forced."""
    ntrs = 16 if (width == 4 or height == 4) else 48
    gathered = [coeff[r][c] if r < height and c < width else 0 for r, c in LFNST_INPUT_SCAN]
    matrix = canonical["lfnst"][str(ntrs)][str(set_idx)][str(lfnst_idx)]
    lo, hi = -(1 << MAX_RANGE), (1 << MAX_RANGE) - 1
    transformed = [round_clip(sum(matrix[i][j] * gathered[j] for j in range(nonzero)),
                              7, lo, hi) for i in range(ntrs)]
    result = [row[:] for row in coeff]
    output_scan = lfnst_output_scan(ntrs)
    for (row, col), value in zip(output_scan, transformed):
        if row < height and col < width:
            result[row][col] = value
    support_side = 4 if ntrs == 16 else 8
    output_set = set(output_scan)
    for row in range(min(height, support_side)):
        for col in range(min(width, support_side)):
            if (row, col) not in output_set:
                result[row][col] = 0
    return result


def flat(beats):
    return [v for beat in beats for v in beat]


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    canonical = load_json(CANONICAL)

    shapes = [(4, 4), (8, 8)]
    records = []
    total_div_configs = 0
    corpus_scan = {}

    for (w, h) in shapes:
        # Which corpus cases share this shape and carry lfnst_idx != 0?
        hit = 0
        scanned = 0
        for d in full_engineering_cases():
            if (d.width, d.height) != (w, h) or not d.lfnst_idx:
                continue
            scanned += 1
            entries = sparse_entries(d, 0x520)  # representative seed for input shape
            img = image(d, entries)
            tail = [img[r][c] for r, c in LFNST_INPUT_SCAN[8:16]]
            if any(v != 0 for v in tail):
                hit += 1
        corpus_scan[f"{w}x{h}"] = {"cases_with_lfnst": scanned,
                                   "cases_with_nonzero_at_scan_8_16": hit}

        for set_idx in range(4):
            for lfnst_idx in (1, 2):
                # Discriminating input: single nonzero at scan position 8 only.
                coeff = [[0] * w for _ in range(h)]
                r0, c0 = LFNST_INPUT_SCAN[8]
                coeff[r0][c0] = 64
                out8 = apply_lfnst_variant(coeff, w, h, set_idx, lfnst_idx, canonical, 8)
                out16 = apply_lfnst_variant(coeff, w, h, set_idx, lfnst_idx, canonical, 16)
                d = Descriptor(w, h, 0, 0, set_idx, lfnst_idx)
                wide8 = inverse_2d(out8, w, h, 0, 0, set_idx, 0, canonical)
                wide16 = inverse_2d(out16, w, h, 0, 0, set_idx, 0, canonical)
                a = flat(output_beats(wide8, "SAT10"))
                b = flat(output_beats(wide16, "SAT10"))
                div = sum(1 for x, y in zip(a, b) if x != y)
                if div:
                    total_div_configs += 1
                records.append({
                    "shape": f"{w}x{h}", "set_idx": set_idx, "lfnst_idx": lfnst_idx,
                    "discriminator": {"scan_index": 8, "row": r0, "col": c0, "value": 64},
                    "intermediate_differs": out8 != out16,
                    "final_divergent_points": div,
                    "points": w * h,
                    "lfnst_out8_nonzero": sum(1 for row in out8 for v in row if v),
                    "lfnst_out16_nonzero": sum(1 for row in out16 for v in row if v),
                    "sample_final_8": a[:4], "sample_final_16": b[:4],
                })

    report = {
        "schema": "its.p0.q06_lfnst_support.v1",
        "official_equivalence": "NOT_PROVEN",
        "current_rule": "nonzero = 8 for (4,4) and (8,8); 16 for all other shapes",
        "configs_tested": len(records),
        "configs_with_final_divergence": total_div_configs,
        "corpus_scan_profile": corpus_scan,
        "records": records,
        "conclusion_scope": "Shows whether the two readings are distinguishable and "
                            "whether the existing corpus can tell them apart. Does not "
                            "decide which reading is official.",
    }
    (OUT / "q06_lfnst_support.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(f"configs tested = {len(records)}")
    print(f"configs with final divergence = {total_div_configs}")
    for k, v in corpus_scan.items():
        print(f"  corpus {k}: {v['cases_with_lfnst']} LFNST-on cases, "
              f"{v['cases_with_nonzero_at_scan_8_16']} carry nonzero at scan 8..15")
    for rec in records[:4]:
        print(f"  {rec['shape']} set{rec['set_idx']} idx{rec['lfnst_idx']}: "
              f"intermediate_differs={rec['intermediate_differs']} "
              f"final_div={rec['final_divergent_points']}/{rec['points']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())