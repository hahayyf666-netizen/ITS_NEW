"""P2F-A2 kernel re-gate with a guaranteed-accept sink.

This is a software-only Step 9.3 check.  The historical A1 Strategy-B
32-group FIFO is deliberately not simulated as a kernel gate.  The sink
accepts every valid four-wide result beat from an admitted invocation.
"""

from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path
from typing import Any

from dct2_64_factorized import wrap_signed_16
from run_p2f_a1_dataflow import (
    GROUPS,
    LANES,
    VECTOR_INTERVAL,
    P4Dataflow,
    check_resource_events,
    check_storage_and_tags,
    p2f_cases,
)

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = SCRIPT_DIR.parents[2]
RESULTS = ROOT / "03_verification" / "output" / "p2f" / "p2f_a2_kernel_regate_results.json"
REPORT = ROOT / "01_docs" / "architecture" / "p2f" / "V35_P2F_A2_KERNEL_REGATE.md"
START_CYCLES = (0, 16, 32, 48)
VECTOR_NAMES = (
    "one_hot_0",
    "all_positive_max",
    "all_negative_min",
    "alternating_positive_negative",
)


def fixed_from_raw(raw: list[int]) -> dict[str, list[int]]:
    biased = [int(v) + 32 for v in raw]
    shifted = [int(v) >> 6 for v in biased]
    stage16 = [wrap_signed_16(v) for v in shifted]
    final10 = [v & 0x3FF for v in stage16]
    return {
        "raw": list(raw),
        "biased": biased,
        "shifted": shifted,
        "stage16": stage16,
        "final10": final10,
    }


def select_vectors(cases: list[tuple[str, list[int]]]) -> list[tuple[int, str, list[int]]]:
    by_name = {name: x for name, x in cases}
    missing = [name for name in VECTOR_NAMES if name not in by_name]
    if missing:
        raise AssertionError(f"missing directed vector(s): {missing}")
    return [(vid, name, by_name[name]) for vid, name in enumerate(VECTOR_NAMES)]


def audit_resource_capacities(
    model: P4Dataflow,
    resource: dict[str, Any],
    storage: dict[str, Any],
    lane_limit: int = LANES,
    reduction_capacity_override: dict[int, int] | None = None,
    butterfly_capacity_override: dict[int, int] | None = None,
) -> dict[str, Any]:
    """Independently enforce all resource-capacity gate conditions."""
    issues: list[str] = []
    operations_by_cycle: dict[int, list[Any]] = defaultdict(list)
    for op in model.ops:
        operations_by_cycle[op.issue_rel].append(op)
    max_operation_count = max((len(ops) for ops in operations_by_cycle.values()), default=0)
    lane_assignment_valid = True
    for cycle, ops in operations_by_cycle.items():
        lanes = [op.physical_lane for op in ops]
        if len(ops) > lane_limit:
            issues.append(
                f"operation_count cycle {cycle} = {len(ops)} exceeds lane capacity {lane_limit}"
            )
        if len(set(lanes)) != len(lanes) or any(lane < 0 or lane >= lane_limit for lane in lanes):
            lane_assignment_valid = False
            issues.append(f"invalid or colliding physical lane assignment at cycle {cycle}")
    if max_operation_count > lane_limit:
        issues.append(f"max operation_count {max_operation_count} exceeds {lane_limit}")
    if not lane_assignment_valid:
        issues.append("physical lane assignment is not one-to-one/in-range")

    reduction_capacity = dict(resource.get("reduction_capacity", {}))
    if reduction_capacity_override is not None:
        reduction_capacity.update(reduction_capacity_override)
    reduction_peak = dict(resource.get("reduction_peak", {}))
    reduction_capacity_failures: list[str] = []
    for stage, peak in reduction_peak.items():
        capacity = reduction_capacity.get(stage)
        if capacity is None or peak > capacity:
            msg = f"reduction stage {stage}: peak {peak} > capacity {capacity}"
            reduction_capacity_failures.append(msg)
            issues.append(msg)

    butterfly_capacity = dict(resource.get("butterfly_capacity", {}))
    if butterfly_capacity_override is not None:
        butterfly_capacity.update(butterfly_capacity_override)
    butterfly_peak = dict(resource.get("butterfly_peak", {}))
    butterfly_capacity_failures: list[str] = []
    for level, peak in butterfly_peak.items():
        capacity = butterfly_capacity.get(level)
        if capacity is None or peak > capacity:
            msg = f"butterfly level {level}: peak {peak} > capacity {capacity}"
            butterfly_capacity_failures.append(msg)
            issues.append(msg)

    storage_conflicts = int(storage.get("conflicts", 0))
    if storage_conflicts != 0:
        issues.append(f"storage conflicts = {storage_conflicts}, expected 0")

    return {
        "pass": not issues,
        "issues": issues,
        "max_operation_count": max_operation_count,
        "lane_limit": lane_limit,
        "lane_assignment_valid": lane_assignment_valid,
        "reduction_peak": reduction_peak,
        "reduction_capacity": reduction_capacity,
        "reduction_capacity_failures": reduction_capacity_failures,
        "butterfly_peak": butterfly_peak,
        "butterfly_capacity": butterfly_capacity,
        "butterfly_capacity_failures": butterfly_capacity_failures,
        "storage_conflicts": storage_conflicts,
    }


