"""Executable Step12B 64x64 DCT2xDCT2 wrapper contract model.

This is deliberately a new model; the frozen V3.5-16 Step12A model is not
modified or imported.  A single IntegrationModel.tick() owns time.  The
numeric kernel is a stateful black-box contract for the frozen R4C: vectors
are accepted every 16 cycles and four complete stage16 values are emitted for
each group.  The surrounding model contains real one-cycle synchronous
memory requests/responses, a single intermediate-memory owner, live H-group
writes, and an output hold/skid path.
"""
from __future__ import annotations

import json
import random
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[2]
CANONICAL = ROOT / "03_verification" / "output" / "canonical_matrices.json"
ORACLE_ROOT = ROOT / "04_reference" / "oracle"
if str(ORACLE_ROOT) not in sys.path:
    sys.path.insert(0, str(ORACLE_ROOT))
from v34_rtl_bitexact import main_2d_details  # type: ignore

N = 64
GROUPS = 16
RESULT_GROUPS = 1024
READ_LATENCY = 1
KERNEL_LATENCY = 24
EPOCH_BITS = 2
EPOCH_MOD = 1 << EPOCH_BITS


class ContractError(RuntimeError):
    pass


def wrap16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def low10(v: int) -> int:
    return v & 0x3FF


def bank_addr(row: int, col: int) -> tuple[int, int]:
    if not (0 <= row < N and 0 <= col < N):
        raise ContractError(f"coordinate out of range: {(row, col)}")
    return ((row & 3) ^ (col & 3), row * 16 + (col >> 2))


def load_matrix() -> list[list[int]]:
    data = json.loads(CANONICAL.read_text(encoding="utf-8"))
    return [[int(v) for v in row]
            for row in data["transforms"]["0"]["inverse_operator"]["64"]]


class SyncBankedMemory:
    """4-bank, 1R/1W-per-bank memory with explicit +1 read response."""

    def __init__(self, name: str, trace: list[dict[str, Any]], words: int = 1024):
        self.name = name
        self.trace = trace
        self.data = [[0] * words for _ in range(4)]
        self.pending: dict[int, list[tuple[Any, int, int]]] = {}
        self.words = words
        self.reads = 0
        self.writes = 0

    def issue(self, cycle: int, reads: list[tuple[int, int, Any]],
              writes: list[tuple[int, int, int, Any]]) -> None:
        read_banks: set[int] = set()
        write_banks: set[int] = set()
        for row, col, token in reads:
            bank, addr = bank_addr(row, col)
            if bank in read_banks:
                raise ContractError(f"{self.name}: read bank conflict at {cycle}")
            read_banks.add(bank)
            self.pending.setdefault(cycle + READ_LATENCY, []).append((token, bank, addr))
            self.reads += 1
            self.trace.append({"cycle": cycle, "event": "memory_read_request",
                               "memory": self.name, "token": repr(token),
                               "row": row, "col": col, "bank": bank, "addr": addr})
        for row, col, value, token in writes:
            bank, addr = bank_addr(row, col)
            if bank in write_banks:
                raise ContractError(f"{self.name}: write bank conflict at {cycle}")
            write_banks.add(bank)
            if not (0 <= addr < self.words):
                raise ContractError(f"{self.name}: address out of range {addr}")
            self.data[bank][addr] = int(value)
            self.writes += 1
            self.trace.append({"cycle": cycle, "event": "memory_write",
                               "memory": self.name, "token": repr(token),
                               "row": row, "col": col, "bank": bank, "addr": addr,
                               "value": int(value)})

    def consume(self, cycle: int) -> list[tuple[Any, int]]:
        out: list[tuple[Any, int]] = []
        for token, bank, addr in self.pending.pop(cycle, []):
            value = self.data[bank][addr]
            out.append((token, value))
            self.trace.append({"cycle": cycle, "event": "memory_read_response",
                               "memory": self.name, "token": repr(token),
                               "bank": bank, "addr": addr, "value": value})
        return out


