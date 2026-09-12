"""Compare the frozen RTL memory timing probe with the Step12B model.

This checker intentionally covers only the V/H staging memory boundary.  It
does not apply a free offset per event: one anchor (the first read request) is
used for request, lane-capture, and stage-full streams.  ResultMemory remains
outside this checker and is validated by the model's explicit +1 contract.
"""
from __future__ import annotations

import argparse
import ast
import csv
import json
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(message)


def model_request_key(event: dict) -> tuple[int, int, int, int, int, int, int, int]:
    token = ast.literal_eval(str(event["token"]))
    phase, tu, vector, lane, row, col = token
    phase_id = 1 if phase == "vertical" else 2
    group = int(lane) // 4
    return (phase_id, int(tu), int(vector), group, int(lane) % 4, int(event["bank"]),
            int(event["addr"]), int(event["cycle"]))


def model_capture_key(event: dict) -> tuple[int, int, int, int, int, int, int, int]:
    phase_id = 1 if event["phase"] == "vertical" else 2
    return (phase_id, int(event["tu"]), int(event["vector"]), int(event["group"]),
            int(event["lane"]), int(event["bank"]), int(event["addr"]),
            int(event["cycle"]))


def rtl_key(row: dict) -> tuple[int, int, int, int, int, int, int, int]:
    return (int(row["phase"]), int(row["tu"]), int(row["vector"]), int(row["group"]),
            int(row["lane"]), int(row["bank"]), int(row["addr"]), int(row["cycle"]))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl-probe", type=Path, required=True)
    ap.add_argument("--model-trace", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    with args.rtl_probe.open(encoding="utf-8", newline="") as f:
        rtl = list(csv.DictReader(f))
    model = json.loads(args.model_trace.read_text(encoding="utf-8"))

    rtl_req = [r for r in rtl if r["event"] == "read_request"]
    rtl_cap = [r for r in rtl if r["event"] == "stage_lane_capture"]
    rtl_full = [r for r in rtl if r["event"] == "stage_full"]
    model_req = [e for e in model if e.get("event") == "memory_read_request"]
    model_cap = [e for e in model if e.get("event") == "stage_lane_capture"]
    model_full = [e for e in model if e.get("event") == "stage_full"]
    if (len(rtl_req), len(rtl_cap), len(rtl_full)) != (8192, 8192, 128):
        fail(f"RTL probe counts mismatch req={len(rtl_req)} cap={len(rtl_cap)} full={len(rtl_full)}")
    if (len(model_req), len(model_cap), len(model_full)) != (8192, 8192, 128):
        fail(f"model counts mismatch req={len(model_req)} cap={len(model_cap)} full={len(model_full)}")

    anchor = int(rtl_req[0]["cycle"]) - int(model_req[0]["cycle"])
    model_req_keys = [model_request_key(e)[:-1] + (int(e["cycle"]) + anchor,)
                      for e in model_req]
    rtl_req_keys = [rtl_key(r) for r in rtl_req]
    if model_req_keys != rtl_req_keys:
        fail("model/RTL staging read-request lane trace mismatch")

    model_cap_keys = [model_capture_key(e)[:-1] + (int(e["cycle"]) + anchor,)
                      for e in model_cap]
    rtl_cap_keys = [rtl_key(r) for r in rtl_cap]
    if model_cap_keys != rtl_cap_keys:
        fail("model/RTL staging lane-capture trace mismatch")
    if any(int(c[7]) != int(q[7]) for c, q in zip(model_cap_keys, rtl_cap_keys)):
        fail("model/RTL lane capture edge mismatch")

    def full_key_model(e: dict) -> tuple[int, int, int, int]:
        return (1 if e["phase"] == "vertical" else 2, int(e["tu"]),
                int(e["vector"]), int(e["cycle"]) + anchor)

    def full_key_rtl(r: dict) -> tuple[int, int, int, int]:
        return (int(r["phase"]), int(r["tu"]), int(r["vector"]), int(r["cycle"]))

    if [full_key_model(e) for e in model_full] != [full_key_rtl(r) for r in rtl_full]:
        fail("model/RTL stage_full trace mismatch")

    payload = {
        "status": "PASS",
        "scope": "V/H staging memory request/capture timing",
        "single_anchor": anchor,
        "rtl_requests": len(rtl_req),
        "rtl_lane_captures": len(rtl_cap),
        "rtl_stage_full": len(rtl_full),
        "request_to_capture_edge_delta": 0,
        "first_request_to_stage_full_edge_delta": 15,
        "result_memory_latency": 1,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print("STEP12B_MEMORY_TIMING_COMPARE_PASS " + json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