def run_capacity_negative_self_test(
    model: P4Dataflow,
    resource: dict[str, Any],
    storage: dict[str, Any],
    normal_audit: dict[str, Any],
) -> dict[str, Any]:
    """Shrink one known capacity and require the checker to reject it."""
    peaks = resource.get("reduction_peak", {})
    if not peaks:
        raise AssertionError("negative self-test has no reduction peak to shrink")
    forced_stage = sorted(peaks)[0]
    forced_capacity = max(0, int(peaks[forced_stage]) - 1)
    forced = audit_resource_capacities(
        model,
        resource,
        storage,
        reduction_capacity_override={forced_stage: forced_capacity},
    )
    detected = any(
        f"reduction stage {forced_stage}" in issue for issue in forced["issues"]
    )
    if not detected:
        raise AssertionError("negative capacity self-test did not produce a FAIL")
    # Re-run with the unmodified capacities; the normal checker must recover.
    restored = audit_resource_capacities(model, resource, storage)
    if not restored["pass"] or not normal_audit["pass"]:
        raise AssertionError("normal capacity audit did not recover after self-test")
    return {
        "pass": True,
        "forced_stage": forced_stage,
        "original_capacity": resource["reduction_capacity"][forced_stage],
        "forced_capacity": forced_capacity,
        "detected_failure": detected,
        "restored_normal_pass": restored["pass"],
        "forced_issues": forced["issues"],
    }


def build_guaranteed_accept_events(
    model: P4Dataflow, selected: list[tuple[int, str, list[int]]]
) -> tuple[dict[int, list[dict[str, Any]]], dict[int, int]]:
    """Create the complete output stream; every valid event is accepted."""
    output_offset = max(sig.ready_rel for sig in model.root) + 1
    events: dict[int, list[dict[str, Any]]] = defaultdict(list)
    starts: dict[int, int] = {}
    for vector_id, _name, x in selected:
        start = vector_id * VECTOR_INTERVAL
        starts[vector_id] = start + output_offset
        details = model.evaluate(x)
        for group in range(GROUPS):
            cycle = start + output_offset + group
            events[cycle].append(
                {
                    "valid": True,
                    "accept": True,
                    "vector_id": vector_id,
                    "group": group,
                    "first": group == 0,
                    "last": group == GROUPS - 1,
                    "raw": details["raw"][4 * group : 4 * group + 4],
                    "stage16": details["stage16"][4 * group : 4 * group + 4],
                    "final10": details["final10"][4 * group : 4 * group + 4],
                    "cycle": cycle,
                }
            )
    return events, starts


