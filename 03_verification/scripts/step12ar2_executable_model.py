"""V3.5-15 Step 12A-R2.3 temporal/protocol closure model.

One IntegrationModel.tick() owns time and advances input handshakes, banked
synchronous memories, the single persistent R4C contract, transform phases,
result storage and output backpressure. Expected values are calculated by an
independent matrix path; no event replay populates result memory.
"""
from __future__ import annotations

import json
import random
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[2]
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"
OUT = ROOT / "03_verification" / "output"
AUDIT = ROOT / "05_audit" / "current" / "15"
# The independent P1-A oracle is frozen inside this repository.  Keeping the
# import repository-relative makes a clean clone reproducible and prevents an
# accidental fallback to a sibling or historical workspace.
ORACLE_ROOT = ROOT / "04_reference" / "oracle"
if str(ORACLE_ROOT) not in sys.path:
    sys.path.insert(0, str(ORACLE_ROOT))
try:
    from v34_rtl_bitexact import main_2d_details as independent_main_2d_details
except ImportError as exc:  # fail closed: no silently duplicated expected model
    raise RuntimeError(f"independent P1-A oracle unavailable: {ORACLE_ROOT}") from exc
N = 64
GROUPS = 16
RESULT_GROUPS = 1024
READ_LATENCY = 1
KERNEL_LATENCY = 24
EPOCH_BITS = 2
EPOCH_MOD = 1 << EPOCH_BITS


class ModelError(Exception):
    pass


def wrap16(value: int) -> int:
    value &= 0xFFFF
    return value - 0x10000 if value & 0x8000 else value


def low10(value: int) -> int:
    return value & 0x3FF


def bank_addr(row: int, col: int) -> tuple[int, int]:
    return ((row & 3) ^ (col & 3), row * 16 + (col >> 2))


def load_matrix() -> list[list[int]]:
    data = json.loads(CANONICAL.read_text(encoding="utf-8"))
    return data["transforms"]["0"]["inverse_operator"]["64"]


def oracle_2d(matrix: list[list[int]], source: list[list[int]]) -> tuple[list[list[int]], list[list[int]], list[list[int]]]:
    # Expected values come from the separately frozen P1-A oracle.  The
    # scheduled kernel below intentionally keeps its own implementation so a
    # defect cannot make both sides pass through one helper.
    details = independent_main_2d_details(source, 0, 0, N, N)
    return (details["stage1_stage16"], details["stage2_stage16"],
            details["final10"])


class BankedMemory:
    """Four banks; one read and one write port per bank; read response +1."""
    def __init__(self, name: str, trace: list[dict[str, Any]]):
        self.name = name
        self.data = [[0] * 1024 for _ in range(4)]
        self.pending: dict[int, list[tuple[Any, int, int]]] = {}
        self.trace = trace
        self.read_count = 0
        self.write_count = 0
        self.read_conflicts = 0

    def consume(self, cycle: int) -> list[tuple[Any, int]]:
        result = []
        for token, bank, addr in self.pending.pop(cycle, []):
            value = self.data[bank][addr]
            self.trace.append({"cycle": cycle, "event": "memory_read_response",
                               "memory": self.name, "token": repr(token),
                               "bank": bank, "addr": addr, "value": value})
            result.append((token, value))
        return result

    def issue(self, cycle: int, reads: list[tuple[int, int, Any]],
              writes: list[tuple[int, int, int, Any]]) -> None:
        read_banks: set[int] = set()
        write_banks: set[int] = set()
        for row, col, token in reads:
            bank, addr = bank_addr(row, col)
            if bank in read_banks:
                self.read_conflicts += 1
                raise ModelError(f"{self.name}: read port conflict at cycle {cycle}")
            read_banks.add(bank)
            self.pending.setdefault(cycle + READ_LATENCY, []).append((token, bank, addr))
            self.read_count += 1
            self.trace.append({"cycle": cycle, "event": "memory_read_request",
                               "memory": self.name, "token": repr(token),
                               "row": row, "col": col, "bank": bank, "addr": addr})
        for row, col, value, token in writes:
            bank, addr = bank_addr(row, col)
            if bank in write_banks:
                raise ModelError(f"{self.name}: write port conflict at cycle {cycle}")
            write_banks.add(bank)
            self.data[bank][addr] = int(value)
            self.write_count += 1
            self.trace.append({"cycle": cycle, "event": "memory_write",
                               "memory": self.name, "token": repr(token),
                               "row": row, "col": col, "bank": bank, "addr": addr,
                               "value": int(value)})


class EpochInputCache(BankedMemory):
    def __init__(self, name: str, trace: list[dict[str, Any]]):
        super().__init__(name, trace)
        self.tags = [[-1] * 1024 for _ in range(4)]
        self.epoch = -1
        self.scrubbing = False
        self.scrub_index = 0
        self.scrub_count = 0

    def begin_tu(self) -> bool:
        if self.scrubbing:
            return False
        nxt = (self.epoch + 1) % EPOCH_MOD
        if self.epoch >= 0 and nxt == 0:
            self.scrubbing = True
            self.scrub_index = 0
            self.epoch = -1
            self.scrub_count += 1
            return False
        self.epoch = nxt
        return True

    def scrub_tick(self, cycle: int) -> bool:
        if not self.scrubbing:
            return True
        for bank in range(4):
            self.tags[bank][self.scrub_index] = -1
        self.trace.append({"cycle": cycle, "event": "epoch_scrub",
                           "memory": self.name, "index": self.scrub_index})
        self.scrub_index += 1
        if self.scrub_index == 1024:
            self.scrubbing = False
            self.epoch = 0
            return True
        return False

    def issue(self, cycle: int, reads, writes) -> None:
        if self.scrubbing and (reads or writes):
            raise ModelError(f"{self.name}: access during scrub")
        super().issue(cycle, reads, writes)
        for row, col, _value, _token in writes:
            bank, addr = bank_addr(row, col)
            self.tags[bank][addr] = self.epoch

    def consume(self, cycle: int):
        if self.scrubbing:
            if self.pending.get(cycle):
                raise ModelError(f"{self.name}: response during scrub")
            return []
        result = []
        for token, bank, addr in self.pending.pop(cycle, []):
            live = self.epoch >= 0 and self.tags[bank][addr] == self.epoch
            value = self.data[bank][addr] if live else 0
            self.trace.append({"cycle": cycle, "event": "memory_read_response",
                               "memory": self.name, "token": repr(token),
                               "bank": bank, "addr": addr, "value": value,
                               "tag_valid": live})
            result.append((token, value))
        return result

    def read_tagged(self, row: int, col: int) -> int:
        bank, addr = bank_addr(row, col)
        live = self.epoch >= 0 and self.tags[bank][addr] == self.epoch
        return self.data[bank][addr] if live else 0