class EpochInputCache(SyncBankedMemory):
    def __init__(self, name: str, trace: list[dict[str, Any]]):
        super().__init__(name, trace)
        self.tags = [[-1] * 1024 for _ in range(4)]
        self.epoch = -1
        self.scrubbing = False
        self.scrub_index = 0

    def begin_tu(self) -> bool:
        if self.scrubbing:
            return False
        nxt = (self.epoch + 1) % EPOCH_MOD
        if self.epoch >= 0 and nxt == 0:
            self.scrubbing = True
            self.scrub_index = 0
            self.epoch = -1
            return False
        self.epoch = nxt
        return True

    def scrub_tick(self, cycle: int) -> None:
        if not self.scrubbing:
            return
        # Four banks are cleared in parallel: one physical address per bank
        # per cycle, so a wrap scrub is exactly 1024 cycles.
        for bank in range(4):
            self.tags[bank][self.scrub_index] = -1
        self.trace.append({"cycle": cycle, "event": "epoch_scrub",
                           "memory": self.name, "index": self.scrub_index})
        self.scrub_index += 1
        if self.scrub_index == 1024:
            self.scrubbing = False
            self.epoch = 0

    def issue(self, cycle: int, reads, writes) -> None:
        if self.scrubbing and (reads or writes):
            raise ContractError(f"{self.name}: access during scrub")
        super().issue(cycle, reads, writes)
        for row, col, _value, _token in writes:
            bank, addr = bank_addr(row, col)
            self.tags[bank][addr] = self.epoch

    def consume(self, cycle: int) -> list[tuple[Any, int]]:
        if self.scrubbing and self.pending.get(cycle):
            raise ContractError(f"{self.name}: response during scrub")
        if self.scrubbing:
            return []
        out: list[tuple[Any, int]] = []
        for token, bank, addr in self.pending.pop(cycle, []):
            live = self.epoch >= 0 and self.tags[bank][addr] == self.epoch
            value = self.data[bank][addr] if live else 0
            out.append((token, value))
            self.trace.append({"cycle": cycle, "event": "memory_read_response",
                               "memory": self.name, "token": repr(token),
                               "bank": bank, "addr": addr, "value": value,
                               "tag_valid": live})
        return out