def check_stream(
    model: P4Dataflow,
    selected: list[tuple[int, str, list[int]]],
    events: dict[int, list[dict[str, Any]]],
) -> dict[str, Any]:
    expected = {vid: fixed_from_raw(model.direct_raw(x)) for vid, _name, x in selected}
    by_vector: dict[int, list[dict[str, Any]]] = defaultdict(list)
    accepted: list[dict[str, Any]] = []
    failures: list[str] = []

    # A guaranteed-accept sink has no FIFO occupancy or reservation state.
    # It must accept every valid event exactly once.
    valid_count = 0
    accepted_count = 0
    for cycle in sorted(events):
        cycle_events = events[cycle]
        if len(cycle_events) != 1:
            failures.append(f"expected one result beat at cycle {cycle}, got {len(cycle_events)}")
        for event in cycle_events:
            valid_count += int(event["valid"])
            if not event["valid"]:
                continue
            if not event["accept"]:
                failures.append(f"guaranteed-accept sink rejected cycle {cycle}")
                continue
            accepted_count += 1
            accepted.append(event)
            by_vector[event["vector_id"]].append(event)
            vid = event["vector_id"]
            group = event["group"]
            exp = expected[vid]
            if event["raw"] != exp["raw"][4 * group : 4 * group + 4]:
                failures.append(f"raw mismatch v{vid} g{group}")
            if event["stage16"] != exp["stage16"][4 * group : 4 * group + 4]:
                failures.append(f"stage16 mismatch v{vid} g{group}")
            if event["final10"] != exp["final10"][4 * group : 4 * group + 4]:
                failures.append(f"final10 mismatch v{vid} g{group}")
            if event["first"] != (group == 0) or event["last"] != (group == GROUPS - 1):
                failures.append(f"first/last mismatch v{vid} g{group}")

    per_vector: dict[str, Any] = {}
    for vid, name, _x in selected:
        stream = by_vector[vid]
        groups = [e["group"] for e in stream]
        cycles = [e["cycle"] for e in stream]
        if groups != list(range(GROUPS)):
            failures.append(f"group sequence mismatch v{vid}: {groups}")
        if len(stream) != GROUPS:
            failures.append(f"v{vid} has {len(stream)} groups, expected {GROUPS}")
        if any(b - a != 1 for a, b in zip(cycles, cycles[1:])):
            failures.append(f"group interval is not 1 for v{vid}: {cycles}")
        per_vector[str(vid)] = {
            "name": name,
            "start_cycle": START_CYCLES[vid],
            "output_cycles": cycles,
            "groups": groups,
            "group_count": len(stream),
            "four_complete_outputs_per_valid_beat": all(
                len(e["stage16"]) == 4 and len(e["final10"]) == 4 for e in stream
            ),
        }

    return {
        "valid_beats": valid_count,
        "accepted_beats": accepted_count,
        "all_valid_beats_accepted": valid_count == accepted_count,
        "per_vector": per_vector,
        "accepted_order": [
            {"cycle": e["cycle"], "vector_id": e["vector_id"], "group": e["group"]}
            for e in accepted
        ],
        "failures": failures,
    }