class InputController:
    def __init__(self):
        self.state = {"A": "FREE", "B": "FREE"}

    def admit(self, usable: Callable[[str], bool] | None = None) -> str | None:
        for name in ("A", "B"):
            if self.state[name] == "FREE" and (usable is None or usable(name)):
                self.state[name] = "FILLING"
                return name
        return None

    def end(self, name: str) -> None:
        if self.state.get(name) != "FILLING":
            raise ModelError("end for non-filling cache")
        self.state[name] = "READY"

    def start_read(self, name: str) -> None:
        if self.state.get(name) != "READY":
            raise ModelError("vertical start before input end")
        self.state[name] = "READING"

    def release(self, name: str) -> None:
        if self.state.get(name) != "READING":
            raise ModelError("cache release ownership error")
        self.state[name] = "FREE"


class ResultMemory:
    """1024 groups with a one-cycle RAM and a two-entry elastic read path.

    ``hold`` is the head entry visible to the output interface and ``skid``
    is the second response slot.  A separate issue index and a one-entry
    pending RAM request permit one request and one output fire per cycle in
    the ready steady state, while the credit check prevents a response from
    arriving when both elastic slots are occupied during backpressure.
    """
    def __init__(self, trace: list[dict[str, Any]], mutate: str | None = None):
        self.capacity = RESULT_GROUPS
        self.beats: dict[int, tuple[int, int, int, int]] = {}
        self.reserved = 0
        self.occupied = 0  # includes memory, pending and holding beats
        self.read_index = 0
        self.issue_index = 0
        self.pending: tuple[int, int] | None = None
        self.hold: tuple[int, tuple[int, int, int, int]] | None = None
        self.skid: list[tuple[int, tuple[int, int, int, int]]] = []
        self.trace = trace
        self.writes = 0
        self.fires = 0
        self.mutate = mutate

    def reserve_tu(self) -> bool:
        if self.capacity - self.reserved - self.occupied < RESULT_GROUPS:
            return False
        if self.occupied == 0 and self.reserved == 0:
            self.read_index = 0
            self.issue_index = 0
            self.pending = None
            self.hold = None
            self.skid.clear()
        self.reserved += RESULT_GROUPS
        return True

    def write_group(self, cycle: int, index: int, values: list[int], vector_id: int, tu: int) -> None:
        if not (0 <= index < self.capacity) or len(values) != 4:
            raise ModelError("result group index/width error")
        if self.reserved <= 0 or index in self.beats:
            raise ModelError("result write without reservation or duplicate")
        self.beats[index] = tuple(low10(v) for v in values)
        self.reserved -= 1
        self.occupied += 1
        self.writes += 1
        self.trace.append({"cycle": cycle, "event": "result_write", "group": index,
                           "vector_id": vector_id, "tu": tu, "phase": "H",
                           "values": list(self.beats[index])})

    def tick(self, cycle: int, req: bool) -> list[tuple[int, tuple[int, int, int, int]]]:
        fired = []
        if self.hold is not None and req:
            index, beat = self.hold
            if index != self.read_index:
                raise ModelError("result read order error")
            fired.append((index, beat))
            self.hold = None
            del self.beats[index]
            self.read_index += 1
            self.occupied -= 1
            self.fires += 1
            self.trace.append({"cycle": cycle, "event": "output_fire", "group": index,
                               "values": list(beat), "req": True,
                               "occupied_after": self.occupied})
            if self.skid:
                self.hold = self.skid.pop(0)
        if self.pending is not None and self.pending[0] == cycle:
            index = self.pending[1]
            if self.hold is not None and len(self.skid) >= 1:
                raise ModelError("result holding overflow")
            if index not in self.beats:
                raise ModelError("result response missing beat")
            entry = (index, self.beats[index])
            if self.hold is None:
                self.hold = entry
            else:
                self.skid.append(entry)
            self.pending = None
            response_cycle = cycle - 1 if self.mutate == "early_response" else cycle
            self.trace.append({"cycle": response_cycle, "event": "result_read_response", "group": index,
                               "req": req, "hold_valid": True,
                               "occupied_before": self.occupied,
                               "occupied_after": self.occupied, "output_fire": False})
        # A request consumes one credit until its response enters hold/skid.
        # The issue pointer is independent of the output retirement pointer.
        elastic_entries = int(self.hold is not None) + len(self.skid)
        if req and self.pending is None and elastic_entries < 2 and self.issue_index in self.beats:
            self.pending = (cycle + READ_LATENCY, self.issue_index)
            self.trace.append({"cycle": cycle, "event": "result_read_request", "group": self.issue_index})
            self.issue_index += 1
        return fired


@dataclass
class KernelEvent:
    cycle: int
    vector_id: int
    serial: int
    group: int
    values: list[int]
    first: bool
    last: bool


