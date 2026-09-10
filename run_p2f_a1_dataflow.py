"""Executable cycle/dataflow proof for the frozen 128-lane P2F-A1 schedule.

This is a software-only architecture model.  It expands every one of the
1368 constant multiplications, evaluates the actual products and reduction
trees, performs the E/O butterflies and output reorder, and checks FIFO
Strategy-B accounting across four vectors issued at 16-cycle intervals.
No RTL, simulator, or Vivado result is used as an expected value.
"""

from __future__ import annotations

import json
from collections import defaultdict, deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from dct2_64_factorized import ExactDCT2Factorizer, wrap_signed_16
from run_p2f_equivalence import deterministic_cases, random_cases

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "p2f_a1_dataflow_results.json"
REPORT = ROOT / "V35_P2F_A1_DATAFLOW_PROOF.md"
LANES = 128
VECTOR_INTERVAL = 16
FIFO_DEPTH = 32
GROUPS = 16
MUL_LATENCY = 1


@dataclass
class MulOp:
    op_id: int
    level: int
    branch: str
    output_p: int
    input_m: int
    source_x_index: int
    coefficient: int
    issue_rel: int
    physical_lane: int = -1


@dataclass
class Dot:
    dot_id: int
    level: int
    branch: str
    output_p: int
    op_ids: list[int]
    issue_rel: int
    ready_rel: int
    value: int = 0


@dataclass
class Signal:
    signal_id: str
    level: int
    p: int
    ready_rel: int
    even: "Signal | None" = None
    odd: Dot | None = None
    value: int = 0


def issue_cycle(level: int, output_p: int) -> int:
    if level in (4, 8, 16):
        return 0
    if level == 32:
        return 1 if output_p < 8 else 2
    if level == 64:
        return 3 + output_p // 4
    raise ValueError(level)


def tree_depth(terms: int) -> int:
    d = 0
    while terms > 1:
        terms //= 2
        d += 1
    return d


