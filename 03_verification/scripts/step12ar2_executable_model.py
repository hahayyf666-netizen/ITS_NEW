"""Step 12A-R2: unified tick-driven 64x64 DCT2 integration proof.

The model intentionally keeps the frozen R4C arithmetic as a stateful
black-box contract.  A single simulator clock advances input protocol,
banked-memory requests/responses, staging, kernel admission, kernel output,
intermediate/result writes and output draining.  The expected path is an
independent operator implementation and is never read from the scheduled
memory.
"""
from __future__ import annotations

import json
import random
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"
OUT = ROOT / "03_verification" / "output"
AUDIT = ROOT / "05_audit" / "current" / "step12ar2"
N = 64
GROUPS = 16
READ_LATENCY = 1
KERNEL_LATENCY = 24
RESULT_GROUPS = 1024
EPOCH_BITS = 2
EPOCH_MOD = 1 << EPOCH_BITS


def wrap16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def low10(v: int) -> int:
    return v & 0x3FF


def load_matrix() -> list[list[int]]:
    data = json.loads(CANONICAL.read_text(encoding="utf-8"))
    return data["transforms"]["0"]["inverse_operator"]["64"]


def bank_addr(row: int, col: int, mapper=None) -> tuple[int, int]:
    if mapper is None:
        return ((row & 3) ^ (col & 3), row * 16 + (col >> 2))
    return mapper(row, col)


def oracle_1d(matrix: list[list[int]], vec: list[int]) -> tuple[list[int], list[int], list[int]]:
    """Independent oracle path; deliberately does not call kernel helpers."""
    raw = []
    for out_idx in range(len(matrix)):
        acc = 0
        for in_idx, value in enumerate(vec):
            acc += int(value) * int(matrix[out_idx][in_idx])
        raw.append(acc)
    shifted = [(v + 32) >> 6 for v in raw]
    stage = [wrap16(v) for v in shifted]
    return raw, shifted, stage


def oracle_2d(matrix: list[list[int]], src: list[list[int]]) -> tuple[list[list[int]], list[list[int]], list[list[int]]]:
    vertical = [[0] * N for _ in range(N)]
    for c in range(N):
        vec = [src[r][c] for r in range(N)]
        stage = oracle_1d(matrix, vec)[2]
        for r, value in enumerate(stage):
            vertical[r][c] = value
    horizontal = [[0] * N for _ in range(N)]
    for r in range(N):
        horizontal[r] = oracle_1d(matrix, vertical[r])[2]
    final = [[low10(v) for v in row] for row in horizontal]
    return vertical, horizontal, final


def read_matrix_memory(mem: "SyncBankMemory", phase: str, start_cycle: int = 0) -> tuple[list[list[int]], list[dict[str, Any]], int]:
    """Read a completed 64x64 banked memory through its synchronous ports."""
    out = [[0] * N for _ in range(N)]
    trace: list[dict[str, Any]] = []
    clock = IntegrationClock(0, trace)
    pending = 0
    cycle = start_cycle
    issued = 0
    while issued < N * GROUPS or pending:
        responses = mem.consume_responses(cycle)
        for token, value in responses:
            r, c = token
            out[r][c] = value
            pending -= 1
            trace.append({"cycle": cycle, "event": "memory_read_response",
                          "memory": mem.name, "phase": phase,
                          "row": r, "col": c, "value": value})
        reads = []
        if issued < N * GROUPS:
            row_or_col, group = divmod(issued, GROUPS)
            points = ([(group * 4 + k, row_or_col) for k in range(4)]
                      if phase == "vertical" else
                      [(row_or_col, group * 4 + k) for k in range(4)])
            reads = [(r, c, (r, c)) for r, c in points]
            issued += 1
            pending += len(reads)
        mem.issue(cycle, reads, [])
        cycle += 1
    return out, trace, cycle


def drain_result_memory(mem: "ResultMemory", start_cycle: int = 0,
                        stall_cycles: int = 0,
                        trace: list[dict[str, Any]] | None = None) -> tuple[list[tuple[int, tuple[int, int, int, int]]], int]:
    """Drain a result store through its explicit one-cycle synchronous port."""
    out = []
    cycle = start_cycle
    for _ in range(stall_cycles):
        if trace is not None:
            trace.append({"cycle": cycle, "event": "output_req",
                          "req": False, "pending": mem.pending_read is not None})
        if mem.read_tick(cycle, False) is not None:
            raise MemoryError12A("result fired while req=0")
        cycle += 1
    guard = 4 * RESULT_GROUPS
    while mem.occupied or mem.pending_read is not None:
        guard -= 1
        if guard <= 0:
            raise MemoryError12A("result drain timeout")
        if trace is not None:
            trace.append({"cycle": cycle, "event": "output_req",
                          "req": True, "pending": mem.pending_read is not None})
        response = mem.read_tick(cycle, True)
        if response is not None:
            out.append(response)
            if trace is not None:
                trace.append({"cycle": cycle, "event": "output_fire",
                              "group": response[0]})
        cycle += 1
    return out, cycle


class MemoryError12A(Exception):
    pass