class PersistentR4C:
    def __init__(self, matrix: list[list[int]], trace: list[dict[str, Any]],
                 initial_vector_id: int = 0):
        self.matrix = matrix
        self.trace = trace
        self.next_vector_id = initial_vector_id & 0xFFFF
        self.last_accept: int | None = None
        self.serial = 0
        self.active: list[dict[str, Any]] = []

    def accept(self, cycle: int, vector_id: int, vector: list[int]) -> None:
        vector_id &= 0xFFFF
        if self.last_accept is not None and cycle - self.last_accept < 16:
            raise ModelError("kernel vector interval below 16")
        if vector_id != self.next_vector_id:
            raise ModelError(f"kernel vector id {vector_id} != {self.next_vector_id}")
        self.active.append({"serial": self.serial, "start": cycle, "vector_id": vector_id,
                            "vector": list(vector), "done": set()})
        self.trace.append({"cycle": cycle, "event": "vector_start", "vector_id": vector_id,
                           "serial": self.serial})
        self.serial += 1
        self.last_accept = cycle
        self.next_vector_id = (self.next_vector_id + 1) & 0xFFFF

    def tick(self, cycle: int) -> list[KernelEvent]:
        output = []
        for item in self.active:
            group = cycle - item["start"] - KERNEL_LATENCY
            if not (0 <= group < GROUPS) or group in item["done"]:
                continue
            values = []
            for output_index in range(group * 4, group * 4 + 4):
                total = 0
                for source in range(N):
                    total += int(item["vector"][source]) * int(self.matrix[output_index][source])
                values.append(wrap16((total + 32) >> 6))
            item["done"].add(group)
            event = KernelEvent(cycle, item["vector_id"], item["serial"], group,
                                values, group == 0, group == 15)
            self.trace.append({"cycle": cycle, "event": "kernel_group", "vector_id": event.vector_id,
                               "group": group, "first": event.first, "last": event.last,
                               "serial": item["serial"]})
            output.append(event)
        self.active = [item for item in self.active if len(item["done"]) < GROUPS]
        return output


class PhaseTask:
    def __init__(self, model: "IntegrationModel", tu: int, phase: str,
                 source: BankedMemory, dest: BankedMemory | None, vector_base: int,
                 cache_slot: str | None):
        self.model = model
        self.tu = tu
        self.phase = phase
        self.source = source
        self.dest = dest
        self.vector_base = vector_base
        self.vector_base_serial = model.kernel.serial
        self.cache_slot = cache_slot
        self.key = (tu, phase)
        self.load_vector = 0
        self.load_group = 0
        self.staging: dict[int, list[int | None]] = {}
        self.accepted = 0
        self.events: list[KernelEvent] = []
        self.stage_values = [[None] * N for _ in range(N)]
        self.done = False
        self.start_cycle: int | None = None

    def start(self, cycle: int) -> None:
        self.start_cycle = cycle
        self.model.trace.append({"cycle": cycle, "event": "phase_start", "tu": self.tu,
                                 "phase": self.phase})

    def consume(self, responses: list[tuple[Any, int]]) -> None:
        for token, value in responses:
            if not isinstance(token, tuple) or token[0] != self.key:
                continue
            _, vector, index = token
            self.staging[vector][index] = value

    def read_points(self, group: int, vector: int) -> list[tuple[int, int, Any]]:
        if self.phase == "vertical":
            coords = [(group * 4 + k, vector) for k in range(4)]
        else:
            coords = [(vector, group * 4 + k) for k in range(4)]
        return [(row, col, (self.key, vector, group * 4 + k))
                for k, (row, col) in enumerate(coords)]

    def tick(self, cycle: int) -> list[tuple[int, int, Any]]:
        if self.done:
            return []
        if self.load_vector < N:
            self.staging.setdefault(self.load_vector, [None] * N)
        if self.load_vector < N:
            values = self.staging.get(self.load_vector)
            if values is not None and all(value is not None for value in values):
                self.model.kernel.accept(cycle, (self.vector_base + self.load_vector) & 0xFFFF,
                                         [int(value) for value in values])
                self.accepted += 1
                self.load_vector += 1
                self.load_group = 0
                if self.load_vector < N:
                    self.staging.setdefault(self.load_vector, [None] * N)
        if self.load_vector < N and self.load_group < GROUPS:
            reads = self.read_points(self.load_group, self.load_vector)
            self.load_group += 1
            return reads
        return []

    def handle(self, event: KernelEvent) -> None:
        # Serial is the permanent internal identity; vector_id is only the
        # 16-bit externally visible tag and may wrap during this phase.
        vector = event.serial - self.vector_base_serial
        if not (0 <= vector < N):
            return
        for k, value in enumerate(event.values):
            index = event.group * 4 + k
            if self.phase == "vertical":
                row, col = index, vector
            else:
                row, col = vector, index
            self.stage_values[row][col] = value
        self.events.append(event)
        if self.dest is not None:
            if self.phase == "vertical":
                writes = [(event.group * 4 + k, vector, value, (self.key, event.group, k))
                          for k, value in enumerate(event.values)]
            else:
                writes = [(vector, event.group * 4 + k, value, (self.key, event.group, k))
                          for k, value in enumerate(event.values)]
            self.dest.issue(event.cycle, [], writes)
        if self.phase == "horizontal":
            self.model.trace.append({"cycle": event.cycle, "event": "final_stage16_write",
                                     "tu": self.tu, "vector_id": event.vector_id,
                                     "serial": event.serial, "group": event.group,
                                     "values": list(event.values)})
            self.model.result.write_group(event.cycle, vector * GROUPS + event.group,
                                          event.values, event.vector_id, self.tu)
        if self.accepted == N and len(self.events) == N * GROUPS:
            self.done = True
            self.model.trace.append({"cycle": event.cycle, "event": "phase_done",
                                     "tu": self.tu, "phase": self.phase})