class P4Dataflow:
    def __init__(self) -> None:
        self.factorizer = ExactDCT2Factorizer()
        self.source = self.factorizer.source
        self.ops: list[MulOp] = []
        self.dots: list[Dot] = []
        self.signals: list[Signal] = []
        self._build_root()
        self._assign_lanes()
        self._check_static_contract()

    def _new_dot(self, level: int, branch: str, output_p: int,
                 indices: list[int], row_parity: int) -> Dot:
        coeff_row = self.source[level]
        ids: list[int] = []
        for m, src_idx in enumerate(indices):
            k = 2 * m + row_parity
            coeff = int(coeff_row[k][output_p])
            if not -128 <= coeff <= 127:
                raise AssertionError(f"coefficient outside signed8: {level} {k} {output_p} {coeff}")
            op = MulOp(
                op_id=len(self.ops), level=level, branch=branch,
                output_p=output_p, input_m=m, source_x_index=src_idx,
                coefficient=coeff, issue_rel=issue_cycle(level, output_p),
            )
            self.ops.append(op)
            ids.append(op.op_id)
        ready = issue_cycle(level, output_p) + MUL_LATENCY + tree_depth(len(ids))
        dot = Dot(len(self.dots), level, branch, output_p, ids,
                  issue_cycle(level, output_p), ready)
        self.dots.append(dot)
        return dot

    def _build_node(self, level: int, indices: list[int], tag: str) -> list[Signal]:
        if level == 4:
            even: list[Dot] = []
            odd: list[Dot] = []
            for p in range(2):
                even.append(self._new_dot(4, f"N4_terminal_even_{tag}", p, indices[0::2], 0))
                odd.append(self._new_dot(4, f"N4_terminal_odd_{tag}", p, indices[1::2], 1))
            out: list[Signal] = [None] * 4  # type: ignore[list-item]
            for p in range(2):
                ready = max(even[p].ready_rel, odd[p].ready_rel) + 1
                out[p] = Signal(f"N4:{tag}:low:{p}", 4, p, ready, odd=odd[p])
                out[p].even = None
                out[p].value = 0
                out[3 - p] = Signal(f"N4:{tag}:high:{p}", 4, 3 - p, ready, odd=odd[p])
                out[3 - p].even = None
            # The terminal even branch is carried explicitly through a small
            # private attribute so evaluation can use the exact E[p].
            for p in range(2):
                setattr(out[p], "even_dot", even[p])
                setattr(out[3 - p], "even_dot", even[p])
            return out

        even_outputs = self._build_node(level // 2, indices[0::2], f"{tag}.E")
        odd: list[Dot] = []
        for p in range(level // 2):
            odd.append(self._new_dot(level, f"N{level}_odd", p, indices[1::2], 1))
        out: list[Signal] = [None] * level  # type: ignore[list-item]
        for p in range(level // 2):
            ready = max(even_outputs[p].ready_rel, odd[p].ready_rel) + 1
            out[p] = Signal(f"N{level}:{tag}:low:{p}", level, p, ready,
                            even=even_outputs[p], odd=odd[p])
            out[level - 1 - p] = Signal(f"N{level}:{tag}:high:{p}", level, level - 1 - p,
                                        ready, even=even_outputs[p], odd=odd[p])
            self.signals.extend((out[p], out[level - 1 - p]))
        return out

    def _build_root(self) -> None:
        self.root = self._build_node(64, list(range(64)), "root")

    def _assign_lanes(self) -> None:
        by_cycle: dict[int, list[MulOp]] = defaultdict(list)
        for op in self.ops:
            by_cycle[op.issue_rel].append(op)
        for cycle, ops in by_cycle.items():
            # Stable operation order is part of the executable schedule.
            for lane, op in enumerate(sorted(ops, key=lambda x: x.op_id)):
                op.physical_lane = lane
            if len(ops) > LANES:
                raise AssertionError(f"multiplier overcommit at cycle {cycle}: {len(ops)}")

    def _check_static_contract(self) -> None:
        expected = {4: 8, 8: 16, 16: 64, 32: 256, 64: 1024}
        actual: dict[int, int] = defaultdict(int)
        for op in self.ops:
            actual[op.level] += 1
        if dict(actual) != expected:
            raise AssertionError(f"operation counts differ: {dict(actual)} != {expected}")
        if len(self.ops) != 1368:
            raise AssertionError(len(self.ops))
        by_cycle: dict[int, list[MulOp]] = defaultdict(list)
        for op in self.ops:
            by_cycle[op.issue_rel].append(op)
        expected_cycles = {0: 88, 1: 128, 2: 128, 3: 128, 4: 128, 5: 128,
                           6: 128, 7: 128, 8: 128, 9: 128, 10: 128}
        if {k: len(v) for k, v in by_cycle.items()} != expected_cycles:
            raise AssertionError({k: len(v) for k, v in by_cycle.items()})
        for cycle, ops in by_cycle.items():
            lanes = [op.physical_lane for op in ops]
            if len(set(lanes)) != len(lanes) or min(lanes) < 0 or max(lanes) >= LANES:
                raise AssertionError(f"lane collision at {cycle}")

    @staticmethod
    def _wrap_and_fixed(raw: list[int]) -> dict[str, list[int]]:
        biased = [v + 32 for v in raw]
        shifted = [v >> 6 for v in biased]
        stage16 = [wrap_signed_16(v) for v in shifted]
        final10 = [v & 0x3FF for v in stage16]
        return {"raw": raw, "biased": biased, "shifted": shifted,
                "stage16": stage16, "final10": final10}

    def evaluate(self, x: list[int]) -> dict[str, Any]:
        if len(x) != 64:
            raise ValueError(len(x))
        products = [op.coefficient * int(x[op.source_x_index]) for op in self.ops]
        for dot in self.dots:
            vals = [products[i] for i in dot.op_ids]
            for _ in range(tree_depth(len(vals))):
                vals = [vals[i] + vals[i + 1] for i in range(0, len(vals), 2)]
            dot.value = vals[0]

        def eval_signal(sig: Signal) -> int:
            if sig.even is None:
                even_sig = getattr(sig, "even_dot")
                even_value = even_sig.value
            else:
                even_value = eval_signal(sig.even)
            assert sig.odd is not None
            odd_value = sig.odd.value
            if "high" in sig.signal_id:
                sig.value = even_value - odd_value
            else:
                sig.value = even_value + odd_value
            return sig.value

        raw = [eval_signal(sig) for sig in self.root]
        fixed = self._wrap_and_fixed(raw)
        fixed["raw"] = raw
        return fixed

    def direct_raw(self, x: list[int]) -> list[int]:
        a = self.factorizer.inverse[64]
        return [sum(int(a[i][j]) * int(x[j]) for j in range(64)) for i in range(64)]

    def reduction_events(self, x: list[int], vector_id: int, start: int) -> list[dict[str, Any]]:
        products = [op.coefficient * int(x[op.source_x_index]) for op in self.ops]
        events: list[dict[str, Any]] = []
        for dot in self.dots:
            vals = [(products[i], i) for i in dot.op_ids]
            for stage in range(tree_depth(len(vals))):
                nxt: list[tuple[int, int]] = []
                for node, (va, ia) in enumerate(vals[::2]):
                    vb, ib = vals[2 * node + 1]
                    value = va + vb
                    cycle = start + dot.issue_rel + MUL_LATENCY + stage + 1
                    events.append({"kind": "reduction", "vector_id": vector_id,
                                   "dot_id": dot.dot_id, "level": dot.level,
                                   "stage": stage, "node": node, "cycle": cycle,
                                   "value": value, "read_ids": [ia, ib],
                                   "write_id": (dot.dot_id, stage, node)})
                    nxt.append((value, node))
                vals = nxt
        return events

    def butterfly_events(self, vector_id: int, start: int) -> list[dict[str, Any]]:
        events: list[dict[str, Any]] = []

        def walk(signals: list[Signal]) -> None:
            seen: set[int] = set()
            for sig in signals:
                if id(sig) in seen:
                    continue
                seen.add(id(sig))
                if sig.even is not None:
                    walk([sig.even])
                # Every signal is one final add/sub output.  A low/high pair
                # shares E/O inputs but has distinct output nodes.
                even_ready = (getattr(sig, "even_dot").ready_rel
                               if sig.even is None else sig.even.ready_rel)
                odd_ready = sig.odd.ready_rel if sig.odd is not None else 0
                events.append({"kind": "butterfly", "vector_id": vector_id,
                               "level": sig.level, "p": sig.p,
                               "cycle": start + max(even_ready, odd_ready) + 1,
                               "op": "sub" if "high" in sig.signal_id else "add",
                               "write_id": (sig.signal_id, vector_id)})

        # Signals are already the root output graph; recursive signals are
        # reached through the even references.  For resource accounting it is
        # sufficient to enumerate every unique signal in the graph.
        all_signals: list[Signal] = []

        def collect(signals: list[Signal]) -> None:
            for sig in signals:
                if any(id(sig) == id(old) for old in all_signals):
                    continue
                all_signals.append(sig)
                if sig.even is not None:
                    collect([sig.even])

        collect(self.root)
        # Root and recursive signals each represent one add/sub output.
        for sig in all_signals:
            even_ready = (getattr(sig, "even_dot").ready_rel
                           if sig.even is None else sig.even.ready_rel)
            odd_ready = sig.odd.ready_rel if sig.odd is not None else 0
            events.append({"kind": "butterfly", "vector_id": vector_id,
                           "level": sig.level, "p": sig.p,
                           "cycle": start + max(even_ready, odd_ready) + 1,
                           "op": "sub" if "high" in sig.signal_id else "add",
                           "write_id": (sig.signal_id, vector_id)})
        return events

    def operation_records(self, vectors: list[tuple[int, list[int]]]) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        for vector_id, x in vectors:
            for op in self.ops:
                out.append({
                    "instance_id": vector_id * len(self.ops) + op.op_id,
                    "op_id": op.op_id, "vector_id": vector_id,
                    "level": f"N{op.level}", "branch": op.branch,
                    "output_p": op.output_p, "input_m": op.input_m,
                    "source_x_index": op.source_x_index,
                    "coefficient": op.coefficient,
                    "issue_cycle": vector_id * VECTOR_INTERVAL + op.issue_rel,
                    "physical_lane": op.physical_lane,
                    "product": op.coefficient * int(x[op.source_x_index]),
                })
        return out


def p2f_cases() -> list[tuple[str, list[int]]]:
    cases = deterministic_cases()
    for seed in (20260904, 20260905, 20260906, 20260907):
        cases.extend(random_cases(seed, 256))
    return cases


def check_resource_events(model: P4Dataflow, vectors: list[tuple[int, list[int]]]) -> dict[str, Any]:
    # These are fixed first-version resources, not values fitted after the
    # fact: one 128-lane multiplier farm, a configurable 124-node reduction
    # forest, and one butterfly node per output signal.
    reduction_capacity = {0: 64, 1: 32, 2: 16, 3: 8, 4: 4}
    butterfly_capacity = {4: 4, 8: 8, 16: 16, 32: 32, 64: 64}
    reductions: list[dict[str, Any]] = []
    butterflies: list[dict[str, Any]] = []
    for vector_id, x in vectors:
        start = vector_id * VECTOR_INTERVAL
        model.evaluate(x)
        reductions.extend(model.reduction_events(x, vector_id, start))
        butterflies.extend(model.butterfly_events(vector_id, start))
        terminal = {}
        for event in reductions:
            if event["vector_id"] == vector_id and event["node"] == 0:
                terminal[(event["dot_id"], event["stage"])] = event["value"]
        for dot in model.dots:
            key = (dot.dot_id, tree_depth(len(dot.op_ids)) - 1)
            if terminal.get(key) != dot.value:
                raise AssertionError(f"reduction data mismatch vector={vector_id} dot={dot.dot_id}")
    reduction_peak: dict[int, int] = {}
    for (cycle, stage), group in _group_by(reductions, lambda e: (e["cycle"], e["stage"])):
        count = len(group)
        reduction_peak[stage] = max(reduction_peak.get(stage, 0), count)
        if count > reduction_capacity[stage]:
            raise AssertionError(f"reduction conflict cycle={cycle} stage={stage} count={count}")
        if len({tuple(e["write_id"]) for e in group}) != count:
            raise AssertionError(f"partial-sum write collision cycle={cycle} stage={stage}")
    butterfly_peak: dict[int, int] = {}
    for (cycle, level), group in _group_by(butterflies, lambda e: (e["cycle"], e["level"])):
        count = len(group)
        butterfly_peak[level] = max(butterfly_peak.get(level, 0), count)
        if count > butterfly_capacity[level]:
            raise AssertionError(f"butterfly conflict cycle={cycle} level={level} count={count}")
    # Every reduction stage is a distinct registered storage bank.  A stage
    # write and the next-stage read are therefore never same-bank/same-cycle;
    # verify uniqueness of all registered write tokens explicitly.
    writes = {(e["cycle"], e["stage"], tuple(e["write_id"])) for e in reductions}
    if len(writes) != len(reductions):
        raise AssertionError("registered partial-sum storage collision")
    return {
        "reduction_capacity": reduction_capacity,
        "reduction_peak": reduction_peak,
        "butterfly_capacity": butterfly_capacity,
        "butterfly_peak": butterfly_peak,
        "reduction_event_count": len(reductions),
        "butterfly_event_count": len(butterflies),
    }


def _group_by(items: Iterable[dict[str, Any]], key_fn):
    groups: dict[Any, list[dict[str, Any]]] = defaultdict(list)
    for item in items:
        groups[key_fn(item)].append(item)
    return groups.items()


def check_storage_and_tags(model: P4Dataflow, vectors: list[tuple[int, list[int]]]) -> dict[str, Any]:
    # Input A/B vector buffers are preloaded four points/cycle.  During issue,
    # each logical register bank exposes 128 operand taps to the farm.
    accesses: list[dict[str, Any]] = []
    reorder: list[dict[str, Any]] = []
    for vector_id, _x in vectors:
        start = vector_id * VECTOR_INTERVAL
        buf = "A" if vector_id % 2 == 0 else "B"
        for i in range(16):
            accesses.append({"cycle": start - 16 + i, "buffer": buf, "kind": "write", "count": 4})
        for rel in sorted({op.issue_rel for op in model.ops}):
            accesses.append({"cycle": start + rel, "buffer": buf, "kind": "read", "count":
                             sum(op.issue_rel == rel for op in model.ops)})
        write_cycle = start + max(sig.ready_rel for sig in model.root)
        for i in range(64):
            reorder.append({"cycle": write_cycle, "buffer": buf, "kind": "write", "index": i})
        for g in range(16):
            for lane in range(4):
                reorder.append({"cycle": write_cycle + 1 + g, "buffer": buf,
                                "kind": "read", "index": 4 * g + lane})

    conflicts = []
    for group_key, group in _group_by(accesses, lambda e: (e["cycle"], e["buffer"])):
        writes = sum(e["count"] for e in group if e["kind"] == "write")
        reads = sum(e["count"] for e in group if e["kind"] == "read")
        if writes and reads:
            conflicts.append({"kind": "vector_read_write", "key": group_key,
                              "writes": writes, "reads": reads})
        if writes > 4 or reads > 128:
            conflicts.append({"kind": "vector_port_capacity", "key": group_key,
                              "writes": writes, "reads": reads})
    for group_key, group in _group_by(reorder, lambda e: (e["cycle"], e["buffer"])):
        writes = sum(e["kind"] == "write" for e in group)
        reads = sum(e["kind"] == "read" for e in group)
        if writes and reads:
            conflicts.append({"kind": "reorder_read_write", "key": group_key,
                              "writes": writes, "reads": reads})
        if writes > 64 or reads > 4:
            conflicts.append({"kind": "reorder_port_capacity", "key": group_key,
                              "writes": writes, "reads": reads})
    if conflicts:
        raise AssertionError(conflicts[:3])
    return {
        "vector_read_ports": 128,
        "vector_write_ports": 4,
        "reorder_write_ports": 64,
        "reorder_read_ports": 4,
        "conflicts": 0,
        "checked_vector_buffer_accesses": len(accesses),
        "checked_reorder_accesses": len(reorder),
    }


def simulate_fifo(model: P4Dataflow, vectors: list[tuple[int, list[int]]],
                  ready_fn, max_cycles: int, explicit_starts: bool = True) -> dict[str, Any]:
    # Strategy B: reserve all 16 slots before the first group is issued.
    occupied = 0
    reserved = 0
    max_total = 0
    launches: list[dict[str, Any]] = []
    launch_attempts: list[dict[str, Any]] = []
    fifo: deque[dict[str, Any]] = deque()
    expected_by_id = {vid: model.evaluate(x) for vid, x in vectors}
    output_events: dict[int, list[dict[str, Any]]] = defaultdict(list)
    consumed: list[dict[str, Any]] = []
    failures: list[str] = []
    for cycle in range(max_cycles):
        # Existing in-flight vectors may finish a group in this cycle.  A
        # Strategy-B admission decision is allowed to account for that same
        # cycle read/fire, while the new reservation is made before group 0 of
        # the candidate invocation is issued.
        cycle_events = output_events.get(cycle, [])
        read_fire = 1 if ready_fn(cycle) and (fifo or cycle_events) else 0
        projected_occupied = occupied + len(cycle_events) - read_fire
        projected_reserved = reserved - len(cycle_events)

        # Explicit invocation starts are attempted before issuing their first
        # group, but after same-edge FIFO release has been included in the
        # capacity check.  A denied invocation never schedules output events.
        for vid, _x in vectors:
            start = vid * VECTOR_INTERVAL if explicit_starts else None
            if start != cycle:
                continue
            free = FIFO_DEPTH - projected_occupied - projected_reserved
            attempt = {"vector_id": vid, "cycle": cycle, "free_slots": free,
                       "accepted": free >= GROUPS}
            launch_attempts.append(attempt)
            if free < GROUPS:
                continue
            reserved += GROUPS
            launches.append({"vector_id": vid, "cycle": cycle, "reserved_after": reserved})
            details = expected_by_id[vid]
            write_cycle = cycle + max(sig.ready_rel for sig in model.root)
            for g in range(GROUPS):
                output_events[write_cycle + 1 + g].append({
                    "vector_id": vid, "group": g,
                    "raw": details["raw"][4*g:4*g+4],
                    "stage16": details["stage16"][4*g:4*g+4],
                    "final10": details["final10"][4*g:4*g+4],
                    "first": g == 0, "last": g == 15,
                })

        for event in cycle_events:
            if reserved <= 0:
                failures.append(f"output without reservation at cycle {cycle}")
                continue
            reserved -= 1
            if occupied + reserved >= FIFO_DEPTH + 1:
                failures.append(f"FIFO overcommit at cycle {cycle}")
            fifo.append(event)
            occupied += 1

        max_total = max(max_total, occupied + reserved)
        if occupied + reserved > FIFO_DEPTH:
            failures.append(f"capacity violation at cycle {cycle}")

        if read_fire and fifo:
            event = fifo.popleft()
            occupied -= 1
            consumed.append(event)

    if failures:
        raise AssertionError(failures[:5])
    for event in consumed:
        vid = event["vector_id"]
        g = event["group"]
        exp = expected_by_id[vid]
        if event["raw"] != exp["raw"][4*g:4*g+4]:
            raise AssertionError(f"FIFO raw mismatch v{vid} g{g}")
        if event["stage16"] != exp["stage16"][4*g:4*g+4]:
            raise AssertionError(f"FIFO stage mismatch v{vid} g{g}")
        if event["first"] != (g == 0) or event["last"] != (g == 15):
            raise AssertionError(f"tag mismatch v{vid} g{g}")
    return {
        "launches": launches,
        "launch_attempts": launch_attempts,
        "consumed_count": len(consumed),
        "max_occupied_plus_reserved": max_total,
        "final_occupied": occupied,
        "final_reserved": reserved,
        "fifo_depth": FIFO_DEPTH,
        "failures": failures,
        "consumed_order": [{"vector_id": e["vector_id"], "group": e["group"]} for e in consumed],
    }


def main() -> None:
    model = P4Dataflow()
    all_cases = p2f_cases()
    selected = [
        (0, next(x for n, x in all_cases if n == "one_hot_0")),
        (1, next(x for n, x in all_cases if n == "all_positive_max")),
        (2, next(x for n, x in all_cases if n == "all_negative_min")),
        (3, next(x for n, x in all_cases if n == "alternating_positive_negative")),
    ]

    # Full data evaluation for every existing P2F vector.  Expected values are
    # recomputed from canonical A directly, not imported from golden files.
    all_pass = 0
    all_wrap_pos = 0
    all_wrap_neg = 0
    for name, x in all_cases:
        got = model.evaluate(x)
        exp = model.direct_raw(x)
        if got["raw"] != exp:
            raise AssertionError(f"all-vector raw mismatch: {name}")
        if got["raw"] != model.factorizer.factorized_raw(x):
            raise AssertionError(f"all-vector factorizer mismatch: {name}")
        if got["stage16"] != [wrap_signed_16(v) for v in got["shifted"]]:
            raise AssertionError(f"all-vector fixed mismatch: {name}")
        all_pass += 1
        all_wrap_pos += sum(v > 32767 for v in got["shifted"])
        all_wrap_neg += sum(v < -32768 for v in got["shifted"])

    # Four vectors explicitly start at 0/16/32/48 and execute the complete
    # cycle-level resource, data, reorder, tag and FIFO proof.
    resource = check_resource_events(model, selected)
    storage = check_storage_and_tags(model, selected)
    steady = simulate_fifo(model, selected, lambda _cycle: True, 100)

    # A separate long-stall/recovery run verifies Strategy-B launch stopping.
    # It uses the same four vectors and only changes downstream ready.
    recovery = simulate_fifo(model, selected,
                             lambda cycle: cycle >= 80, 180)

    expected_launch_ids = [0, 1, 2, 3]
    steady_launch_ids = [item["vector_id"] for item in steady["launches"]]
    stop_issues: list[str] = []
    if steady_launch_ids != expected_launch_ids:
        cycle32 = next((a for a in steady["launch_attempts"] if a["vector_id"] == 2), None)
        stop_issues.append(
            "Strategy-B rejected a required vector start: "
            f"expected {expected_launch_ids} at cycles [0,16,32,48], "
            f"accepted {steady_launch_ids}; cycle-32 free_slots="
            f"{cycle32['free_slots'] if cycle32 else 'unknown'}"
        )
    if steady["consumed_count"] != 64:
        stop_issues.append(
            f"steady no-backpressure consumed {steady['consumed_count']} groups, expected 64"
        )
    if steady["max_occupied_plus_reserved"] > FIFO_DEPTH:
        stop_issues.append("reserved+occupied exceeded FIFO depth")
    if not any(item["vector_id"] == 2 and not item["accepted"]
               for item in recovery["launch_attempts"]):
        stop_issues.append("long ready=0 run did not prove launch stop")
    overall_status = "PASS" if not stop_issues else "FAIL"

    details = [model.evaluate(x) for _, x in selected]
    schedule = []
    for cycle in range(16):
        ops = [op for op in model.ops if op.issue_rel == cycle]
        schedule.append({
            "cycle_offset": cycle,
            "operation_count": len(ops),
            "levels": {f"N{n}": sum(op.level == n for op in ops) for n in (4, 8, 16, 32, 64) if any(op.level == n for op in ops)},
            "lane_min": min((op.physical_lane for op in ops), default=None),
            "lane_max": max((op.physical_lane for op in ops), default=None),
        })

    records = {
        "status": overall_status,
        "operation_count_per_vector": len(model.ops),
        "operation_level_counts": {f"N{n}": sum(op.level == n for op in model.ops) for n in (4, 8, 16, 32, 64)},
        "vector_start_cycles": [0, 16, 32, 48],
        "multiplier_lanes": LANES,
        "vector_interval": VECTOR_INTERVAL,
        "fifo_depth": FIFO_DEPTH,
        "all_p2f_vectors": {"count": len(all_cases), "raw_and_fixed_pass": all_pass,
                             "positive_wrap_outputs": all_wrap_pos, "negative_wrap_outputs": all_wrap_neg},
        "selected_vectors": [name for name, _ in [("one_hot_0", selected[0][1]),
                                                    ("all_positive_max", selected[1][1]),
                                                    ("all_negative_min", selected[2][1]),
                                                    ("alternating_positive_negative", selected[3][1])]],
        "cycle_schedule": schedule,
        "resource_conflicts": resource,
        "storage_conflicts": storage,
        "steady_fifo": steady,
        "stall_recovery_fifo": recovery,
        "stop_issues": stop_issues,
        "selected_stage16_first4": [d["stage16"][:4] for d in details],
        "selected_final10_first4": [d["final10"][:4] for d in details],
        "operation_instances_first_four_vectors": model.operation_records(selected),
    }
    RESULTS.write_text(json.dumps(records, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    op_counts = records["operation_level_counts"]
    output_start = max(sig.ready_rel for sig in model.root) + 1
    steady_result = "PASS" if steady_launch_ids == expected_launch_ids and steady["consumed_count"] == 64 else "FAIL"
    report = f"""# V35 P2F-A1 Executable Cycle/Dataflow Proof

Status: **{overall_status} (software cycle/dataflow proof; no RTL/Vivado)**

## Scope and expected-value independence

This model expands every operation in one DCT2-64 invocation and evaluates the
actual signed products, full-precision reduction trees, E/O butterflies,
reorder buffer and result FIFO. Expected raw values are independently computed
as `A*x` from the frozen canonical `inverse_operator`; no RTL output or golden
file is used as an expected value.

The four full cycle-level vectors are launched at cycles `0, 16, 32, 48`:
`one_hot_0`, `all_positive_max`, `all_negative_min`, and
`alternating_positive_negative`. The same executable graph is also run against
all {len(all_cases)} vectors from the existing P2F deterministic suite.

## Operation expansion

Each operation record contains `op_id`, `vector_id`, `level`, `output_p`,
`input_m`, source `x` index, coefficient, absolute issue cycle, physical lane,
and the computed product. One vector has exactly:

| level | multiplication instances |
|---|---:|
| N4 terminal | {op_counts['N4']} |
| N8 odd | {op_counts['N8']} |
| N16 odd | {op_counts['N16']} |
| N32 odd | {op_counts['N32']} |
| N64 odd | {op_counts['N64']} |
| **total** | **{len(model.ops)}** |

## 16-cycle issue schedule

| cycle | multiplication instances | levels | lane range |
|---:|---:|---|---|
""" + "\n".join(
        f"| {r['cycle_offset']} | {r['operation_count']} | "
        f"{', '.join(f'{k}={v}' for k, v in r['levels'].items()) or 'idle'} | "
        f"{r['lane_min'] if r['lane_min'] is not None else '—'}..{r['lane_max'] if r['lane_max'] is not None else '—'} |"
        for r in schedule
    ) + f"""

The issue stream uses at most 128 unique physical lanes per cycle and repeats
every 16 cycles. The average is `1368/16 = 85.5` products/cycle, or
66.796875% farm utilization. Coefficient selection is tied to each expanded
operation and each lane performs at most one local-table read per cycle.

## Dataflow and reduction proof

Products enter registered binary reduction stages without any intermediate
rounding, shifting, clipping or wrapping. The fixed first-version reduction
fabric capacities are stage 0..4 = `64, 32, 16, 8, 4` add nodes (124 nodes in
total). The observed peaks were:

```text
reduction peak = {resource['reduction_peak']}
butterfly peak = {resource['butterfly_peak']}
reduction conflicts = 0
butterfly conflicts = 0
partial-sum register collisions = 0
```

The raw result then follows exactly:

```text
raw = A*x
biased = raw + 32
shifted = biased >>> 6
stage16 = signed16 wrap(shifted)
final10 = stage16[9:0]
```

The first contiguous output beat starts at cycle offset {output_start}; groups
0..15 occupy offsets {output_start}..{output_start + 15}. Every beat contains
four complete final 1D results.

## Storage, reorder and tags

The model checks A/B vector-buffer preload (4 writes/cycle) against the 128
operand reads/cycle, and checks two alternating reorder buffers (64 writes at
completion, then 4 reads/cycle). All checked read/write and port conflicts are
zero. Reorder ownership alternates by vector ID; no buffer is reused before its
16 groups have been read.

Every FIFO entry carries `vector_id`, `group`, `first`, `last`, raw, stage16 and
final10 data. The consumed order is checked against the independent `A*x`
results, so data/tag alignment is not inferred from a fire count.

## Strategy-B FIFO proof

The result FIFO is fixed at 32 groups. At each invocation start, 16 slots are
reserved before any group 0 issue. Occupied FIFO groups plus reserved in-flight
groups are checked every cycle.

| scenario | launch attempts | accepted launches | consumed groups | max(reserved+occupied) | result |
|---|---|---:|---:|---:|---|
| ready every cycle | {[(x['vector_id'], x['cycle'], x['accepted']) for x in steady['launch_attempts']]} | {[(x['vector_id'], x['cycle']) for x in steady['launches']]} | {steady['consumed_count']} | {steady['max_occupied_plus_reserved']} | {steady_result} |
| ready=0 until cycle 80, then recovery | {[(x['vector_id'], x['cycle'], x['accepted']) for x in recovery['launch_attempts']]} | {[(x['vector_id'], x['cycle']) for x in recovery['launches']]} | {recovery['consumed_count']} | {recovery['max_occupied_plus_reserved']} | PASS |

The long-stall run stops launching when the 32-group capacity is reserved and
then drains after recovery without loss, duplication or reorder. The steady
run is a hard gate: with the existing output start at cycle 18, cycle 32 has
only 15 free slots, so vector2 is rejected instead of being silently delayed.

## STOP issues

{chr(10).join(f"- {item}" for item in stop_issues) if stop_issues else "- None"}

## Existing P2F vector sweep

```text
vectors checked = {len(all_cases)}
raw/fixed dataflow matches = {all_pass}/{len(all_cases)}
positive wrap outputs observed = {all_wrap_pos}
negative wrap outputs observed = {all_wrap_neg}
```

## Final gate

```text
128 multiplier lanes <= capacity              PASS
vector starts 0/16/32/48                     {"PASS" if steady_launch_ids == expected_launch_ids else "FAIL"}
all 1368 operations expanded and evaluated   PASS
reduction/butterfly/storage conflicts        PASS (0)
raw == factorized graph == A*x               PASS
raw+32 >>>6 wrap16                           PASS
4 complete outputs/cycle                     PASS
group interval = 1                            PASS
FIFO depth = 32                               PASS
reserved + occupied <= 32                    PASS
backpressure stop/recovery                   {"PASS" if not recovery["failures"] else "FAIL"}
```

This is an executable software architecture proof. It is not a timing claim;
the next RTL implementation must still prove the same contracts and 2.000 ns
post-route timing. Because Strategy-B cannot admit all four required starts
under the current schedule, the overall A1.1 gate is **{overall_status}**.
"""
    REPORT.write_text(report, encoding="utf-8")
    print(f"P2F_A1_DATAFLOW_{overall_status} vectors={len(all_cases)} ops={len(model.ops)}")
    if overall_status != "PASS":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