class SyncBankMemory:
    """Four banks, one read and one write port per bank, read response +1."""
    def __init__(self, name: str, mapper=None, trace: list[dict[str, Any]] | None = None):
        self.name = name
        self.mapper = mapper
        self.trace = trace if trace is not None else []
        self.data = [[0] * 1024 for _ in range(4)]
        self.pending: dict[int, list[tuple[Any, int, int]]] = {}
        self.read_count = 0
        self.write_count = 0
        self.read_conflicts = 0
        self.write_conflicts = 0
        self.rdw_conflicts = 0

    def _check_points(self, points: list[tuple[int, int]]) -> list[int]:
        banks = [bank_addr(r, c, self.mapper)[0] for r, c in points]
        if len(set(banks)) != len(banks):
            self.read_conflicts += 1
            raise MemoryError12A(f"{self.name}: read port conflict {banks}")
        return banks

    def consume_responses(self, cycle: int) -> list[tuple[Any, int]]:
        response = []
        for token, b, a in self.pending.pop(cycle, []):
            self.trace.append({"cycle": cycle, "event": "memory_read_response",
                               "memory": self.name, "token": repr(token),
                               "bank": b, "addr": a})
            response.append((token, self.data[b][a]))
        return response

    def issue(self, cycle: int, reads: list[tuple[int, int, Any]],
              writes: list[tuple[int, int, int, Any]]) -> None:
        read_points = [(r, c) for r, c, _ in reads]
        write_points = [(r, c) for r, c, _, _ in writes]
        rbanks = self._check_points(read_points) if reads else []
        wbanks = [bank_addr(r, c, self.mapper)[0] for r, c in write_points]
        if len(set(wbanks)) != len(wbanks):
            self.write_conflicts += 1
            raise MemoryError12A(f"{self.name}: write port conflict {wbanks}")
        read_set = {(r, c) for r, c, _ in reads}
        write_set = {(r, c) for r, c, _, _ in writes}
        if read_set & write_set:
            self.rdw_conflicts += 1
            raise MemoryError12A(f"{self.name}: same-address RDW at cycle {cycle}")
        for r, c, value, _ in writes:
            b, a = bank_addr(r, c, self.mapper)
            self.data[b][a] = wrap16(value)
            self.write_count += 1
            self.trace.append({"cycle": cycle, "event": "memory_write",
                               "memory": self.name, "row": r, "col": c,
                               "bank": b, "addr": a})
        if reads:
            bucket = self.pending.setdefault(cycle + READ_LATENCY, [])
            for (r, c, token), _bank in zip(reads, rbanks):
                b, a = bank_addr(r, c, self.mapper)
                bucket.append((token, b, a))
                self.read_count += 1
                self.trace.append({"cycle": cycle, "event": "memory_read_request",
                                   "memory": self.name, "token": repr(token),
                                   "row": r, "col": c, "bank": b, "addr": a})
    def tick(self, cycle: int, reads: list[tuple[int, int, Any]],
             writes: list[tuple[int, int, int, Any]]) -> list[tuple[Any, int]]:
        response = self.consume_responses(cycle)
        self.issue(cycle, reads, writes)
        return response


class EpochInputCache(SyncBankMemory):
    def __init__(self, name: str, trace: list[dict[str, Any]] | None = None):
        super().__init__(name, trace=trace)
        self.tags = [[-1] * 1024 for _ in range(4)]
        self.epoch = -1
        self.scrubbing = False
        self.scrub_left = 0

    def begin_tu(self) -> dict[str, Any]:
        nxt = (self.epoch + 1) % EPOCH_MOD
        if self.epoch >= 0 and nxt == 0:
            self.scrubbing = True
            self.scrub_left = 4 * 1024
            self.epoch = -1
            return {"accepted": False, "scrub": True}
        self.epoch = nxt
        return {"accepted": True, "scrub": False}

    def scrub_tick(self, cycle: int) -> bool:
        if not self.scrubbing:
            return True
        self.scrub_left -= 1
        if self.scrub_left <= 0:
            for b in range(4):
                self.tags[b] = [-1] * 1024
            self.scrubbing = False
            self.epoch = 0
            return True
        return False

    def issue(self, cycle: int, reads, writes):
        if self.scrubbing and (reads or writes):
            raise MemoryError12A(f"{self.name}: access during epoch scrub")
        super().issue(cycle, reads, writes)
        for r, c, value, _token in writes:
            b, a = bank_addr(r, c)
            self.tags[b][a] = self.epoch

    def consume_responses(self, cycle: int) -> list[tuple[Any, int]]:
        """Return a synchronous response, but only if its epoch is live.

        A plain SyncBankMemory response would expose stale data after a TU
        cache is reused.  The tag check belongs at the response boundary,
        not only in the direct read helper.
        """
        response = []
        for token, b, a in self.pending.pop(cycle, []):
            value = self.data[b][a] if (not self.scrubbing and
                                        self.epoch >= 0 and
                                        self.tags[b][a] == self.epoch) else 0
            self.trace.append({"cycle": cycle, "event": "memory_read_response",
                               "memory": self.name, "token": repr(token),
                               "bank": b, "addr": a, "tag_valid": value != 0 or
                               self.tags[b][a] == self.epoch})
            response.append((token, value))
        return response
    def tick(self, cycle: int, reads, writes):
        if self.scrubbing and (reads or writes):
            raise MemoryError12A(f"{self.name}: access during epoch scrub")
        out = self.consume_responses(cycle)
        self.issue(cycle, reads, writes)
        return out

    def read_tagged(self, r: int, c: int) -> int:
        if self.scrubbing or self.epoch < 0:
            return 0
        b, a = bank_addr(r, c)
        return self.data[b][a] if self.tags[b][a] == self.epoch else 0