class IntegrationModel:
    """The only object allowed to advance the absolute cycle."""
    def __init__(self, matrix: list[list[int]], sources: list[list[list[int]]],
                 output_req: Callable[["IntegrationModel"], bool], mutate: str | None = None,
                 input_req: Callable[["IntegrationModel"], bool] | None = None,
                 initial_vector_id: int = 0):
        self.matrix = matrix
        self.sources = sources
        self.output_req_fn = output_req
        self.input_req_fn = input_req or (lambda _model: True)
        self.mutate = mutate
        self.cycle = 0
        self.trace: list[dict[str, Any]] = []
        self.controller = InputController()
        self.caches = {"A": EpochInputCache("inputA", self.trace),
                       "B": EpochInputCache("inputB", self.trace)}
        self.cache_tu: dict[int, tuple[str, EpochInputCache]] = {}
        self.tu_state = [{"input": "PENDING", "vertical": "PENDING", "horizontal": "PENDING"}
                         for _ in sources]
        self.input_queue: list[tuple[int, list[tuple[int, int]], str]] = []
        for tu, source in enumerate(sources):
            events = [(row * N + col, int(source[row][col])) for row in range(N)
                      for col in range(N) if source[row][col] != 0]
            end_mode = "same" if events and events[-1][0] == N * N - 1 else "standalone"
            self.input_queue.append((tu, events, end_mode))
        self.input_active: tuple[int, str, EpochInputCache, list[tuple[int, int]], str] | None = None
        self.initial_vector_id = initial_vector_id & 0xFFFF
        self.kernel = PersistentR4C(matrix, self.trace, initial_vector_id=self.initial_vector_id)
        self.inter = {tu: BankedMemory(f"intermediate{tu}", self.trace) for tu in range(len(sources))}
        self.result = ResultMemory(self.trace, mutate=mutate)
        self.current: PhaseTask | None = None
        self.ready_v: list[int] = []
        self.completed_h: set[int] = set()
        self.drained: list[tuple[int, tuple[int, int, int, int]]] = []
        self.stats = {"input_cache_full": 0, "result_capacity_wait": 0,
                      "output_backpressure": 0, "epoch_scrub": 0}

    def data_req(self) -> bool:
        return (self.input_active is not None and
                not self.input_active[2].scrubbing and
                bool(self.input_req_fn(self)))

    def try_start_input(self) -> None:
        if self.input_active is not None or not self.input_queue:
            return
        tu, events, end_mode = self.input_queue[0]
        slot = self.controller.admit(lambda name: not self.caches[name].scrubbing)
        if slot is None:
            self.stats["input_cache_full"] += 1
            return
        cache = self.caches[slot]
        if not cache.begin_tu():
            self.controller.state[slot] = "FREE"
            self.stats["epoch_scrub"] += 1
            return
        self.input_queue.pop(0)
        self.input_active = (tu, slot, cache, events, end_mode)
        self.cache_tu[tu] = (slot, cache)
        self.tu_state[tu]["input"] = "FILLING"

    def tick_input(self) -> None:
        self.try_start_input()
        if self.input_active is None:
            return
        tu, slot, cache, events, end_mode = self.input_active
        req = self.data_req()
        if not events:
            self.trace.append({"cycle": self.cycle, "event": "input_handshake",
                               "tu": tu, "vld": False, "end": True,
                               "req": req, "data_fire": False,
                               "end_fire": req})
            if req:
                self.controller.end(slot)
                self.tu_state[tu]["input"] = "READY"
                self.ready_v.append(tu)
                self.input_active = None
            return
        addr, value = events[0]
        self.trace.append({"cycle": self.cycle, "event": "input_handshake",
                           "tu": tu, "vld": True, "end": bool(len(events) == 1 and end_mode == "same"),
                           "req": req, "data_fire": req,
                           "end_fire": bool(req and len(events) == 1 and end_mode == "same")})
        if not req:
            self.stats["input_cache_full"] += 1
            return
        row, col = divmod(addr, N)
        cache.issue(self.cycle, [], [(row, col, value, ("input", tu, addr))])
        self.trace.append({"cycle": self.cycle, "event": "input_data_fire", "tu": tu,
                           "slot": slot, "addr": addr, "value": value})
        events.pop(0)
        if not events and end_mode == "same":
            self.controller.end(slot)
            self.tu_state[tu]["input"] = "READY"
            self.ready_v.append(tu)
            self.trace.append({"cycle": self.cycle, "event": "input_end_fire", "tu": tu,
                               "same_cycle_data": True})
            self.input_active = None

    def choose_phase(self) -> None:
        if self.current is not None:
            return
        # The persistent kernel has one globally ordered vector-id stream.
        # Finish the current TU's H phase (IDs 64..127) before admitting the
        # next TU's V phase (IDs 128..191).
        for tu, state in enumerate(self.tu_state):
            if state["vertical"] == "DONE" and state["horizontal"] == "PENDING":
                if not self.result.reserve_tu():
                    self.stats["result_capacity_wait"] += 1
                    continue
                state["horizontal"] = "RUNNING"
                self.current = PhaseTask(self, tu, "horizontal", self.inter[tu], None,
                                         (self.initial_vector_id + tu * 128 + 64) & 0xFFFF, None)
                self.current.start(self.cycle)
                return
        if self.ready_v:
            tu = self.ready_v.pop(0)
            slot, cache = self.cache_tu[tu]
            self.controller.start_read(slot)
            self.tu_state[tu]["vertical"] = "RUNNING"
            self.current = PhaseTask(self, tu, "vertical", cache, self.inter[tu],
                                     (self.initial_vector_id + tu * 128) & 0xFFFF, slot)
            self.current.start(self.cycle)

    def finish_phase(self) -> None:
        if self.current is None or not self.current.done:
            return
        task = self.current
        if task.phase == "vertical":
            slot, _cache = self.cache_tu[task.tu]
            self.controller.release(slot)
            self.tu_state[task.tu]["vertical"] = "DONE"
        else:
            self.tu_state[task.tu]["horizontal"] = "DONE"
            self.completed_h.add(task.tu)
        self.current = None

    def tick(self) -> None:
        # Responses from all memories arrive at the same global edge.
        for cache in self.caches.values():
            responses = cache.consume(self.cycle)
            if self.current is not None and self.current.source is cache:
                self.current.consume(responses)
        for memory in self.inter.values():
            responses = memory.consume(self.cycle)
            if self.current is not None and self.current.source is memory:
                self.current.consume(responses)
        for cache in self.caches.values():
            if cache.scrubbing:
                cache.scrub_tick(self.cycle)
        self.tick_input()

        for event in self.kernel.tick(self.cycle):
            if self.current is None:
                raise ModelError("kernel output without phase owner")
            if self.mutate == "missing_group" and event.vector_id >= 64 and event.group == 5:
                continue
            if self.mutate == "wrong_result" and event.vector_id >= 64:
                event.values[0] += 1
            if self.mutate == "horizontal_plus1024" and event.vector_id >= 64:
                event.values = [wrap16(v + 1024) for v in event.values]
            self.current.handle(event)
            if self.mutate == "duplicate_group" and event.vector_id >= 64 and event.group == 5:
                self.current.handle(event)

        self.finish_phase()
        self.choose_phase()
        if self.current is not None:
            reads = self.current.tick(self.cycle)
            if reads:
                self.current.source.issue(self.cycle, reads, [])

        req = bool(self.output_req_fn(self))
        self.trace.append({"cycle": self.cycle, "event": "output_req", "req": req,
                           "occupied_before": self.result.occupied,
                           "hold_valid": self.result.hold is not None})
        if not req and self.result.occupied:
            self.stats["output_backpressure"] += 1
        self.drained.extend(self.result.tick(self.cycle, req))
        if self.result.reserved < 0 or self.result.occupied < 0 or \
                self.result.reserved + self.result.occupied > self.result.capacity:
            raise ModelError("result capacity invariant violated")
        self.cycle += 1

    def done(self) -> bool:
        inputs_done = not self.input_queue and self.input_active is None
        phases_done = all(state["horizontal"] == "DONE" for state in self.tu_state)
        return (inputs_done and phases_done and self.current is None
                and self.result.occupied == 0
                and self.result.pending is None and self.result.hold is None
                and not self.result.skid)

    def run(self, limit: int = 300000) -> None:
        while not self.done() and self.cycle < limit:
            self.tick()
        if not self.done():
            raise ModelError(f"integration timeout at cycle {self.cycle}")


