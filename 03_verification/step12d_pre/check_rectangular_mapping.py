"""Check the generalized logical bank/address and raster mapping contract.

This is a logical conflict proof for the four-bank formula.  It is not a
Vivado RAM-inference, placement, timing, or final ownership proof.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def bank(row: int, col: int) -> int:
    return (row & 3) ^ (col & 3)


def address(row: int, col: int, width: int) -> int:
    assert width % 4 == 0
    return row * (width // 4) + (col // 4)


def shape_rows(legal: dict) -> list[tuple[int, int, str]]:
    out: list[tuple[int, int, str]] = []
    for transform, rows in legal["official_shape_support"].items():
        for block in rows:
            w, h = (int(x) for x in block.split("x"))
            out.append((w, h, transform))
    return out


def build_proof(legal: dict) -> dict:
    records = []
    for width, height, transform in shape_rows(legal):
        assert width % 4 == 0 and height % 4 == 0
        assert width <= 64 and height <= 64
        input_depth = height * (width // 4)
        intermediate_depth = height * (width // 4)

        for vector in range(width):
            for group in range(height // 4):
                rows = [group * 4 + lane for lane in range(4)]
                banks = [bank(row, vector) for row in rows]
                addrs = [address(row, vector, width) for row in rows]
                assert len(set(banks)) == 4
                assert all(0 <= a < input_depth for a in addrs)

        for vector in range(height):
            for group in range(width // 4):
                cols = [group * 4 + lane for lane in range(4)]
                banks = [bank(vector, col) for col in cols]
                addrs = [address(vector, col, width) for col in cols]
                assert len(set(banks)) == 4
                assert all(0 <= a < intermediate_depth for a in addrs)

        for vector in range(width):
            for group in range(height // 4):
                rows = [group * 4 + lane for lane in range(4)]
                banks = [bank(row, vector) for row in rows]
                assert len(set(banks)) == 4

        for row in range(height):
            for group in range(width // 4):
                for lane in range(4):
                    col = group * 4 + lane
                    result_index = row * width + col
                    result_beat = result_index // 4
                    result_lane = result_index % 4
                    decoded_row = result_beat // (width // 4)
                    decoded_col = (result_beat % (width // 4)) * 4 + result_lane
                    assert (decoded_row, decoded_col) == (row, col)

        records.append({
            "width": width,
            "height": height,
            "transform_shape_row": transform,
            "vertical_vectors": width,
            "vertical_vector_length": height,
            "horizontal_vectors": height,
            "horizontal_vector_length": width,
            "result_beats": (width * height) // 4,
            "input_bank_depth": input_depth,
            "intermediate_bank_depth": intermediate_depth,
            "status": "PASS_LOGICAL_NO_4_LANE_BANK_CONFLICT",
        })

    return {
        "schema": "step12d_pre.memory_mapping_proof.v1",
        "status": "PASS_LOGICAL_MAPPING_CONFLICT_FREE_NOT_PHYSICAL_PROOF",
        "official_shape_rows_checked": len(records),
        "unique_shape_rows": len({(r["width"], r["height"]) for r in records}),
        "formula": {
            "bank": "(row[1:0] XOR col[1:0])",
            "address": "row * (width / 4) + floor(col / 4)",
            "vertical_input_coordinate": "row=input_index, col=vertical_vector",
            "intermediate_coordinate": "row=vertical_output, col=horizontal_input",
            "result_beat": "row * (width / 4) + floor(horizontal_output / 4)",
            "raster_index": "row * width + horizontal_output",
        },
        "conflict_checks": {
            "vertical_input_read_group": "four consecutive row lanes at fixed column",
            "intermediate_horizontal_read_group": "four consecutive column lanes at fixed row",
            "vertical_intermediate_write_group": "four consecutive output rows at fixed column",
            "all_four_lane_banks_distinct": True,
            "all_addresses_in_range": True,
            "result_raster_order": True,
            "result_beat_lane_round_trip": True,
        },
        "records": records,
        "physical_proof": False,
        "tuple_coverage": "shape/type rows only; descriptor coupling remains pending",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout", action="store_true")
    args = parser.parse_args()
    legal = json.loads((EVIDENCE / "LEGAL_TRANSFORM_MATRIX.json").read_text(encoding="utf-8"))
    proof = build_proof(legal)
    if args.stdout:
        print(json.dumps(proof, ensure_ascii=False, indent=2))
        return 0
    (EVIDENCE / "MEMORY_MAPPING_PROOF.json").write_text(
        json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({
        "status": proof["status"],
        "official_shape_rows_checked": proof["official_shape_rows_checked"],
        "unique_shape_rows": proof["unique_shape_rows"],
        "physical_proof": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