class ResultMemory:
    """1024 40-bit beats, 1-cycle RAM response, hold + one skid entry."""

    def __init__(self, trace: list[dict[str, Any]]):
        self.trace = trace
        self.beats: dict[int, tuple[int, int, int, int]] = {}
        self.write_cycle: dict[int, int] = {}
        self.reserved = 0
        self.occupied = 0
        self.read_index = 0
        self.issue_index = 0
        self.pending: tuple[int, int] | None = None
        self.hold: tuple[int, tuple[int, int, int, int]] | None = None
        self.skid: tuple[int, tuple[int, int, int, int]] | None = None
        self.writes = 0
        self.fires = 0

    def reserve(self, cycle: int) -> bool:
        if self.reserved or self.occupied:
            return False
        # A completed TU has fully retired its 1024-beat address space.  A
        # subsequent TU reuses the same result memory from raster index zero.
        self.read_index = 0
        self.issue_index = 0
        self.pending = None
        self.hold = None
        self.skid = None
        self.reserved = RESULT_GROUPS
        self.trace.append({"cycle": cycle, "event": "result_reserve",
                           "groups": RESULT_GROUPS})
        return True

    def write_group(self, cycle: int, index: int, values: list[int], tu: int,
                    vector: int, group: int) -> None:
        if not (0 <= index < RESULT_GROUPS) or len(values) != 4:
            raise ContractError("result write shape/range error")
        if self.reserved <= 0 or index in self.beats:
            raise ContractError("result write without reservation or duplicate")
        beat = tuple(low10(v) for v in values)
        self.beats[index] = beat
        self.write_cycle[index] = cycle
        self.reserved -= 1
        self.occupied += 1
        self.writes += 1
        self.trace.append({"cycle": cycle, "event": "result_write", "tu": tu,
                           "vector": vector, "group": group, "index": index,
                           "values": list(beat)})

    def tick(self, cycle: int, req: bool) -> list[tuple[int, tuple[int, int, int, int]]]:
        fired: list[tuple[int, tuple[int, int, int, int]]] = []
        # A previously held beat fires only on an actual ready/request.
        if self.hold is not None and req:
            index, beat = self.hold
            if index != self.read_index:
                raise ContractError("result read order error")
            fired.append((index, beat))
            del self.beats[index]
            self.write_cycle.pop(index, None)
            self.read_index += 1
            self.occupied -= 1
            self.fires += 1
            self.trace.append({"cycle": cycle, "event": "output_fire",
                               "index": index, "values": list(beat), "req": True})
            self.hold = self.skid
            self.skid = None

        # A RAM response is never discarded.  If req is high and the head is
        # free after the fire above, it may retire in this same abstract edge;
        # otherwise it enters hold/skid and remains stable during backpressure.
        if self.pending is not None and self.pending[0] == cycle:
            index = self.pending[1]
            if index not in self.beats:
                raise ContractError("result response for missing beat")
            entry = (index, self.beats[index])
            self.pending = None
            self.trace.append({"cycle": cycle, "event": "result_read_response",
                               "index": index, "req": bool(req)})
            if self.hold is None:
                self.hold = entry
            elif self.skid is None:
                self.skid = entry
            else:
                raise ContractError("result hold/skid overflow")

        # In ready steady state a new request is issued every cycle.  Requests
        # never target a beat written on this same edge, avoiding RDW reliance.
        elastic = int(self.hold is not None) + int(self.skid is not None)
        if req and self.pending is None and elastic < 2:
            if (self.issue_index in self.beats and
                    self.write_cycle[self.issue_index] < cycle):
                self.pending = (cycle + READ_LATENCY, self.issue_index)
                self.trace.append({"cycle": cycle, "event": "result_read_request",
                                   "index": self.issue_index})
                self.issue_index += 1
        return fired


@dataclass
class KernelEvent:
    cycle: int
    serial: int
    vector_id: int
    group: int
    values: list[int]
    first: bool
    last: bool


class R4CContract:
    """Frozen R4C timing contract; no surrounding phase may stall it."""

    def __init__(self, matrix: list[list[int]], trace: list[dict[str, Any]],
                 initial_vector_id: int = 0):
        self.matrix = matrix
        self.trace = trace
        self.next_id = initial_vector_id & 0xFFFF
        self.last_start: int | None = None
        self.serial = 0
        self.active: list[dict[str, Any]] = []

    def accept(self, cycle: int, vector: list[int]) -> int:
        if self.last_start is not None and cycle - self.last_start < 16:
            raise ContractError("R4C vector interval below 16")
        serial = self.serial
        vector_id = self.next_id
        self.active.append({"serial": serial, "vector_id": vector_id,
                            "start": cycle, "vector": list(vector), "groups": set()})
        self.serial += 1
        self.next_id = (self.next_id + 1) & 0xFFFF
        self.last_start = cycle
        self.trace.append({"cycle": cycle, "event": "vector_start", "serial": serial,
                           "vector_id": vector_id})
        return serial

    def tick(self, cycle: int) -> list[KernelEvent]:
        out: list[KernelEvent] = []
        for item in self.active:
            group = cycle - item["start"] - KERNEL_LATENCY
            if not (0 <= group < GROUPS) or group in item["groups"]:
                continue
            vals: list[int] = []
            for output in range(group * 4, group * 4 + 4):
                raw = sum(int(self.matrix[output][j]) * int(item["vector"][j])
                          for j in range(N))
                vals.append(wrap16((raw + 32) >> 6))
            item["groups"].add(group)
            ev = KernelEvent(cycle, item["serial"], item["vector_id"], group, vals,
                             group == 0, group == GROUPS - 1)
            self.trace.append({"cycle": cycle, "event": "kernel_group",
                               "serial": ev.serial, "vector_id": ev.vector_id,
                               "group": group, "first": ev.first, "last": ev.last})
            out.append(ev)
        self.active = [item for item in self.active if len(item["groups"]) != GROUPS]
        return out