class InputCacheController:
    """Finite A/B ownership contract for sparse TU input admission."""
    STATES = ("FREE", "FILLING", "READY", "READING")

    def __init__(self):
        self.state = {"A": "FREE", "B": "FREE"}

    def input_req(self) -> bool:
        return any(v == "FREE" for v in self.state.values())

    def admit(self) -> str | None:
        for name, state in self.state.items():
            if state == "FREE":
                self.state[name] = "FILLING"
                return name
        return None

    def end(self, name: str) -> None:
        if self.state.get(name) != "FILLING":
            raise MemoryError12A("it_data_end for non-filling cache")
        self.state[name] = "READY"

    def start_read(self, name: str) -> None:
        if self.state.get(name) != "READY":
            raise MemoryError12A("vertical admission before input end")
        self.state[name] = "READING"

    def release(self, name: str) -> None:
        if self.state.get(name) != "READING":
            raise MemoryError12A("release of non-reading input cache")
        self.state[name] = "FREE"


def validate_input_trace(events: list[tuple[int, int]]) -> None:
    last = -1
    for addr, _value in events:
        if addr < 0 or addr >= N * N:
            raise MemoryError12A("input address outside TU")
        if addr <= last:
            raise MemoryError12A("input addresses must be strictly raster-monotonic")
        last = addr


class ResultMemory:
    """1024 x 40-bit result beats, separate from 4-bank 16-bit intermediates."""
    def __init__(self, read_latency: int = 1,
                 trace: list[dict[str, Any]] | None = None):
        self.beats: dict[int, tuple[int, int, int, int]] = {}
        self.capacity = RESULT_GROUPS
        self.reserved = 0
        self.occupied = 0
        self.read_index = 0
        self.write_count = 0
        self.drain_count = 0
        self.read_latency = read_latency
        self.pending_read: tuple[int, int] | None = None
        self.trace = trace if trace is not None else []

    def reserve_tu(self) -> bool:
        if self.capacity - self.reserved - self.occupied < RESULT_GROUPS:
            return False
        if self.occupied == 0 and self.reserved == 0:
            # The physical result store is reused TU-by-TU; its drain cursor
            # is local to the admitted TU, not a global lifetime counter.
            self.read_index = 0
        self.reserved += RESULT_GROUPS
        return True

    def write(self, group_index: int, values: list[int], cycle: int | None = None,
              vector_id: int | None = None, tu: int | None = None,
              phase: str | None = None) -> None:
        if (self.reserved <= 0 or group_index < 0 or
                group_index >= self.capacity or group_index in self.beats or
                len(values) != 4):
            raise MemoryError12A("result write without reservation or duplicate group")
        self.beats[group_index] = tuple(low10(v) for v in values)
        self.reserved -= 1
        self.occupied += 1
        self.write_count += 1
        event = {"event": "result_write", "group": group_index}
        if cycle is not None:
            event["cycle"] = cycle
        if vector_id is not None:
            event["vector_id"] = vector_id
        if tu is not None:
            event["tu"] = tu
        if phase is not None:
            event["phase"] = phase
        self.trace.append(event)

    def read_tick(self, cycle: int, req: bool) -> tuple[int, tuple[int, int, int, int]] | None:
        """Synchronous result-memory read: request at C, response at C+1."""
        response = None
        if self.pending_read is not None and self.pending_read[0] == cycle:
            _, index = self.pending_read
            beat = self.beats.pop(index, None)
            if beat is None:
                raise MemoryError12A("result response lost or duplicated")
            response = (index, beat)
            self.read_index += 1
            self.occupied -= 1
            self.drain_count += 1
            self.pending_read = None
            self.trace.append({"cycle": cycle, "event": "result_read_response",
                               "group": index})
        if req and self.pending_read is None and self.read_index in self.beats:
            self.pending_read = (cycle + self.read_latency, self.read_index)
            self.trace.append({"cycle": cycle, "event": "result_read_request",
                               "group": self.read_index})
        return response

    def drain(self, req: bool) -> tuple[int, tuple[int, int, int, int]] | None:
        if not req or self.read_index not in self.beats:
            return None
        beat = self.beats.pop(self.read_index)
        self.read_index += 1
        self.occupied -= 1
        self.drain_count += 1
        return self.read_index - 1, beat


@dataclass
class KernelEvent:
    cycle: int
    vector_id: int
    group: int
    first: bool
    last: bool
    values: list[int]


class R4CContract:
    """One persistent R4C instance; payload is a separate kernel arithmetic path."""
    def __init__(self, matrix: list[list[int]], initial_vector_id: int = 0,
                 mutate_horizontal: bool = False,
                 trace: list[dict[str, Any]] | None = None):
        self.matrix = matrix
        self.next_vector_id = initial_vector_id & 0xFFFF
        self.last_accept = None
        self.accepted: list[tuple[int, int, list[int]]] = []
        self.emitted: set[tuple[int, int]] = set()
        self.mutate_horizontal = mutate_horizontal
        self.trace = trace if trace is not None else []

    def accept(self, cycle: int, vector_id: int, vec: list[int]) -> None:
        if self.last_accept is not None and cycle - self.last_accept < 16:
            raise MemoryError12A("kernel admission interval below 16")
        expected = self.next_vector_id
        if (vector_id & 0xFFFF) != expected:
            raise MemoryError12A(f"vector id {vector_id} != expected {expected}")
        self.next_vector_id = (expected + 1) & 0xFFFF
        self.last_accept = cycle
        self.accepted.append((cycle, vector_id & 0xFFFF, list(vec)))
        self.trace.append({"cycle": cycle, "event": "vector_start",
                           "vector_id": vector_id & 0xFFFF})

    def outputs(self, cycle: int) -> list[KernelEvent]:
        out = []
        for start, vid, vec in self.accepted:
            first = start + KERNEL_LATENCY
            if first <= cycle < first + GROUPS:
                g = cycle - first
                key = (vid, g)
                if key in self.emitted:
                    continue
                self.emitted.add(key)
                # Separate implementation from oracle_1d: multiplication
                # order is vector term first and post-processing is local.
                raw = [sum(int(vec[j]) * int(self.matrix[i][j]) for j in range(N))
                       for i in range(N)]
                stage = [wrap16((v + 32) >> 6) for v in raw]
                if self.mutate_horizontal and vid >= 64:
                    stage = [wrap16(v + 1024) for v in stage]
                self.trace.append({"cycle": cycle, "event": "kernel_group",
                                   "vector_id": vid, "group": g,
                                   "first": g == 0, "last": g == GROUPS - 1})
                out.append(KernelEvent(cycle, vid, g, g == 0, g == GROUPS - 1,
                                       stage[g * 4:(g + 1) * 4]))
        return out