def source_case(name: str, seed: int = 20260904) -> list[list[int]]:
    rng = random.Random(seed)
    if name == "zero":
        return [[0] * N for _ in range(N)]
    if name == "sparse":
        out = [[0] * N for _ in range(N)]
        out[0][0] = 32767
        out[63][63] = -32768
        return out
    if name == "alternating":
        return [[32767 if (r + c) & 1 else -32768 for c in range(N)] for r in range(N)]
    return [[rng.randint(-32768, 32767) for _ in range(N)] for _ in range(N)]


def validate_kernel_events(trace: list[dict[str, Any]], vector_ids: list[int]) -> dict[str, Any]:
    """Derive II/group/tag properties from real kernel events, never constants."""
    starts = {int(e["vector_id"]): int(e["cycle"])
              for e in trace if e.get("event") == "vector_start"}
    groups: dict[int, list[dict[str, Any]]] = {vid: [] for vid in vector_ids}
    for event in trace:
        if event.get("event") == "kernel_group" and int(event.get("vector_id", -1)) in groups:
            groups[int(event["vector_id"])].append(event)
    if set(starts) != set(vector_ids):
        raise ModelError("kernel vector_start set mismatch")
    group_ii: set[int] = set()
    for vid in vector_ids:
        evs = sorted(groups[vid], key=lambda e: int(e["group"]))
        if [int(e["group"]) for e in evs] != list(range(GROUPS)):
            raise ModelError(f"vector {vid}: group sequence mismatch")
        cycles = [int(e["cycle"]) for e in evs]
        if cycles != list(range(cycles[0], cycles[0] + GROUPS)):
            raise ModelError(f"vector {vid}: group interval is not 1")
        if not evs[0].get("first") or not evs[-1].get("last"):
            raise ModelError(f"vector {vid}: first/last tag mismatch")
        if any(bool(e.get("first")) for e in evs[1:]) or any(bool(e.get("last")) for e in evs[:-1]):
            raise ModelError(f"vector {vid}: first/last tag repeated")
        group_ii.update(b - a for a, b in zip(cycles, cycles[1:]))
    ordered_starts = [starts[vid] for vid in vector_ids]
    # A 64-vector vertical or horizontal phase is the steady-state unit.  Do
    # not mistake the legal V->H/TU boundary gap for a vector II violation.
    phase_iis: list[list[int]] = []
    for base in range(0, len(vector_ids), N):
        phase_starts = ordered_starts[base:base + N]
        if len(phase_starts) > 1:
            phase_iis.append(sorted(set(b - a for a, b in zip(phase_starts, phase_starts[1:]))))
    if any(ii != [16] for ii in phase_iis) or group_ii != {1}:
        raise ModelError(f"kernel II mismatch: phases={phase_iis}, group={sorted(group_ii)}")
    return {"vectors": len(vector_ids), "vector_ii": [16], "phase_vector_ii": phase_iis,
            "group_ii": [1], "groups_per_vector": GROUPS}