@dataclass
class PhaseTask:
    model: "IntegrationModel"
    tu: int
    phase: str
    source: SyncBankedMemory
    dest: SyncBankedMemory | None
    cache_slot: str | None
    vector_base: int
    start_cycle: int = 0
    next_vector: int = 0
    next_group: int = 0
    values: dict[int, list[int | None]] = field(default_factory=dict)
    accepted: dict[int, int] = field(default_factory=dict)
    emitted: int = 0
    done: bool = False

    def begin(self, cycle: int) -> None:
        self.start_cycle = cycle
        self.values[0] = [None] * N
        self.model.trace.append({"cycle": cycle, "event": "phase_start", "tu": self.tu,
                                 "phase": self.phase})

    def coords(self, vector: int, group: int) -> list[tuple[int, int]]:
        if self.phase == "vertical":
            return [(group * 4 + k, vector) for k in range(4)]
        return [(vector, group * 4 + k) for k in range(4)]

    def consume(self, responses: Iterable[tuple[Any, int]]) -> None:
        for token, value in responses:
            if not (isinstance(token, tuple) and token[0] == self.phase):
                continue
            _, vector, first = token
            if vector not in self.values:
                self.values[vector] = [None] * N
            self.values[vector][first] = int(value)

    def tick(self, cycle: int) -> list[tuple[int, int, Any]]:
        if self.done:
            return []
        reads: list[tuple[int, int, Any]] = []
        if self.next_vector < N:
            self.values.setdefault(self.next_vector, [None] * N)
            coords = self.coords(self.next_vector, self.next_group)
            reads = [(r, c, (self.phase, self.next_vector, self.next_group * 4 + k))
                     for k, (r, c) in enumerate(coords)]
            self.next_group += 1
            if self.next_group == GROUPS:
                self.next_group = 0
                self.next_vector += 1
                if self.next_vector < N:
                    self.values.setdefault(self.next_vector, [None] * N)

        # A vector is launched as soon as its final synchronous response is
        # present.  This naturally yields 16-cycle starts: 16 reads/group.
        for vector in sorted(self.values):
            if vector in self.accepted or vector >= N:
                continue
            vals = self.values[vector]
            if all(v is not None for v in vals):
                serial = self.model.kernel.accept(
                    cycle, [int(v) for v in vals])
                self.accepted[vector] = serial
                self.model.trace.append({"cycle": cycle, "event": "phase_vector_start",
                                         "tu": self.tu, "phase": self.phase,
                                         "vector": vector, "serial": serial})
            break
        return reads

    def handle(self, event: KernelEvent) -> None:
        vector = event.serial - self.model.phase_serial_base(self)
        if not (0 <= vector < N):
            raise ContractError("kernel event does not belong to phase")
        for k, value in enumerate(event.values):
            idx = event.group * 4 + k
            if self.phase == "vertical":
                row, col = idx, vector
            else:
                row, col = vector, idx
            if self.dest is not None:
                self.dest.issue(self.model.cycle, [],
                                [(row, col, value, (self.phase, vector, idx))])
        self.emitted += 1
        if self.phase == "horizontal":
            self.model.write_result_from_h(event, self.tu, vector)
        if len(self.accepted) == N and self.emitted == N * GROUPS:
            self.done = True
            self.model.trace.append({"cycle": event.cycle, "event": "phase_done",
                                     "tu": self.tu, "phase": self.phase})