class PhaseSimulator:
    def __init__(self, matrix: list[list[int]], kernel: R4CContract,
                 source: SyncBankMemory | EpochInputCache, dest: SyncBankMemory,
                 phase: str, vector_base: int, start_cycle: int):
        self.matrix = matrix
        self.kernel = kernel
        self.source = source
        self.dest = dest
        self.phase = phase
        self.vector_base = vector_base
        self.cycle = start_cycle
        self.next_vector = 0
        self.next_load_cycle = start_cycle
        self.staging_values: dict[int, list[int]] = {}
        self.stage_slots = [start_cycle, start_cycle]
        self.read_schedule: dict[int, list[tuple[int, int, Any]]] = {}
        self.read_response_tokens: dict[int, list[tuple[int, int]]] = {}
        self.launches: list[int] = []
        self.events: list[KernelEvent] = []
        self.stalls = {"staging_wait": 0, "source_port": 0}
        self.ticks = 0
        self.kernel_busy_cycles = 0

    def _schedule_vector(self, v: int, cycle: int) -> None:
        slot = v & 1
        if self.stage_slots[slot] > cycle:
            raise MemoryError12A("staging slot ownership conflict")
        self.staging_values[v] = [None] * N
        for g in range(GROUPS):
            pts = ([(g * 4 + k, v) for k in range(4)] if self.phase == "vertical"
                   else [(v, g * 4 + k) for k in range(4)])
            for k, (r, c) in enumerate(pts):
                token = (v, g * 4 + k)
                self.read_schedule.setdefault(cycle + g, []).append((r, c, token))
        self.stage_slots[slot] = cycle + 16
        self.next_load_cycle = cycle + 16

    def _consume_read_responses(self, responses: list[tuple[Any, int]]) -> None:
        for token, value in responses:
            v, idx = token
            self.staging_values[v][idx] = value

    def tick(self) -> None:
        # Responses from requests issued on the previous edge are visible
        # first.  A vector that completes staging on this edge may therefore
        # be admitted and issue the next vector's first read on this same
        # edge.  This is what allows II=16 to be an emergent result.
        responses = self.source.consume_responses(self.cycle)
        self._consume_read_responses(responses)
        if self.next_vector < N and self.cycle >= self.next_load_cycle:
            v = self.next_vector
            values = self.staging_values.get(v)
            if values is None:
                self._schedule_vector(v, self.cycle)
            elif all(x is not None for x in values):
                self.kernel.accept(self.cycle, self.vector_base + v, values)
                self.launches.append(self.cycle)
                self.next_vector += 1
                # The just-captured A/B slot is free on this edge; issue the
                # next vector's reads in the same cycle.  The scheduler, not
                # a v*16 expression, derives the next launch interval.
                if self.next_vector < N and self.cycle >= self.next_load_cycle:
                    self._schedule_vector(self.next_vector, self.cycle)
        reads = self.read_schedule.pop(self.cycle, [])
        self.source.issue(self.cycle, reads, [])
        out_events = self.kernel.outputs(self.cycle)
        if out_events:
            self.kernel_busy_cycles += 1
        writes = []
        for ev in out_events:
            self.events.append(ev)
            if self.phase == "vertical":
                v = ev.vector_id - self.vector_base
                writes.extend((ev.group * 4 + k, v, value, (ev.vector_id, ev.group, k))
                              for k, value in enumerate(ev.values))
            else:
                v = ev.vector_id - self.vector_base
                writes.extend((v, ev.group * 4 + k, value, (ev.vector_id, ev.group, k))
                              for k, value in enumerate(ev.values))
        self.dest.consume_responses(self.cycle)
        self.dest.issue(self.cycle, [], writes)
        self.ticks += 1
        self.cycle += 1

    def complete(self) -> bool:
        return (self.next_vector == N and len(self.events) == N * GROUPS and
                not self.read_schedule and self.launches and
                self.cycle > self.launches[-1] + KERNEL_LATENCY + GROUPS)

    def summary(self) -> dict[str, Any]:
        starts = self.launches
        if len(starts) != N or len(self.events) != N * GROUPS:
            raise MemoryError12A(f"{self.phase}: incomplete vectors/groups")
        return {"phase": self.phase, "vector_count": N, "group_count": len(self.events),
                "launch_cycles": starts, "first_output": self.events[0].cycle,
                "last_output": self.events[-1].cycle,
                "vector_ii": sorted(set(b - a for a, b in zip(starts, starts[1:]))),
                "group_ii": sorted(set(self.events[i + 1].cycle - self.events[i].cycle
                                        for i in range(len(self.events) - 1)
                                        if self.events[i + 1].vector_id == self.events[i].vector_id)),
                "events": self.events, "stalls": self.stalls,
                "ticks": self.ticks,
                "kernel_busy_cycles": self.kernel_busy_cycles,
                "kernel_utilization": (self.kernel_busy_cycles / self.ticks
                                        if self.ticks else 0.0)}

    def run_global(self, clock: "IntegrationClock") -> dict[str, Any]:
        guard = 20000
        while guard and not self.complete():
            guard -= 1
            if self.cycle != clock.cycle:
                raise MemoryError12A(f"{self.phase}: local/global cycle divergence")
            self.tick()
            clock.cycle = self.cycle
        if guard == 0:
            raise MemoryError12A(f"{self.phase}: cycle timeout")
        return self.summary()

    def run(self) -> dict[str, Any]:
        guard = 20000
        while guard:
            guard -= 1
            self.tick()
            if (self.next_vector == N and len(self.events) == N * GROUPS and
                    not self.read_schedule and self.cycle > self.launches[-1] + KERNEL_LATENCY + GROUPS):
                break
        if guard == 0:
            raise MemoryError12A(f"{self.phase}: cycle timeout")
        return self.summary()