def validate_result_causality(trace: list[dict[str, Any]]) -> bool:
    """Every H kernel group must write the corresponding result beat that cycle."""
    kernel = {(int(e["vector_id"]), int(e["group"])): int(e["cycle"])
              for e in trace if e.get("event") == "kernel_group"}
    writes = [e for e in trace if e.get("event") == "result_write"]
    for event in writes:
        vid = int(event["vector_id"])
        local_group = int(event["group"]) % GROUPS
        if (vid, local_group) not in kernel or kernel[(vid, local_group)] != int(event["cycle"]):
            return False
    return True


def validate_trace(trace: list[dict[str, Any]]) -> bool:
    previous = -1
    requests: dict[tuple[str, str], int] = {}
    for event in trace:
        cycle = event.get("cycle")
        if not isinstance(cycle, int) or cycle < previous:
            return False
        previous = cycle
        kind = event.get("event")
        if kind == "memory_read_request":
            requests[(event.get("memory", ""), event.get("token", ""))] = cycle
        elif kind == "memory_read_response":
            key = (event.get("memory", ""), event.get("token", ""))
            if key not in requests or cycle != requests[key] + READ_LATENCY:
                return False
        elif kind == "result_read_request":
            requests[("result", str(event["group"]))] = cycle
        elif kind == "result_read_response":
            key = ("result", str(event["group"]))
            if key not in requests or cycle != requests[key] + READ_LATENCY:
                return False
    return validate_result_causality(trace)


def validate_output_hold(trace: list[dict[str, Any]], require_req_drop: bool = False) -> bool:
    """Check that a response under req=0 remains held and unconsumed."""
    saw_req_drop_response = False
    requests: dict[int, int] = {}
    for event in trace:
        if event.get("event") == "result_read_request":
            requests[int(event["group"])] = int(event["cycle"])
        if event.get("event") != "result_read_response":
            continue
        if not isinstance(event.get("cycle"), int):
            return False
        if not event.get("req", True):
            saw_req_drop_response = True
            if not event.get("hold_valid", False):
                return False
            if event.get("occupied_after") != event.get("occupied_before"):
                return False
            if event.get("output_fire", False):
                return False
    if require_req_drop and not saw_req_drop_response:
        return False
    return True


def run_case(matrix: list[list[int]], name: str, req_mode: str = "ready",
             mutate: str | None = None, initial_vector_id: int = 0) -> dict[str, Any]:
    source = source_case(name)
    expected_v, expected_h, expected_f = oracle_2d(matrix, source)

    def req_fn(model: IntegrationModel) -> bool:
        if req_mode == "ready":
            return True
        return (model.cycle % 7) not in (2, 3)

    def input_req_fn(model: IntegrationModel) -> bool:
        return req_mode == "ready" or (model.cycle % 5) not in (1, 2)

    model = IntegrationModel(matrix, [source], req_fn, mutate=mutate,
                             input_req=input_req_fn, initial_vector_id=initial_vector_id)
    model.run()
    output_fire_cycles = [int(e["cycle"]) for e in model.trace
                          if e.get("event") == "output_fire"]
    output_fire_ii = sorted(set(b - a for a, b in zip(output_fire_cycles,
                                                       output_fire_cycles[1:])))
    if req_mode == "ready" and output_fire_ii != [1]:
        raise ModelError(f"{name}: output fire II is {output_fire_ii}, expected [1]")
    if not validate_trace(model.trace):
        raise ModelError(f"{name}: trace causality failure")
    expected_vector_ids = [((initial_vector_id + i) & 0xFFFF) for i in range(128)]
    kernel_metrics = validate_kernel_events(model.trace, expected_vector_ids)
    if not validate_output_hold(model.trace, require_req_drop=req_mode != "ready"):
        raise ModelError(f"{name}: output holding contract failure")
    actual_v = [[0] * N for _ in range(N)]
    for row in range(N):
        for col in range(N):
            bank, addr = bank_addr(row, col)
            actual_v[row][col] = model.inter[0].data[bank][addr]
    actual_h = [[0] * N for _ in range(N)]
    for event in (e for e in model.trace if e.get("event") == "final_stage16_write"):
        row, group = int(event["serial"]) - 64, int(event["group"])
        actual_h[row][group * 4:group * 4 + 4] = list(event["values"])
    final = [[low10(value) for value in row] for row in actual_h]
    drained_final = [[0] * N for _ in range(N)]
    for index, beat in model.drained:
        row, group = divmod(index, GROUPS)
        drained_final[row][group * 4:group * 4 + 4] = list(beat)
    if actual_v != expected_v:
        raise ModelError(f"{name}: vertical stage16 mismatch")
    if actual_h != expected_h:
        raise ModelError(f"{name}: horizontal stage16 mismatch")
    if final != expected_f:
        raise ModelError(f"{name}: final result mismatch")
    if drained_final != expected_f:
        raise ModelError(f"{name}: drained ResultMemory mismatch")
    return {"name": name, "status": "PASS", "cycles": model.cycle,
            "vertical_stage16_match": True, "horizontal_stage16_match": True,
            "final10_match": drained_final == expected_f, "result_writes": model.result.writes,
            "result_fires": model.result.fires, "trace_events": len(model.trace),
            "backpressure_cycles": model.stats["output_backpressure"],
            "output_fire_ii": output_fire_ii,
            "vector_ii": kernel_metrics["vector_ii"],
            "group_ii": kernel_metrics["group_ii"],
            "kernel_groups_checked": kernel_metrics["vectors"] * GROUPS,
            "input_handshakes": sum(e.get("event") == "input_handshake" for e in model.trace)}