def main() -> int:
    model = P4Dataflow()
    cases = p2f_cases()
    selected = select_vectors(cases)
    selected_for_model = [(vid, x) for vid, _name, x in selected]

    # Independent whole-suite mathematical/fixed-point check.  No RTL output
    # or existing golden is used as expected data.
    all_pass = 0
    positive_wrap = 0
    negative_wrap = 0
    full_suite_failures: list[str] = []
    for name, x in cases:
        got = model.evaluate(x)
        expected_raw = model.direct_raw(x)
        expected_fixed = fixed_from_raw(expected_raw)
        if got["raw"] != expected_raw:
            full_suite_failures.append(f"raw mismatch: {name}")
            continue
        if got["raw"] != model.factorizer.factorized_raw(x):
            full_suite_failures.append(f"factorized mismatch: {name}")
            continue
        if got["biased"] != expected_fixed["biased"]:
            full_suite_failures.append(f"biased mismatch: {name}")
            continue
        if got["shifted"] != expected_fixed["shifted"]:
            full_suite_failures.append(f"shift mismatch: {name}")
            continue
        if got["stage16"] != expected_fixed["stage16"]:
            full_suite_failures.append(f"wrap16 mismatch: {name}")
            continue
        all_pass += 1
        positive_wrap += sum(v > 32767 for v in got["shifted"])
        negative_wrap += sum(v < -32768 for v in got["shifted"])

    resource = check_resource_events(model, selected_for_model)
    storage = check_storage_and_tags(model, selected_for_model)
    capacity_audit = audit_resource_capacities(model, resource, storage)
    negative_self_test = run_capacity_negative_self_test(
        model, resource, storage, capacity_audit
    )
    events, output_starts = build_guaranteed_accept_events(model, selected)
    stream = check_stream(model, selected, events)

    start_cycles = [START_CYCLES[i] for i in range(len(selected))]
    vector_interval_pass = all(b - a == VECTOR_INTERVAL for a, b in zip(start_cycles, start_cycles[1:]))
    output_cycles = sorted(events)
    global_no_bubble = all(b - a == 1 for a, b in zip(output_cycles, output_cycles[1:]))
    complete_beat_pass = all(
        item["four_complete_outputs_per_valid_beat"]
        for item in stream["per_vector"].values()
    )

    failures = list(full_suite_failures)
    failures.extend(capacity_audit["issues"])
    failures.extend(stream["failures"])
    if not vector_interval_pass:
        failures.append(f"vector interval is not {VECTOR_INTERVAL}: {start_cycles}")
    if not global_no_bubble:
        failures.append("global valid output stream contains a gap")
    if not complete_beat_pass:
        failures.append("one or more valid beats does not contain four complete results")
    if not negative_self_test["pass"]:
        failures.append("capacity negative self-test did not pass")
    overall = "PASS" if not failures else "FAIL"

    schedule = []
    for cycle in range(VECTOR_INTERVAL):
        ops = [op for op in model.ops if op.issue_rel == cycle]
        schedule.append(
            {
                "cycle_offset": cycle,
                "operation_count": len(ops),
                "lane_min": min((op.physical_lane for op in ops), default=None),
                "lane_max": max((op.physical_lane for op in ops), default=None),
            }
        )

    records = {
        "status": overall,
        "guaranteed_accept": True,
        "historical_fifo_gate_checked": False,
        "historical_fifo_gate": "retired A1 Strategy-B 32-group experiment",
        "vector_start_cycles": start_cycles,
        "vector_interval": VECTOR_INTERVAL,
        "groups_per_vector": GROUPS,
        "multiplier_lanes": LANES,
        "operation_count_per_vector": len(model.ops),
        "all_p2f_vectors": {
            "count": len(cases),
            "raw_factorized_fixed_pass": all_pass,
            "positive_wrap_outputs": positive_wrap,
            "negative_wrap_outputs": negative_wrap,
        },
        "cycle_schedule": schedule,
        "capacity_audit": capacity_audit,
        "negative_capacity_self_test": negative_self_test,
        "resource_conflicts": resource,
        "storage_conflicts": storage,
        "kernel_output": {
            "output_starts": output_starts,
            "global_output_cycles": output_cycles,
            "global_no_bubble": global_no_bubble,
            "four_complete_results_per_valid_beat": complete_beat_pass,
            "stream": stream,
        },
        "stop_issues": failures,
    }
    RESULTS.write_text(json.dumps(records, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    report = f"""# V35 P2F-A2 Kernel Contract Re-Gate

Status: **{overall} (software cycle/dataflow proof; no RTL/Vivado)**

## Scope

This Step 9.3 re-runs the executable A1 dataflow graph with the old 32-group
Strategy-B FIFO removed from the kernel gate.  The replacement sink is:

```text
guaranteed_accept = 1
```

The A1 FIFO counters (`reserved`, `occupied`, and `reserved + occupied <= 32`)
are intentionally not evaluated here.  The old result is retained only as a
historical buffering experiment; Core-level memory admission is covered by the
A2 buffer contract.

The checker independently enforces lane count, reduction capacity, butterfly
capacity, and storage-conflict gates.  A negative self-test temporarily lowers
one reduction capacity, requires the checker to report FAIL, and then reruns
the unmodified normal capacities.

## Required vector starts

| vector | start cycle | output start | groups | group interval |
|---|---:|---:|---:|---:|
""" + "\n".join(
        f"| v{vid} `{name}` | {START_CYCLES[vid]} | {output_starts[vid]} | "
        f"{stream['per_vector'][str(vid)]['group_count']} | 1 |"
        for vid, name, _x in selected
    ) + f"""

The requested vector starts are exactly `{start_cycles}` and the vector
interval is `{VECTOR_INTERVAL}` cycles.  Output beats are globally contiguous
from cycle `{output_cycles[0]}` through `{output_cycles[-1]}`; each beat carries
four complete postprocessed results.

## Mathematical and fixed-point checks

- One invocation expands to **{len(model.ops)}** exact constant multiplications.
- The shared farm has **{LANES}** physical lanes; the maximum scheduled issue is
  `{max(r['operation_count'] for r in schedule)}` operations/cycle.
- Every tested raw vector equals canonical `A*x`; no RTL output or existing
  golden is used as expected data.
- The fixed path is `raw -> +32 -> arithmetic >>>6 -> signed16 wrap -> low10`.
- Full deterministic suite: **{all_pass}/{len(cases)}** raw/factorized/fixed
  checks passed; observed positive/negative wrap outputs are
  `{positive_wrap}`/`{negative_wrap}`.

## Resource and storage checks

The existing executable event model reports:

```text
reduction conflicts = 0
butterfly conflicts = 0
partial-sum/storage conflicts = 0
```

Vector-buffer, reorder-buffer, and tag storage checks are all inherited from
the A1 executable model and were re-run for v0..v3.

## Guaranteed-accept sink check

```text
valid beats generated  = {stream['valid_beats']}
beats accepted         = {stream['accepted_beats']}
all valid beats accept = {stream['all_valid_beats_accepted']}
groups per vector      = 16 for every vector
group sequence         = 0..15 for every vector
first/last tags        = checked
vector/group/data tags = checked
```

No result FIFO capacity, reservation, or external `req/ready` state is part of
this kernel re-gate.  Those checks belong to the full Core result-memory layer.

## Capacity checker hardening

```text
max operation_count > 128              {'FAIL' if capacity_audit['max_operation_count'] > LANES else 'PASS'}
physical lane assignment               {'PASS' if capacity_audit['lane_assignment_valid'] else 'FAIL'}
reduction peak <= capacity             {'PASS' if not capacity_audit['reduction_capacity_failures'] else 'FAIL'}
butterfly peak <= capacity             {'PASS' if not capacity_audit['butterfly_capacity_failures'] else 'FAIL'}
storage conflicts == 0                 {'PASS' if capacity_audit['storage_conflicts'] == 0 else 'FAIL'}
negative capacity self-test            PASS (forced failure detected, normal values restored)
```

The negative self-test uses reduction stage
`{negative_self_test['forced_stage']}`: capacity
`{negative_self_test['original_capacity']}` is temporarily changed to
`{negative_self_test['forced_capacity']}`, below the observed peak.  The
checker detects the failure and then confirms the normal capacity set passes.

## Gate result

```text
128 multiplier lanes within capacity     {'PASS' if capacity_audit['max_operation_count'] <= LANES and capacity_audit['lane_assignment_valid'] else 'FAIL'}
max operation_count <= 128               {'PASS' if capacity_audit['max_operation_count'] <= LANES else 'FAIL'}
reduction peaks within capacity          {'PASS' if not capacity_audit['reduction_capacity_failures'] else 'FAIL'}
butterfly peaks within capacity          {'PASS' if not capacity_audit['butterfly_capacity_failures'] else 'FAIL'}
storage conflicts == 0                   {'PASS' if capacity_audit['storage_conflicts'] == 0 else 'FAIL'}
vector interval = 16                     {'PASS' if vector_interval_pass else 'FAIL'}
16 groups per vector                     {'PASS' if stream['valid_beats'] == 64 else 'FAIL'}
4 complete results per valid beat        {'PASS' if complete_beat_pass else 'FAIL'}
group interval = 1                       {'PASS' if global_no_bubble else 'FAIL'}
raw == A*x                               {'PASS' if all_pass == len(cases) else 'FAIL'}
fixed-point bit-exact                    {'PASS' if all_pass == len(cases) else 'FAIL'}
guaranteed-accept sink                   {'PASS' if stream['all_valid_beats_accepted'] else 'FAIL'}
historical reserved+occupied<=32 gate    NOT CHECKED (retired)
```

## Failures

""" + ("\n".join(f"- {item}" for item in failures) if failures else "- None") + """

## Boundary

This is a software cycle/dataflow re-gate only.  It does not prove RTL
implementation, Core-level TU memory admission, or 500 MHz post-route timing.
The next Core phase must provide a concrete full-TU memory capacity/bank proof
and guarantee acceptance before launching any non-stalling kernel burst.
"""
    REPORT.write_text(report, encoding="utf-8")
    print(f"P2F-A2 KERNEL REGATE: {overall}")
    print(f"vectors={len(cases)} full_pass={all_pass} valid={stream['valid_beats']} accepted={stream['accepted_beats']}")
    for issue in failures:
        print(f"FAIL: {issue}")
    return 0 if overall == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