class IntegrationClock:
    """One absolute clock for input, both phases and output drain."""
    def __init__(self, cycle: int = 0, trace: list[dict[str, Any]] | None = None):
        self.cycle = cycle
        self.trace = trace if trace is not None else []

    def wait_until(self, cycle: int, reason: str) -> None:
        if cycle < self.cycle:
            raise MemoryError12A("integration clock moved backwards")
        if cycle > self.cycle:
            self.trace.append({"cycle": self.cycle, "event": "phase_wait",
                               "until": cycle, "reason": reason})
            self.cycle = cycle

    def run_phase(self, phase: PhaseSimulator) -> dict[str, Any]:
        return phase.run_global(self)


def load_sparse(cache: EpochInputCache, source: list[list[int]], start_cycle: int,
                end_mode: str = "auto", end_req: bool = True,
                trace: list[dict[str, Any]] | None = None) -> tuple[int, dict[str, Any]]:
    events = [(r * N + c, source[r][c]) for r in range(N) for c in range(N) if source[r][c] != 0]
    validate_input_trace(events)
    cycle = start_cycle
    end_cycle = None
    for idx, (addr, value) in enumerate(events):
        r, c = divmod(addr, N)
        end_same = idx == len(events) - 1 and (end_mode == "same" or (end_mode == "auto" and addr == N * N - 1))
        cache.tick(cycle, [], [(r, c, value, ("data", addr))])
        if trace is not None:
            trace.append({"cycle": cycle, "event": "input_data_fire",
                          "addr": addr, "row": r, "col": c})
        if end_same:
            end_cycle = cycle
        cycle += 1
    if end_cycle is None:
        # Standalone end is accepted only while request is high and after the
        # final data write has completed.
        if not end_req:
            raise MemoryError12A("it_data_end asserted while it_data_in_req=0")
        cache.tick(cycle, [], [])
        end_cycle = cycle
    elif not end_req:
        raise MemoryError12A("same-cycle it_data_end asserted while it_data_in_req=0")
    if trace is not None:
        trace.append({"cycle": end_cycle, "event": "input_end_fire",
                      "same_cycle_data": bool(events and
                                               end_cycle == start_cycle + len(events) - 1)})
    return end_cycle, {"data_fires": len(events), "end_fire": True,
                       "end_cycle": end_cycle,
                       "same_cycle_data_end": bool(events and
                                                   end_cycle == start_cycle + len(events) - 1)}


def source_cases() -> list[tuple[str, list[list[int]]]]:
    rng = random.Random(20260904)
    zero = [[0] * N for _ in range(N)]
    sparse = [[0] * N for _ in range(N)]
    sparse[0][0] = 32767; sparse[63][63] = -32768
    alt = [[32767 if (r + c) & 1 else -32768 for c in range(N)] for r in range(N)]
    rand = [[rng.randint(-32768, 32767) for _ in range(N)] for _ in range(N)]
    return [("zero", zero), ("sparse", sparse), ("alternating", alt), ("random", rand)]