class IntegrationModel:
    """Only this object advances ``cycle``; all children are tick-driven."""

    def __init__(self, sources: list[list[list[int]]], initial_vector_id: int = 0,
                 output_req: callable | None = None):
        if not sources:
            raise ValueError("at least one TU is required")
        self.matrix = load_matrix()
        self.sources = sources
        self.trace: list[dict[str, Any]] = []
        self.cycle = 0
        self.caches = {"A": EpochInputCache("inputA", self.trace),
                       "B": EpochInputCache("inputB", self.trace)}
        self.cache_owner: dict[int, str] = {}
        self.input_queue = list(range(len(sources)))
        self.input_active: tuple[int, str, list[tuple[int, int]]] | None = None
        self.ready_tus: list[int] = []
        self.tu_state = [{"input": "PENDING", "vertical": "PENDING",
                          "horizontal": "PENDING"} for _ in sources]
        self.current: PhaseTask | None = None
        self.intermediate = SyncBankedMemory("intermediate", self.trace)
        self.intermediate_owner: int | None = None
        self.result = ResultMemory(self.trace)
        self.kernel = R4CContract(self.matrix, self.trace, initial_vector_id)
        self.phase_bases: dict[tuple[int, str], int] = {}
        self.output_req = output_req or (lambda _cycle, _model: True)
        self.drained: list[tuple[int, tuple[int, int, int, int]]] = []
        self.stats = {"input_cache_full": 0, "staging_wait": 0,
                      "result_capacity_wait": 0, "output_backpressure": 0,
                      "epoch_scrub": 0}

    def phase_serial_base(self, task: PhaseTask) -> int:
        return self.phase_bases[(task.tu, task.phase)]

    def _events_for(self, tu: int) -> list[tuple[int, int]]:
        src = self.sources[tu]
        return [(r * N + c, int(src[r][c]))
                for r in range(N) for c in range(N) if int(src[r][c]) != 0]

    def _start_input(self) -> None:
        if self.input_active is not None or not self.input_queue:
            return
        for slot in ("A", "B"):
            cache = self.caches[slot]
            if self.cache_owner.get(-1) == slot:
                continue
            if cache.scrubbing:
                continue
            if self.tu_state[self.input_queue[0]]["input"] != "PENDING":
                continue
            if not cache.begin_tu():
                self.stats["epoch_scrub"] += 1
                continue
            tu = self.input_queue.pop(0)
            self.cache_owner[tu] = slot
            self.input_active = (tu, slot, self._events_for(tu))
            self.tu_state[tu]["input"] = "FILLING"
            self.trace.append({"cycle": self.cycle, "event": "descriptor_bind",
                               "tu": tu, "slot": slot})
            return
        self.stats["input_cache_full"] += 1

    def _tick_input(self) -> None:
        self._start_input()
        if self.input_active is None:
            return
        tu, slot, events = self.input_active
        cache = self.caches[slot]
        req = not cache.scrubbing
        if not events:
            if req:
                self.tu_state[tu]["input"] = "READY"
                self.ready_tus.append(tu)
                self.input_active = None
                self.trace.append({"cycle": self.cycle, "event": "input_end_fire",
                                   "tu": tu, "same_cycle_data": False})
            return
        addr, value = events.pop(0)
        if not req:
            self.stats["input_cache_full"] += 1
            return
        row, col = divmod(addr, N)
        cache.issue(self.cycle, [], [(row, col, value, ("input", tu, addr))])
        self.trace.append({"cycle": self.cycle, "event": "input_data_fire", "tu": tu,
                           "slot": slot, "addr": addr, "value": value,
                           "req": True})

    def _choose_phase(self) -> None:
        if self.current is not None:
            return
        # Single intermediate owner and one R4C.  H has priority once V is done.
        for tu, st in enumerate(self.tu_state):
            if st["vertical"] == "DONE" and st["horizontal"] == "PENDING":
                if self.intermediate_owner != tu or not self.result.reserve(self.cycle):
                    self.stats["result_capacity_wait"] += 1
                    continue
                st["horizontal"] = "RUNNING"
                base = self.kernel.serial
                self.phase_bases[(tu, "horizontal")] = base
                self.current = PhaseTask(self, tu, "horizontal", self.intermediate,
                                         None, None, (tu * 128 + 64) & 0xFFFF)
                self.current.begin(self.cycle)
                return
        for tu in list(self.ready_tus):
            if self.intermediate_owner is not None:
                break
            slot = self.cache_owner[tu]
            if self.tu_state[tu]["vertical"] != "PENDING":
                self.ready_tus.remove(tu)
                continue
            self.ready_tus.remove(tu)
            self.intermediate_owner = tu
            self.tu_state[tu]["vertical"] = "RUNNING"
            base = self.kernel.serial
            self.phase_bases[(tu, "vertical")] = base
            self.current = PhaseTask(self, tu, "vertical", self.caches[slot],
                                     self.intermediate, slot, (tu * 128) & 0xFFFF)
            self.current.begin(self.cycle)
            return

    def write_result_from_h(self, event: KernelEvent, tu: int, vector: int) -> None:
        self.trace.append({"cycle": event.cycle, "event": "final_stage16_write",
                           "tu": tu, "vector": vector, "group": event.group,
                           "values": list(event.values)})
        self.result.write_group(event.cycle, vector * GROUPS + event.group,
                                event.values, tu, vector, event.group)

    def _finish_phase(self) -> None:
        if self.current is None or not self.current.done:
            return
        task = self.current
        if task.phase == "vertical":
            slot = task.cache_slot
            self.tu_state[task.tu]["vertical"] = "DONE"
            if slot is not None:
                self.caches[slot].epoch = self.caches[slot].epoch
            self.trace.append({"cycle": self.cycle, "event": "vertical_owner_hold",
                               "tu": task.tu})
        else:
            self.tu_state[task.tu]["horizontal"] = "DONE"
            self.intermediate_owner = None
            self.trace.append({"cycle": self.cycle, "event": "tu_compute_done",
                               "tu": task.tu})
        self.current = None

    def tick(self) -> None:
        # Response phase of synchronous memories.
        if self.current is not None:
            for cache in self.caches.values():
                if self.current.source is cache:
                    self.current.consume(cache.consume(self.cycle))
            if self.current.source is self.intermediate:
                self.current.consume(self.intermediate.consume(self.cycle))
        else:
            for cache in self.caches.values():
                cache.consume(self.cycle)
            self.intermediate.consume(self.cycle)
        for cache in self.caches.values():
            if cache.scrubbing:
                cache.scrub_tick(self.cycle)

        self._tick_input()
        for event in self.kernel.tick(self.cycle):
            if self.current is None:
                raise ContractError("R4C event without phase owner")
            self.current.handle(event)

        self._finish_phase()
        self._choose_phase()
        if self.current is not None:
            reads = self.current.tick(self.cycle)
            if reads:
                self.current.source.issue(self.cycle, reads, [])

        req = bool(self.output_req(self.cycle, self))
        if not req:
            self.stats["output_backpressure"] += 1
        self.drained.extend(self.result.tick(self.cycle, req))
        self.trace.append({"cycle": self.cycle, "event": "output_req", "req": req,
                           "hold": self.result.hold is not None,
                           "occupied": self.result.occupied})
        if self.result.reserved < 0 or self.result.occupied < 0:
            raise ContractError("negative result credit")
        if self.result.reserved + self.result.occupied > RESULT_GROUPS:
            raise ContractError("result capacity overcommit")
        self.cycle += 1

    def run(self, max_cycles: int = 20000) -> dict[str, Any]:
        while self.cycle < max_cycles:
            self.tick()
            done = all(st["horizontal"] == "DONE" for st in self.tu_state)
            if done and self.result.occupied == 0 and self.result.reserved == 0:
                break
        else:
            raise ContractError("integration did not finish before timeout")
        return {"cycles": self.cycle, "trace": self.trace,
                "drained": self.drained, "stats": self.stats,
                "result_writes": self.result.writes, "result_fires": self.result.fires,
                "vector_starts": [e for e in self.trace if e.get("event") == "vector_start"]}


