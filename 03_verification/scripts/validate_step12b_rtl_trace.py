"""Fail-closed RTL trace audit and cycle-accurate comparison.

The model and RTL use one global anchor only: the first accepted input data
beat. Every subsequent event is compared at its absolute cycle; no
event-specific, TU-specific, or normal-vs-SYNTHESIS offsets are permitted.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "05_audit" / "current" / "17"


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl-trace", type=Path,
                    default=OUT / "step12b_rtl_event_trace_normal.csv")
    ap.add_argument("--model-trace", type=Path,
                    default=OUT / "step12b_cycle_trace.json")
    args = ap.parse_args()
    with args.rtl_trace.open(encoding="utf-8", newline="") as f:
        rtl = list(csv.DictReader(f))
    model = json.loads(args.model_trace.read_text(encoding="utf-8"))

    rc = [int(r["cycle"]) for r in rtl]
    mc = [int(e["cycle"]) for e in model]
    if any(b < a for a, b in zip(rc, rc[1:])):
        fail("RTL trace cycle rollback")
    if any(b < a for a, b in zip(mc, mc[1:])):
        fail("model trace cycle rollback")
    rtl_input = next((int(r["cycle"]) for r in rtl if r["event"] == "input_fire"), None)
    model_input = next((int(e["cycle"]) for e in model if e["event"] == "input_data_fire"), None)
    if rtl_input is None or model_input is None:
        fail("missing input-fire anchor")
    anchor = rtl_input - model_input
    rtl_inputs = [r for r in rtl if r["event"] == "input_fire"]
    model_inputs = [e for e in model if e.get("event") == "input_data_fire"]
    if len(rtl_inputs) != len(model_inputs):
        fail("model/RTL data-fire count mismatch")
    for e, r in zip(model_inputs, rtl_inputs):
        if int(e["cycle"]) + anchor != int(r["cycle"]) or int(e["addr"]) != int(r["addr"]):
            fail("data-fire cycle/address mismatch")
    model_ends = [e for e in model if e.get("event") == "input_end_fire"]
    rtl_ends = [r for r in rtl_inputs if r.get("end") == "1"]
    if len(model_ends) != len(rtl_ends):
        fail("model/RTL end-fire count mismatch")

    starts = [r for r in rtl if r["event"] == "vector_start"]
    groups = [r for r in rtl if r["event"] == "kernel_group"]
    writes = [r for r in rtl if r["event"] == "result_write"]
    fires = [r for r in rtl if r["event"] == "output_fire"]
    done = [r for r in rtl if r["event"] == "it_done"]
    if len(starts) != 128 or len(groups) != 2048 or len(writes) != 1024 or len(fires) != 1024:
        fail(f"RTL trace counts wrong starts={len(starts)} groups={len(groups)} writes={len(writes)} fires={len(fires)}")
    for phase in ("1", "2"):
        p = [int(r["cycle"]) for r in starts if r["phase"] == phase]
        if len(p) != 64 or any(b - a != 16 for a, b in zip(p, p[1:])):
            fail(f"phase {phase} vector II is not 16")
    per_vector: dict[tuple[str, str], list[int]] = {}
    for r in groups:
        per_vector.setdefault((r["phase"], r["vector"]), []).append(int(r["group"]))
    if any(sorted(vals) != list(range(16)) for vals in per_vector.values()):
        fail("kernel group sequence is not 0..15")
    group_cycle = {(r["phase"], r["vector"], r["group"]): int(r["cycle"]) for r in groups}
    for r in writes:
        key = (r["phase"], r["vector"], r["group"])
        if int(r["cycle"]) != group_cycle.get(key, -1):
            fail("result_write is not same-cycle with horizontal kernel_group")
    if [int(r["index"]) for r in fires] != list(range(1024)):
        fail("output fire index/order mismatch")

    # Compare common event streams independently. Same-cycle ordering in a
    # CSV monitor is not a contract; cycles and tags are.
    ms = [e for e in model if e.get("event") == "phase_vector_start"]
    if len(ms) != len(starts):
        fail("model/RTL vector-start count mismatch")
    for e, r in zip(ms, starts):
        local = int(e["vector"])
        phase = "1" if e["phase"] == "vertical" else "2"
        vector = local if phase == "1" else local + 64
        if int(e["cycle"]) + anchor != int(r["cycle"]):
            fail("vector_start cycle mismatch")
        if r["phase"] != phase or int(r["vector"]) != vector:
            fail("vector_start tag mismatch")

    mg = [e for e in model if e.get("event") == "kernel_group"]
    if len(mg) != len(groups):
        fail("model/RTL kernel-group count mismatch")
    for e, r in zip(mg, groups):
        serial = int(e["serial"])
        phase = "1" if serial < 64 else "2"
        if int(e["cycle"]) + anchor != int(r["cycle"]):
            fail("kernel_group cycle mismatch")
        if (r["phase"], int(r["vector"]), int(r["group"])) != (phase, serial, int(e["group"])):
            fail("kernel_group tag mismatch")

    mw = [e for e in model if e.get("event") == "result_write"]
    if len(mw) != len(writes):
        fail("model/RTL result-write count mismatch")
    for e, r in zip(mw, writes):
        # The model records H vector indices locally (0..63); RTL exposes the
        # global R4C vector tag (64..127) for that phase.
        vector = int(e["vector"]) + 64
        if int(e["cycle"]) + anchor != int(r["cycle"]):
            fail("result_write cycle mismatch")
        if (r["phase"], int(r["vector"]), int(r["group"])) != ("2", vector, int(e["group"])):
            fail("result_write tag mismatch")

    mf = [e for e in model if e.get("event") == "output_fire"]
    if len(mf) != len(fires):
        fail("model/RTL output-fire count mismatch")
    for e, r in zip(mf, fires):
        if int(e["cycle"]) + anchor != int(r["cycle"]) or int(e["index"]) != int(r["index"]):
            fail("output_fire cycle/index mismatch")
    md = [e for e in model if e.get("event") == "it_done"]
    if len(md) != len(done):
        fail("model/RTL it_done count mismatch")
    for e, r in zip(md, done):
        if int(e["cycle"]) + anchor != int(r["cycle"]):
            fail("it_done cycle mismatch")
    print(f"STEP12B_RTL_TRACE_PASS rows={len(rtl)} anchor={anchor} starts=128 groups=2048 writes=1024 fires=1024")
    return 0


if __name__ == "__main__":
    sys.exit(main())