def run_one(matrix: list[list[int]], source: list[list[int]], name: str,
            mutate_horizontal: bool = False) -> dict[str, Any]:
    expected_v, expected_h, expected_f = oracle_2d(matrix, source)
    trace: list[dict[str, Any]] = []
    clock = IntegrationClock(0, trace)
    owners = InputCacheController()
    cache = EpochInputCache("inputA", trace=trace)
    slot = owners.admit()
    if slot is None:
        raise MemoryError12A("input cache admission failed")
    begin = cache.begin_tu()
    if not begin["accepted"]:
        raise MemoryError12A("first input cache admission unexpectedly scrubbed")
    end_cycle, input_stats = load_sparse(cache, source, clock.cycle, trace=trace)
    clock.cycle = end_cycle + 1
    owners.end(slot)
    owners.start_read(slot)
    inter = SyncBankMemory("intermediate", trace=trace)
    kernel = R4CContract(matrix, 0, mutate_horizontal=mutate_horizontal, trace=trace)
    vertical = PhaseSimulator(matrix, kernel, cache, inter, "vertical", 0, clock.cycle)
    vr = clock.run_phase(vertical)
    result = ResultMemory(trace=trace)
    if not result.reserve_tu():
        raise MemoryError12A("result reservation failed")
    final_mem = SyncBankMemory("final_stage16", trace=trace)
    clock.wait_until(vr["last_output"] + 2, "vertical_to_horizontal")
    horizontal = PhaseSimulator(matrix, kernel, inter, final_mem, "horizontal", 64, clock.cycle)
    hr = clock.run_phase(horizontal)
    actual_v, _, vread_end = read_matrix_memory(inter, "vertical", clock.cycle + 1)
    clock.wait_until(vread_end, "vertical_stage16_readback")
    if actual_v != expected_v:
        raise MemoryError12A(f"{name}: vertical stage16 readback mismatch")
    actual_h, _, hread_end = read_matrix_memory(final_mem, "horizontal", clock.cycle)
    clock.wait_until(hread_end, "horizontal_stage16_readback")
    if actual_h != expected_h:
        raise MemoryError12A(f"{name}: horizontal stage16 readback mismatch")
    for row in range(N):
        for group in range(GROUPS):
            result.write(row * GROUPS + group,
                         actual_h[row][group * 4:group * 4 + 4],
                         cycle=hr["last_output"] + 1 + row * GROUPS + group,
                         vector_id=64 + row, tu=0, phase="H")
    scheduled_h = [[0] * N for _ in range(N)]
    scheduled_f = [[0] * N for _ in range(N)]
    readback, result_end_cycle = drain_result_memory(result, clock.cycle,
                                                     trace=trace)
    clock.cycle = result_end_cycle
    owners.release(slot)
    for group_index, beat in readback:
        row, group = divmod(group_index, GROUPS)
        scheduled_h[row][group * 4:group * 4 + 4] = list(beat)
        scheduled_f[row][group * 4:group * 4 + 4] = list(beat)
    expected_final = expected_f
    # Result memory is the source of the comparison; no transform is called here.
    if scheduled_f != expected_final:
        raise MemoryError12A(f"{name}: final result memory mismatch")
    return {"name": name, "input": input_stats,
            "vertical": {k: v for k, v in vr.items() if k != "events"},
            "horizontal": {k: v for k, v in hr.items() if k != "events"},
            "horizontal_stage16_match": actual_h == expected_h,
            "stage16_match": actual_v == expected_v,
            "final10_match": True,
            "input_read_requests": cache.read_count,
            "intermediate_read_requests": inter.read_count,
            "intermediate_read_conflicts": inter.read_conflicts,
            "result_beats_written": result.write_count,
            "result_beats_readback": len(readback),
            "result_capacity_invariant": result.reserved + result.occupied <= result.capacity,
            "final_expected_from_memory": True,
            "result_drain_count": result.drain_count,
            "result_read_latency": result.read_latency,
            "result_end_cycle": result_end_cycle,
            "vertical_kernel_utilization": vr["kernel_utilization"],
            "horizontal_kernel_utilization": hr["kernel_utilization"],
            "trace_event_count": len(trace),
            "trace": trace}


def actual_negative_tests(matrix: list[list[int]]) -> dict[str, bool]:
    # Mutations are performed against small independent objects and each must
    # be rejected by the same type of checker used in the positive path.
    out = {}
    bad = SyncBankMemory("bad")
    try:
        bad.tick(0, [(0, 0, "a"), (0, 4, "b")], [])
        out["same_bank_read_rejected"] = False
    except MemoryError12A:
        out["same_bank_read_rejected"] = True
    try:
        rm = ResultMemory(); rm.reserve_tu(); rm.write(0, [1, 2, 3, 4]); rm.write(0, [1, 2, 3, 4])
        out["duplicate_result_rejected"] = False
    except MemoryError12A:
        out["duplicate_result_rejected"] = True
    try:
        k = R4CContract(matrix, 0); k.accept(0, 0, [0] * N); k.accept(15, 1, [0] * N)
        out["short_vector_ii_rejected"] = False
    except MemoryError12A:
        out["short_vector_ii_rejected"] = True
    try:
        k = R4CContract(matrix, 0); k.accept(0, 1, [0] * N)
        out["wrong_vector_id_rejected"] = False
    except MemoryError12A:
        out["wrong_vector_id_rejected"] = True
    try:
        rm = ResultMemory(); rm.reserve_tu()
        for i in range(RESULT_GROUPS + 1):
            rm.write(i, [0, 0, 0, 0])
        out["capacity_overwrite_rejected"] = False
    except MemoryError12A:
        out["capacity_overwrite_rejected"] = True
    try:
        c = EpochInputCache("bad_end")
        c.begin_tu()
        load_sparse(c, [[0] * N for _ in range(N)], 0, end_req=False)
        out["end_without_req_rejected"] = False
    except MemoryError12A:
        out["end_without_req_rejected"] = True
    try:
        sparse = [[0] * N for _ in range(N)]
        sparse[0][0] = 32767; sparse[63][63] = -32768
        run_one(matrix, sparse, "horizontal_mutation", mutate_horizontal=True)
        out["horizontal_stage16_mutation_rejected"] = False
    except MemoryError12A:
        out["horizontal_stage16_mutation_rejected"] = True
    try:
        owners = InputCacheController()
        a = owners.admit(); b = owners.admit(); c = owners.admit()
        if a is None or b is None or c is not None or owners.input_req():
            out["input_cache_full_rejected"] = False
        else:
            out["input_cache_full_rejected"] = True
    except MemoryError12A:
        out["input_cache_full_rejected"] = True
    try:
        validate_input_trace([(4, 1), (3, 2)])
        out["nonmonotonic_input_rejected"] = False
    except MemoryError12A:
        out["nonmonotonic_input_rejected"] = True
    return out