def make_case(kind: str, seed: int = 20260904) -> list[list[int]]:
    rng = random.Random(seed)
    if kind == "zero":
        return [[0] * N for _ in range(N)]
    if kind == "sparse":
        a = [[0] * N for _ in range(N)]
        for r, c, v in ((0, 0, 32767), (1, 7, -32768), (17, 33, 1234),
                        (63, 63, -4321), (42, 11, 77)):
            a[r][c] = v
        return a
    if kind == "alternating":
        return [[32767 if ((r + c) & 1) == 0 else -32768 for c in range(N)]
                for r in range(N)]
    if kind == "random":
        return [[rng.randint(-32768, 32767) for _ in range(N)] for _ in range(N)]
    raise ValueError(kind)


def validate_case(kind: str, source: list[list[int]], req_fn=None) -> dict[str, Any]:
    model = IntegrationModel([source], initial_vector_id=0, output_req=req_fn)
    run = model.run()
    expected = main_2d_details(source, 0, 0, N, N)
    actual = [[0] * N for _ in range(N)]
    for index, beat in run["drained"]:
        row = index // GROUPS
        group = index % GROUPS
        for k, value in enumerate(beat):
            actual[row][group * 4 + k] = value
    if actual != expected["final10"]:
        raise ContractError(f"{kind}: final10 mismatch")
    events = [e for e in run["trace"] if e.get("event") == "phase_vector_start"]
    if len(events) != 128:
        raise ContractError(f"{kind}: expected 128 V/H vector starts, got {len(events)}")
    phase_iis: dict[str, list[int]] = {}
    for phase in ("vertical", "horizontal"):
        phase_events = [e for e in events if e.get("phase") == phase]
        starts = [int(e["cycle"]) for e in phase_events]
        if len(starts) != 64 or any(b - a != 16 for a, b in zip(starts, starts[1:])):
            raise ContractError(f"{kind}: {phase} vector interval is not 16")
        phase_iis[phase] = sorted(set(b - a for a, b in zip(starts, starts[1:])))
    writes = [e for e in run["trace"] if e.get("event") == "result_write"]
    if len(writes) != RESULT_GROUPS:
        raise ContractError(f"{kind}: result write count {len(writes)}")
    if any(int(e["cycle"]) < 0 for e in writes):
        raise ContractError(f"{kind}: retroactive result event")
    return {"kind": kind, "cycles": run["cycles"], "vectors": len(events),
            "vector_ii": phase_iis,
            "result_writes": len(writes), "result_fires": len(run["drained"]),
            "stats": run["stats"]}