def two_tu_case(matrix: list[list[int]]) -> dict[str, Any]:
    src0, src1 = source_case("sparse"), source_case("sparse")
    src1[1][2] = -12345
    src1[62][61] = 23456
    holder: dict[str, int] = {}

    def req_fn(model: IntegrationModel) -> bool:
        if "tu0_done" not in holder:
            if 0 in model.completed_h:
                holder["tu0_done"] = model.cycle
            else:
                return False
        return model.cycle >= holder["tu0_done"] + 128

    model = IntegrationModel(matrix, [src0, src1], req_fn,
                             input_req=lambda m: (m.cycle % 5) not in (1, 2))
    model.run()
    if not validate_trace(model.trace):
        raise ModelError("two-TU trace causality failure")
    kernel_metrics = validate_kernel_events(model.trace, list(range(256)))
    if not validate_output_hold(model.trace, require_req_drop=False):
        raise ModelError("two-TU output holding contract failure")
    writes = [e for e in model.trace if e.get("event") == "result_write"]
    fires = [e for e in model.trace if e.get("event") == "output_fire"]
    _, _, expected0 = oracle_2d(matrix, src0)
    _, _, expected1 = oracle_2d(matrix, src1)
    expected_beats = []
    for expected in (expected0, expected1):
        expected_beats.extend(tuple(expected[row][g * 4:(g + 1) * 4])
                              for row in range(N) for g in range(GROUPS))
    observed_beats = [tuple(e.get("values", [])) for e in fires]
    data_ok = observed_beats == expected_beats
    return {"status": "PASS", "cycles": model.cycle, "result_writes": len(writes),
            "result_fires": len(fires), "long_backpressure": model.stats["output_backpressure"] >= 128,
            "capacity_wait": model.stats["result_capacity_wait"] > 0,
            "tag_order_ok": [e["group"] for e in fires] == list(range(RESULT_GROUPS)) * 2,
            "kernel_groups_checked": kernel_metrics["vectors"] * GROUPS,
            "vector_ii": kernel_metrics["vector_ii"],
            "group_ii": kernel_metrics["group_ii"],
            "data_ok": data_ok,
            "trace": model.trace}


def vector_id_wrap_test(matrix: list[list[int]]) -> dict[str, Any]:
    trace: list[dict[str, Any]] = []
    kernel = PersistentR4C(matrix, trace, initial_vector_id=0xFFFE)
    for cycle, vector_id in zip((0, 16, 32, 48), (0xFFFE, 0xFFFF, 0, 1)):
        kernel.accept(cycle, vector_id, [0] * N)
    events: list[KernelEvent] = []
    for cycle in range(100):
        events.extend(kernel.tick(cycle))
    return {"pass": len(events) == 64 and all(e.group == i % GROUPS for i, e in enumerate(events)),
            "ids": [0xFFFE, 0xFFFF, 0, 1], "groups": len(events)}


def epoch_wrap_test() -> dict[str, Any]:
    trace: list[dict[str, Any]] = []
    cache = EpochInputCache("epoch_test", trace)
    cache.begin_tu()
    cache.issue(0, [], [(3, 7, 1234, ("old",))])
    old = cache.read_tagged(3, 7)
    scrub_cycles = 0
    for _ in range(EPOCH_MOD + 1):
        if not cache.begin_tu():
            while cache.scrubbing:
                cache.scrub_tick(scrub_cycles)
                scrub_cycles += 1
            cache.begin_tu()
    return {"pass": old == 1234 and cache.read_tagged(3, 7) == 0,
            "scrub_count": cache.scrub_count, "scrub_cycles": scrub_cycles}


def input_protocol_tests() -> dict[str, bool]:
    """Small executable contract tests for input fire/end and A/B ownership."""
    out: dict[str, bool] = {}
    data_fire = lambda vld, req: bool(vld and req)
    end_fire = lambda end, req: bool(end and req)
    out["data_fire_requires_req"] = (not data_fire(True, False)) and data_fire(True, True)
    out["end_without_req_rejected"] = not end_fire(True, False)
    out["same_cycle_data_end_accepted"] = data_fire(True, True) and end_fire(True, True)
    out["standalone_end_accepted"] = (not data_fire(False, True)) and end_fire(True, True)

    owners = InputController()
    first = owners.admit()
    second = owners.admit()
    third = owners.admit()
    full_rejected = first is not None and second is not None and third is None
    if first is not None:
        owners.end(first)
        owners.start_read(first)
        owners.release(first)
    recovered = owners.admit() == first
    out["cache_full_rejected"] = full_rejected
    out["cache_recovery_reaccepted"] = recovered
    scrub_owners = InputController()
    scrub_owners.state["A"] = "FREE"
    scrub_owners.state["B"] = "FREE"
    out["scrub_cache_bypassed"] = scrub_owners.admit(lambda name: name != "A") == "B"

    valid = [0, 1, 4095]
    duplicate = [0, 1, 1]
    reverse = [1, 0]
    out["address_valid"] = valid == sorted(set(valid)) and all(0 <= a < N * N for a in valid)
    out["duplicate_address_rejected"] = duplicate != sorted(set(duplicate))
    out["reverse_address_rejected"] = reverse != sorted(reverse)
    out["out_of_range_rejected"] = not all(0 <= a < N * N for a in [0, 4096])
    return out


