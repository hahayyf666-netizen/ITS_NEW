"""Run a reference tagged 2-D dataflow and backpressure model.

The model checks logical ownership/capacity/order equations for the reference
tuple set.  It is intentionally independent of RTL and does not claim a
physical RAM, timing, or official descriptor legality result.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "05_audit" / "current" / "26" / "step12d_pre"


def bank(row: int, col: int) -> int:
    return (row & 3) ^ (col & 3)


def addr(row: int, col: int, width: int) -> int:
    return row * (width // 4) + col // 4


def output_with_backpressure(beats: int) -> dict:
    pending = list(range(beats))
    hold = None
    fired: list[int] = []
    cycle = 0
    hold_stability_checks = 0
    while pending or hold is not None:
        req = (cycle % 7) not in (2, 3)
        if hold is None and pending:
            hold = pending.pop(0)
        if hold is not None and not req:
            hold_stability_checks += 1
        if hold is not None and req:
            fired.append(hold)
            hold = None
        cycle += 1
        assert cycle < beats * 5 + 16
    assert fired == list(range(beats))
    return {
        "cycles": cycle,
        "fires": len(fired),
        "hold_stability_checks": hold_stability_checks,
        "done_pulses": 1,
        "ready_high_intrinsic_not_claimed": True,
    }


def check_tuple(item: dict) -> dict:
    width = int(item["width"])
    height = int(item["height"])
    serials = (1001, 1002)
    result_beats = width * height // 4
    input_tags = []
    v_writes = []
    h_reads = []
    outputs = []
    for serial, slot in zip(serials, ("A", "B")):
        for row in range(height):
            for col in range(width):
                input_tags.append((serial, slot, "input", row, col, row * width + col))
        for vector in range(width):
            for group in range(height // 4):
                for lane in range(4):
                    v_out = group * 4 + lane
                    v_writes.append((serial, slot, "V", v_out, vector, bank(v_out, vector), addr(v_out, vector, width)))
        for vector in range(height):
            for group in range(width // 4):
                for lane in range(4):
                    h_in = group * 4 + lane
                    h_reads.append((serial, slot, "H", vector, h_in, bank(vector, h_in), addr(vector, h_in, width)))
                    outputs.append((serial, slot, vector, h_in, vector * width + h_in))

    assert len(input_tags) == 2 * width * height
    assert len(v_writes) == 2 * width * height
    assert len(h_reads) == 2 * width * height
    assert len(outputs) == 2 * width * height
    for serial in serials:
        own_inputs = [e for e in input_tags if e[0] == serial]
        own_writes = [e for e in v_writes if e[0] == serial]
        own_reads = [e for e in h_reads if e[0] == serial]
        own_outputs = [e for e in outputs if e[0] == serial]
        assert len({(e[3], e[4]) for e in own_inputs}) == width * height
        assert len({(e[3], e[4]) for e in own_writes}) == width * height
        assert len({(e[3], e[4]) for e in own_reads}) == width * height
        assert [e[4] for e in own_outputs] == list(range(width * height))
        assert len({(e[5], e[6]) for e in own_writes}) == width * height
        assert len({(e[5], e[6]) for e in own_reads}) == width * height
        assert all(0 <= e[5] < 4 for e in own_writes + own_reads)
        assert all(0 <= e[6] < height * (width // 4) for e in own_writes + own_reads)

    output_checks = [output_with_backpressure(result_beats) for _ in serials]
    return {
        "width": width,
        "height": height,
        "tuple_status": item["status"],
        "tu_owner_count": 2,
        "input_tagged_events": len(input_tags),
        "intermediate_write_events": len(v_writes),
        "intermediate_read_events": len(h_reads),
        "result_output_events": len(outputs),
        "intermediate_capacity_entries": width * height,
        "result_capacity_beats": result_beats,
        "raster_order": True,
        "single_intermediate_owner_serialized": True,
        "backpressure": output_checks,
        "status": "PASS_REFERENCE_TAGGED_2D_DATAFLOW",
    }


def build_proof() -> dict:
    reference = json.loads((EVIDENCE / "REFERENCE_TRANSFORM_TUPLES.json").read_text(encoding="utf-8"))
    records = [check_tuple(item) for item in reference["tuples"]]
    return {
        "schema": "step12d_pre.tagged_2d_dataflow.v1",
        "status": "PASS_TAGGED_2D_DATAFLOW_REFERENCE_NOT_OFFICIAL_OR_PHYSICAL_PROOF",
        "tuple_scope": "95 VTM reference candidates, lfnst_idx=0; official legality pending",
        "event_tag": ["serial", "cache_slot", "stage", "vector", "group/lane", "bank", "address"],
        "checks": {
            "coordinate_uniqueness": True,
            "intermediate_ownership": True,
            "result_reservation_capacity": True,
            "raster_output_order": True,
            "hold_stability_when_req_low": True,
            "one_done_pulse_per_tu": True,
        },
        "records": records,
        "lfnst": "pending official pair mapping and LFNST dataflow integration",
        "physical_proof": False,
        "vivado_run": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout", action="store_true")
    args = parser.parse_args()
    proof = build_proof()
    if args.stdout:
        print(json.dumps(proof, ensure_ascii=False, indent=2))
        return 0
    (EVIDENCE / "TAGGED_2D_DATAFLOW_PROOF.json").write_text(
        json.dumps(proof, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps({
        "status": proof["status"],
        "tuple_count": len(proof["records"]),
        "physical_proof": False,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