def main() -> int:
    results: dict[str, Any] = {"version": "V3.5-17-Step12B-cycle-model",
                               "status": "PASS", "cases": []}
    for kind in ("zero", "sparse", "alternating", "random"):
        results["cases"].append(validate_case(kind, make_case(kind)))

    # 1->0 output transition: the beat must stay held and all data must drain
    # in-order after recovery.  The model's output path itself is the object
    # under test; the final10 compare above remains independent.
    def bursty(cycle: int, _model: IntegrationModel) -> bool:
        return not (cycle % 17 in (4, 5, 6, 7, 8))

    results["backpressure"] = validate_case("backpressure", make_case("sparse"), bursty)
    out = ROOT / "05_audit" / "current" / "17"
    out.mkdir(parents=True, exist_ok=True)
    (out / "step12b_cycle_results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    # Keep a compact event trace for the deterministic sparse case.
    trace_model = IntegrationModel([make_case("sparse")], output_req=bursty)
    trace_model.run()
    (out / "step12b_cycle_trace.json").write_text(json.dumps(trace_model.trace, indent=2), encoding="utf-8")
    report = ["# V3.5-17 Step12B cycle model", "", "Status: PASS", "",
              "A single IntegrationModel.tick() advances input, synchronous memories,",
              "the persistent R4C contract, V/H scheduling, live result writes and output hold/skid.", "",
              "| case | cycles | vectors | vector II | result writes | result fires |",
              "|---|---:|---:|---|---:|---:|"]
    for item in results["cases"]:
        report.append(f"| {item['kind']} | {item['cycles']} | {item['vectors']} | {item['vector_ii']} | {item['result_writes']} | {item['result_fires']} |")
    report += ["", "The model is a Step12B functional/protocol pre-gate; no Vivado or full-core timing claim is made."]
    (out / "V35_STEP12B_CYCLE_MODEL_REPORT.md").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(json.dumps(results, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