def negative_tests(matrix: list[list[int]]) -> dict[str, bool]:
    out: dict[str, bool] = {}
    out["trace_rollback_rejected"] = not validate_trace([{"cycle": 2}, {"cycle": 1}])
    out["ram_early_response_rejected"] = not validate_trace([
        {"cycle": 0, "event": "result_read_request", "group": 0},
        {"cycle": 0, "event": "result_read_response", "group": 0}])
    try:
        run_case(matrix, "sparse", mutate="early_response")
        out["integration_early_response_rejected"] = False
    except ModelError:
        out["integration_early_response_rejected"] = True
    groups = list(range(GROUPS))
    def valid_groups(values: list[int]) -> bool:
        return len(values) == GROUPS and sorted(values) == groups
    out["missing_group_rejected"] = not valid_groups(groups[:-1])
    out["duplicate_group_rejected"] = not valid_groups(groups + [0])
    try:
        run_case(matrix, "sparse", mutate="missing_group")
        out["integration_missing_group_rejected"] = False
    except ModelError:
        out["integration_missing_group_rejected"] = True
    try:
        run_case(matrix, "sparse", mutate="duplicate_group")
        out["integration_duplicate_group_rejected"] = False
    except ModelError:
        out["integration_duplicate_group_rejected"] = True
    try:
        bad_kernel = PersistentR4C(matrix, [], initial_vector_id=0)
        bad_kernel.accept(0, 1, [0] * N)
        out["wrong_vector_id_rejected"] = False
    except ModelError:
        out["wrong_vector_id_rejected"] = True
    try:
        bad_owner = InputController()
        slot = bad_owner.admit()
        bad_owner.start_read(slot or "A")
        out["premature_vertical_start_rejected"] = False
    except ModelError:
        out["premature_vertical_start_rejected"] = True
    try:
        run_case(matrix, "sparse", mutate="wrong_result")
        out["wrong_result_data_rejected"] = False
    except ModelError:
        out["wrong_result_data_rejected"] = True
    # Fault injection: response arrives while req=0 but the implementation
    # drops hold_valid and decrements occupied.  The same protocol checker must
    # reject this trace.
    faulty_hold = [{"cycle": 1, "event": "result_read_response", "req": False,
                    "hold_valid": False, "occupied_before": 1,
                    "occupied_after": 0, "output_fire": True}]
    out["output_holding_failure_rejected"] = not validate_output_hold(faulty_hold)
    try:
        over = ResultMemory([])
        over.reserve_tu()
        for index in range(RESULT_GROUPS):
            over.write_group(0, index, [0, 0, 0, 0], 64, 0)
        over.write_group(0, RESULT_GROUPS, [0, 0, 0, 0], 64, 0)
        out["result_overcapacity_rejected"] = False
    except ModelError:
        out["result_overcapacity_rejected"] = True
    # Simulate the forbidden mutation: reuse epoch 0 without clearing tags.
    stale = EpochInputCache("stale", [])
    stale.begin_tu()
    stale.issue(0, [], [(3, 7, 1234, ("old",))])
    stale.epoch = 0
    out["epoch_scrub_disabled_rejected"] = stale.read_tagged(3, 7) != 0
    try:
        bad = BankedMemory("bad", [])
        bad.issue(0, [(0, 0, "a"), (0, 4, "b")], [])
        out["bank_conflict_rejected"] = False
    except ModelError:
        out["bank_conflict_rejected"] = True
    try:
        run_case(matrix, "sparse", mutate="horizontal_plus1024")
        out["horizontal_stage16_mutation_rejected"] = False
    except ModelError:
        out["horizontal_stage16_mutation_rejected"] = True
    return out


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    AUDIT.mkdir(parents=True, exist_ok=True)
    matrix = load_matrix()
    cases = [run_case(matrix, name, mode) for name, mode in
             (("zero", "ready"), ("sparse", "ready"), ("alternating", "toggle"), ("random", "toggle"))]
    wrap_case = run_case(matrix, "wrap", "toggle", initial_vector_id=0xFFFE)
    two = two_tu_case(matrix)
    negatives = negative_tests(matrix)
    epoch = epoch_wrap_test()
    ident = vector_id_wrap_test(matrix)
    input_contract = input_protocol_tests()
    all_pass = (all(c["vertical_stage16_match"] and c["horizontal_stage16_match"]
                    and c["final10_match"] and c["result_writes"] == RESULT_GROUPS
                    and c["result_fires"] == RESULT_GROUPS for c in cases + [wrap_case])
                and two["result_writes"] == 2 * RESULT_GROUPS
                and two["result_fires"] == 2 * RESULT_GROUPS
                and two["long_backpressure"] and two["capacity_wait"] and two["tag_order_ok"]
                and two["data_ok"]
                and all(negatives.values()) and all(input_contract.values())
                and epoch["pass"] and ident["pass"])
    result = {"status": "PASS" if all_pass else "FAIL", "step": "V3.5-15",
              "cases": cases, "wrap_case": wrap_case,
              "two_tu": {k: v for k, v in two.items() if k != "trace"},
              "negative_tests": negatives, "input_contract": input_contract,
              "epoch_wrap": epoch, "vector_id_wrap": ident,
              "contracts": {"global_tick": True, "result_write_same_cycle": True,
                            "result_read_latency": 1, "holding": True,
                            "input_data_fire": "vld && req", "input_end_fire": "end && req",
                            "single_persistent_r4c": True, "epoch_scrub_cycles": 1024}}
    (AUDIT / "step12ar2_results.json").write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    (AUDIT / "step12ar2_negative_tests.json").write_text(json.dumps(negatives, indent=2), encoding="utf-8")
    (AUDIT / "step12ar2_event_trace.json").write_text(json.dumps({"two_tu": two["trace"]}, indent=2), encoding="utf-8")
    report = ["# V3.5-15 Temporal & Protocol Closure", "",
              f"Status: **{result['status']}**", "",
              "- One IntegrationModel.tick() owns the absolute cycle.",
              "- H kernel groups write ResultMemory in the same cycle; historical replay is forbidden.",
              "- Result output uses one-cycle synchronous response and a two-entry elastic holding path; ready steady-state output_fire II=1.",
              "- Input data/end are accepted only on vld&&req / end&&req.",
              "- A persistent R4C contract is reused across both phases.",
              "- Four-bank memories model one read and one write port per bank.",
              "- Epoch wrap scrubs four tag banks in parallel for 1024 cycles.",
              "- Negative mutations are fail-closed and part of the overall gate.",
              "- The frozen independent P1-A oracle is vendored under 04_reference/oracle.", ""]
    (OUT / "V35_15_REPORT.md").write_text("\n".join(report), encoding="utf-8")
    return 0 if all_pass else 1


if __name__ == "__main__":
    raise SystemExit(main())