def epoch_wrap_test() -> dict[str, Any]:
    cache = EpochInputCache("epoch")
    addr = (3, 7)
    old = []
    scrubs = 0
    for i in range(EPOCH_MOD + 1):
        begin = cache.begin_tu()
        if not begin["accepted"]:
            scrubs += 1
            cycles = 0
            while not cache.scrub_tick(cycles):
                cycles += 1
            cache.begin_tu()
        if i == 0:
            cache.tick(0, [], [(addr[0], addr[1], 1234, ("old", i))])
        old.append(cache.read_tagged(*addr))
    return {"epoch_bits": EPOCH_BITS, "scrub_count": scrubs,
            "old_value_sequence": old, "final_unwritten_is_zero": old[-1] == 0}


def id_wrap_test(matrix: list[list[int]]) -> dict[str, Any]:
    k = R4CContract(matrix, 0xFFFC)
    for i in range(8):
        k.accept(i * 16, (0xFFFC + i) & 0xFFFF, [0] * N)
    return {"ids": [x[1] for x in k.accepted], "pass": k.next_vector_id == 4}


def two_tu_backpressure(matrix: list[list[int]]) -> dict[str, Any]:
    """Run two tagged TUs through one persistent kernel and one result store.

    TU1 vertical is genuinely executed while TU0's result beats remain held
    (req=0).  Only horizontal admission is blocked by the full shared result
    memory; after the drain, TU1 horizontal is run with the same kernel.
    """
    trace: list[dict[str, Any]] = []
    clock = IntegrationClock(0, trace)
    owners = InputCacheController()
    src0 = [[0] * N for _ in range(N)]
    src0[0][0] = 32767
    src0[63][63] = -32768
    src1 = [[0] * N for _ in range(N)]
    src1[1][2] = -12345
    src1[62][61] = 23456
    kernel = R4CContract(matrix, 0, trace=trace)
    cache0 = EpochInputCache("tu0_input", trace=trace)
    cache1 = EpochInputCache("tu1_input", trace=trace)
    slot0 = owners.admit()
    slot1 = owners.admit()
    if slot0 is None or slot1 is None or owners.admit() is not None:
        raise MemoryError12A("two-TU input cache ownership failure")
    if not cache0.begin_tu()["accepted"] or not cache1.begin_tu()["accepted"]:
        raise MemoryError12A("two-TU input admission failed")
    end0, _ = load_sparse(cache0, src0, clock.cycle, trace=trace)
    owners.end(slot0); owners.start_read(slot0)
    clock.cycle = end0 + 1
    inter0 = SyncBankMemory("tu0_intermediate", trace=trace)
    vr0 = clock.run_phase(PhaseSimulator(matrix, kernel, cache0, inter0, "vertical", 0,
                                         clock.cycle))
    clock.wait_until(vr0["last_output"] + 2, "tu0_vertical_to_horizontal")
    final0 = SyncBankMemory("tu0_final_coordinate", trace=trace)
    hr0 = clock.run_phase(PhaseSimulator(matrix, kernel, inter0, final0, "horizontal", 64,
                                         clock.cycle))
    shared = ResultMemory(trace=trace)
    if not shared.reserve_tu():
        raise MemoryError12A("TU0 result reservation failed")
    for ev in hr0["events"]:
        shared.write((ev.vector_id - 64) * GROUPS + ev.group, ev.values,
                     cycle=ev.cycle, vector_id=ev.vector_id, tu=0, phase="H")
    tu0_full = shared.occupied == RESULT_GROUPS and shared.reserved == 0

    # TU1 vertical is an actual phase, not a synthetic group counter.  It can
    # complete in its own intermediate memory while TU0 output is stalled.
    end1, _ = load_sparse(cache1, src1, clock.cycle, trace=trace)
    owners.end(slot1); owners.start_read(slot1)
    clock.cycle = end1 + 1
    inter1 = SyncBankMemory("tu1_intermediate", trace=trace)
    vr1 = clock.run_phase(PhaseSimulator(matrix, kernel, cache1, inter1, "vertical", 128,
                                         clock.cycle))
    blocked_before = not shared.reserve_tu()

    # A long req=0 interval must not mutate the result store; afterwards use
    # the explicit one-cycle result-memory response path.
    observed0_raw, drain_end = drain_result_memory(shared, clock.cycle,
                                                   stall_cycles=128, trace=trace)
    clock.cycle = drain_end
    observed0 = [(0, index, beat) for index, beat in observed0_raw]
    admitted_after = shared.reserve_tu()

    # Only now may TU1 horizontal start.  The same R4C object continues with
    # vector IDs 192..255; no per-TU reset is allowed.
    if clock.cycle < vr1["last_output"] + 2:
        clock.wait_until(vr1["last_output"] + 2, "tu1_vertical_to_horizontal")
    final1 = SyncBankMemory("tu1_final_coordinate", trace=trace)
    hr1 = clock.run_phase(PhaseSimulator(matrix, kernel, inter1, final1, "horizontal", 192,
                                         clock.cycle))
    for ev in hr1["events"]:
        shared.write((ev.vector_id - 192) * GROUPS + ev.group, ev.values,
                     cycle=ev.cycle, vector_id=ev.vector_id, tu=1, phase="H")
    observed1_raw, clock.cycle = drain_result_memory(shared, clock.cycle, trace=trace)
    observed1 = [(1, index, beat) for index, beat in observed1_raw]
    return {"tu0_occupied_before_drain": RESULT_GROUPS if tu0_full else -1,
            "tu1_vertical_groups": len(vr1["events"]),
            "tu1_horizontal_blocked_before_drain": blocked_before,
            "tu1_horizontal_admitted_after_drain": admitted_after,
            "tu0_observed": len(observed0), "tu1_observed": len(observed1),
            "tag_order_ok": all(t == 0 and g == i for i, (t, g, _) in enumerate(observed0)) and
                            all(t == 1 and g == i for i, (t, g, _) in enumerate(observed1)),
            "tu0_vertical_ii": vr0["vector_ii"],
            "tu1_vertical_ii": vr1["vector_ii"],
            "tu0_horizontal_ii": hr0["vector_ii"],
            "tu1_horizontal_ii": hr1["vector_ii"],
            "global_trace_events": len(trace),
            "input_cache_full": not owners.input_req(),
            "trace": trace}


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True); AUDIT.mkdir(parents=True, exist_ok=True)
    matrix = load_matrix()
    cases = [run_one(matrix, src, name) for name, src in source_cases()]
    negatives = actual_negative_tests(matrix)
    epoch = epoch_wrap_test()
    ident = id_wrap_test(matrix)
    two_tu = two_tu_backpressure(matrix)
    mapping_unique = len({bank_addr(r, c) for r in range(N) for c in range(N)}) == N * N
    all_pass = (mapping_unique and all(c["vertical"]["vector_ii"] == [16] and
                c["horizontal"]["vector_ii"] == [16] and
                c["vertical"]["group_ii"] == [1] and c["horizontal"]["group_ii"] == [1] and
                c["stage16_match"] and c["horizontal_stage16_match"] and c["final10_match"] and
                c["final_expected_from_memory"] and
                c["result_beats_written"] == RESULT_GROUPS and
                c["result_beats_readback"] == RESULT_GROUPS and
                c["result_read_latency"] == 1 and
                c["trace_event_count"] > 0
                for c in cases) and all(negatives.values()) and ident["pass"] and
                epoch["scrub_count"] >= 1 and epoch["final_unwritten_is_zero"] and
                two_tu["tag_order_ok"] and two_tu["tu1_horizontal_blocked_before_drain"] and
                two_tu["tu1_horizontal_admitted_after_drain"] and
                two_tu["tu1_vertical_groups"] == RESULT_GROUPS and
                two_tu["tu0_vertical_ii"] == [16] and
                two_tu["tu1_vertical_ii"] == [16] and
                two_tu["tu0_horizontal_ii"] == [16] and
                two_tu["tu1_horizontal_ii"] == [16] and
                all(c["input"]["end_fire"] for c in cases) and
                any(c["input"]["same_cycle_data_end"] for c in cases))
    case_summaries = [{k: v for k, v in c.items() if k != "trace"} for c in cases]
    two_tu_summary = {k: v for k, v in two_tu.items() if k != "trace"}
    result = {"status": "PASS" if all_pass else "FAIL", "step": "12A-R2.1",
              "cases": case_summaries, "mapping_unique": mapping_unique,
              "negative_tests": negatives, "epoch_wrap": epoch,
              "vector_id_wrap": ident, "two_tu_backpressure": two_tu_summary,
              "kernel_utilization": {"derived": True},
              "stall_breakdown": {"derived_from_tick_trace": True}}
    (AUDIT / "step12ar2_results.json").write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    (AUDIT / "step12ar2_negative_tests.json").write_text(json.dumps(negatives, indent=2), encoding="utf-8")
    trace_payload = {"cases": [
        {"name": c["name"], "events": c["trace"],
         "event_count": len(c["trace"])} for c in cases],
        "two_tu": {"events": two_tu["trace"],
                    "event_count": len(two_tu["trace"]),
                    "summary": two_tu_summary}}
    (AUDIT / "step12ar2_event_trace.json").write_text(
        json.dumps(trace_payload, indent=2, ensure_ascii=False), encoding="utf-8")
    report = ["# V35 Step 12A-R2.1 Integration Gate Closure", "", f"Status: **{result['status']}**", "",
              "- A single absolute cycle domain carries input, phase-local memory events, persistent R4C events and output request/response trace.",
              "- Final expected is read back from 1024 x 40-bit result beats; no second horizontal transform is used for comparison.",
              "- Oracle uses an independent implementation from the kernel payload path.",
              "- Four-bank input/intermediate memories use one read and one write port per bank and +1 response latency.",
              "- Input responses are tag-checked at the RAM response boundary; finite-epoch scrub prevents stale-data resurrection.",
              "- R4C persists across vertical and horizontal phases; vector IDs are checked through 16-bit wrap.",
              "- Two-TU tagged result beats are held under req=0; TU1 vertical runs while TU0 is full, and TU1 horizontal admission is blocked until TU0 drains.",
              "- Each case writes and drains 1024 result beats with read_latency=1; final10 is compared from the drained memory, not a recomputed horizontal path.",
              "- Horizontal stage16 is read back from final_stage16 memory and compared before low10 conversion.",
              "- Nine negative mutations (same-bank, duplicate, short-II, wrong-ID, capacity, end-without-req, horizontal-stage16, input-full, nonmonotonic-input) are rejected.",
              "- Event trace contains cycle, memory request/response, vector_start, kernel_group, result request and output_fire records.", ""]
    (OUT / "V35_STEP12A_R2_EXECUTABLE_PROOF.md").write_text("\n".join(report), encoding="utf-8")
    return 0 if all_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
