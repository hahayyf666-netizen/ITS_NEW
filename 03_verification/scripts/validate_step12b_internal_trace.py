"""Audit verification-only internal transaction events in the Step12B trace.

This is deliberately separate from the public output comparator.  The DUT
trace records transaction/fire events, not level samples.  The audit checks
the single-TU resource event counts and the one-cycle result RAM request /
response contract without changing the datapath.
"""
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl-trace", type=Path, required=True)
    ap.add_argument("--model-trace", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    with args.rtl_trace.open(encoding="utf-8", newline="") as f:
        rtl = list(csv.DictReader(f))
    model = json.loads(args.model_trace.read_text(encoding="utf-8"))

    cycles = [int(row["cycle"]) for row in rtl]
    if any(b < a for a, b in zip(cycles, cycles[1:])):
        fail("internal RTL trace cycle rollback")

    def rows(event: str) -> list[dict[str, str]]:
        return [row for row in rtl if row["event"] == event]

    rtl_input = next((int(r["cycle"]) for r in rtl if r["event"] == "input_fire"), None)
    model_input = next((int(e["cycle"]) for e in model
                        if e.get("event") == "input_data_fire"), None)
    if rtl_input is None or model_input is None:
        fail("missing input anchor for internal trace")
    anchor = rtl_input - model_input

    expected = {
        "stage_capture": 128,
        "intermediate_write": 1024,
        "result_reserve": 1,
        "result_read_request": 1024,
        "result_read_response": 1024,
        "epoch_scrub": 0,
    }
    model_expected = {
        "stage_capture": 128,
        "result_reserve": 1,
        "result_read_request": 1024,
        "result_read_response": 1024,
    }
    for event, count in expected.items():
        if len(rows(event)) != count:
            fail(f"{event} count mismatch: got {len(rows(event))}, expected {count}")
    for event, count in model_expected.items():
        if sum(1 for e in model if e.get("event") == event) != count:
            fail(f"model {event} count mismatch")

    stages = rows("stage_capture")
    stage_keys = [(int(r["phase"]), int(r["vector"])) for r in stages]
    if stage_keys != ([(1, v) for v in range(64)] +
                      [(2, v) for v in range(64)]):
        fail("stage_capture phase/vector sequence mismatch")

    req = rows("result_read_request")
    rsp = rows("result_read_response")
    req_cycles = [int(r["cycle"]) for r in req]
    rsp_cycles = [int(r["cycle"]) for r in rsp]
    if any(b < a for a, b in zip(req_cycles, req_cycles[1:])):
        fail("result read request cycle rollback")
    if any(b < a for a, b in zip(rsp_cycles, rsp_cycles[1:])):
        fail("result read response cycle rollback")
    if any(b - a != 1 for a, b in zip(req_cycles, rsp_cycles)):
        fail("result read request/response latency is not one cycle")
    if [int(r["index"]) for r in req] != list(range(1024)):
        fail("result read request index/order mismatch")
    if [int(r["index"]) for r in rsp] != list(range(1024)):
        fail("result read response index/order mismatch")

    # These internal events are compared with the same single input-fire
    # anchor as the public event comparator.  No per-event offset is allowed.
    for event in ("stage_capture", "result_reserve", "result_read_request",
                  "result_read_response"):
        rr = rows(event)
        mm = [e for e in model if e.get("event") == event]
        if len(rr) != len(mm):
            fail(f"internal model/RTL {event} count mismatch")
        for r, m in zip(rr, mm):
            if int(r["cycle"]) != int(m["cycle"]) + anchor:
                fail(f"internal {event} cycle mismatch")
        if event in ("result_read_request", "result_read_response"):
            for r, m in zip(rr, mm):
                if int(r["index"]) != int(m["index"]):
                    fail(f"internal {event} index mismatch")
    stage_model = [e for e in model if e.get("event") == "stage_capture"]
    for r, m in zip(stages, stage_model):
        phase = 1 if m.get("phase") == "vertical" else 2
        if int(r["phase"]) != phase or int(r["vector"]) != int(m["vector"]):
            fail("stage_capture model/RTL tag mismatch")

    payload = {
        "status": "PASS",
        "scope": "single-TU verification-only internal transaction events",
        "events": {event: len(rows(event)) for event in expected},
        "result_read_latency": 1,
        "global_anchor": anchor,
        "model_event_counts": {event: sum(1 for e in model if e.get("event") == event)
                                for event in model_expected},
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print("STEP12B_INTERNAL_TRACE_PASS " + json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
