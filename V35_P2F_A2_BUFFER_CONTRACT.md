# V35 P2F-A2 Buffer Contract — 1D Kernel / Full-Core Split

**Status: CONTRACT FREEZE (software/architecture only)**  
**Scope: Step 9.2 only; no RTL, Vivado, P2B, or full-core implementation was performed.**

## 1. Purpose and decision

The P2F 1D kernel is no longer specified as a producer of a fixed 32-group
external-style FIFO.  Its result destination is instead a **guaranteed-accept,
four-wide result/intermediate memory port** owned by the integrating Core.

The old 32-group Strategy-B FIFO remains documented as the historical A1
experiment.  Its failure is retained as evidence, not hidden or repaired by
silently changing the FIFO depth:

- first output beat in the executable A1 model: cycle 18;
- vector starts requested at cycles 0, 16, 32, 48;
- at cycle 32 only 15 slots were free while a new 16-group reservation was
  required;
- vector 2 was therefore rejected and the no-backpressure four-vector gate
  failed.

This is a buffering/admission mismatch.  It does not invalidate the exact
factorization, the 128-lane schedule, or the 4-complete-results/cycle kernel
contract.

## 2. Frozen mathematical and fixed-point contracts

These contracts are inherited unchanged from P0-B/P1-A/P2F-Pre:

```text
main source kernel       C
main inverse operator    A = C^T
main raw operation       y_raw = A*x
main postprocess         raw + 32 -> arithmetic >>> 6 -> signed16 wrap
LFNST operation          M*x
LFNST postprocess        raw + 64 -> arithmetic >>> 7 -> Clip3 signed16
```

The kernel and Core must not transpose `inverse_operator` a second time.
LFNST is not part of this DCT2-64 kernel contract and remains `M*x` when it is
later integrated.

No intermediate rounding, shift, clipping, or wrap is permitted in the
factorized raw path.  The fixed-point conversion is applied only at the
specified postprocess stage.

## 3. P2F 1D kernel contract

The first P2F prototype is the exact DCT2-64 1D kernel.  Its externally visible
calculation contract is:

| Item | Frozen requirement |
|---|---|
| Input | one complete signed16 vector of 64 samples, supplied through the A/B vector buffers |
| Compute | exact canonical factorization of `A*x` |
| Parallel result | four complete post-reduction 1D results per valid beat |
| Group order | `group = 0,1,...,15` |
| Group contents | `y[4g+0] ... y[4g+3]` after the kernel's specified fixed-point postprocess |
| Group issue interval | 1 cycle in steady state |
| Vector invocation interval | 16 cycles in the no-backpressure schedule |
| Internal pipeline | non-stalling during an admitted invocation |
| Result destination | guaranteed-accept 4-wide memory port |
| Backpressure input | not allowed to stall an admitted invocation |
| Tags | `valid`, `vector_id`, `group`, `first`, `last` travel with data |

“Guaranteed accept” means that once an invocation is admitted, the destination
memory port accepts one four-result beat on every kernel `result_valid` cycle.
There is no kernel-side `ready` bubble or mid-burst drop path.  If the Core
cannot make that guarantee, it must not admit the invocation.

The four values are complete results: all constant products, reductions,
butterfly operations, `+32`, arithmetic `>>>6`, and signed16 wrap have already
been applied.  A partial product, partial sum, or unfinished reduction is not a
valid P2F result beat.

## 4. Kernel-to-memory interface

The implementation-facing logical interface is:

```text
kernel_result_valid
kernel_result_data[3:0]       // four signed16 stage results
kernel_result_group           // 0..15
kernel_result_vector_id
kernel_result_first
kernel_result_last
kernel_result_accept          // required to be 1 for every admitted beat
```

`kernel_result_accept` is a contract assertion, not a mechanism for stopping
the non-stalling P2F pipeline.  During an admitted burst:

```text
kernel_result_valid == 1  =>  kernel_result_accept == 1
```

The memory writer records the beat at the address derived from the vector/TU
tag and group.  The writer must verify that group order is contiguous and that
the destination bank/port mapping has no conflict.

The kernel must not expose the old Strategy-B `reserved/occupied` FIFO state
as its correctness criterion.  Those counters belong to a Core-level result
memory implementation.

## 5. Full-Core buffer contract

External output request/ready and TU-level backpressure are handled only after
the 1D result/intermediate memory layer:

```text
1D P2F kernel
    -> guaranteed-accept 4-wide result/intermediate memory
    -> transpose / second 1D phase
    -> full-TU result memory
    -> it_data_out / it_data_out_vld
```

For a main-transform phase, the Core must provide enough independently writable
memory space for every beat that the admitted phase can produce.  This space
includes:

```text
occupied entries already in result/intermediate memory
+ entries reserved for the whole admitted TU/phase
+ all in-flight beats inside the non-stalling kernel and memory-write pipeline
```

Admission is made **before** the first vector/group of the TU or phase starts.
If the capacity proof fails, the Core holds the upstream start request; it must
not start group 0 and later hope that external `req` recovers.

Once admitted, the memory writer must accept every beat of that invocation or
phase.  External `it_data_out_req=0` may stop reads from full-TU result memory,
but it must not cause an already-started P2F burst to overwrite, drop, duplicate,
or reorder entries.

The exact numeric capacity is a Core integration parameter, not a 32-group
kernel constant.  Before RTL integration, the Core design must derive it from
the largest simultaneously live TU/phase, bank count, write latency, and all
in-flight pipeline entries, then prove the admission inequality by exhaustive
cycle simulation.

## 6. Memory ownership and phase separation

The following ownership is frozen for the next integration step:

1. **Vector A/B buffers** belong to the 1D kernel.  One buffer is computed while
   the other may be loaded for the next admitted vector.
2. **Intermediate/transpose memory** belongs to the Core.  It accepts the
   kernel's four-wide writes and supplies the access pattern for the next 1D
   phase.
3. **Full-TU result memory** belongs to the Core.  It absorbs output read
   backpressure and feeds `it_data_out` in the required raster order.
4. A buffer is not released until all writes, reads, and in-flight entries
   associated with its owner have retired.

The kernel may expose a `phase_done`/`vector_done` tag, but it must not infer
that the external interface has consumed the TU.  Memory ownership and release
are Core responsibilities.

## 7. Backpressure and safety invariants

The integrated Core must assert the following properties:

```text
No-admit:
  insufficient free memory => no TU/vector start

Guaranteed accept:
  admitted burst => every valid beat is accepted by its memory port

No overcommit:
  occupied + reserved + in_flight <= physical capacity

No corruption:
  no overwrite of an unread entry

Ordering:
  vector_id/TU_id/group and first/last remain aligned with data

Recovery:
  prolonged external output backpressure stops future admissions;
  after recovery all stored beats drain exactly once in order
```

The old A1 check `reserved + occupied <= 32` is retained only as a historical
FIFO experiment.  It is not the P2F A2 kernel gate.  The corresponding A2 Core
check uses the actual full-TU memory capacity and explicitly includes
in-flight entries.

## 8. P2F kernel gate after the split

The 1D kernel is considered architecturally valid only if it independently
passes:

```text
128 multiplier lanes within capacity
vector interval = 16 cycles
4 complete results per cycle
group interval = 1
group sequence 0..15
no internal multiplier/reduction/storage conflict
raw/fixed-point bit-exact against the independent Oracle
tag/data alignment
```

It is **not** required in this gate to prove external `it_data_out_req`
behavior.  That behavior is deferred to the Core-level memory contract.

## 9. Core integration gate (future, not executed in Step 9.2)

Before integrating the kernel into the full ITS Core, the next design phase must
provide and verify:

1. a concrete intermediate/transpose memory organization and bank map;
2. a concrete full-TU result-memory depth and ownership protocol;
3. admission equations for every supported rectangular TU and both transform
   phases;
4. exhaustive bank/read/write conflict checks;
5. a cycle-accurate test with `req/ready=0` for a long interval and subsequent
   recovery;
6. exact counts of kernel-generated beats, memory-write accepts, and interface
   read fires;
7. no loss, duplication, overwrite, or reordering across consecutive TUs;
8. only after the above, a new integrated 500 MHz post-route OOC run.

The Core integration must not simply reconnect the old 32-group FIFO and call
the A2 contract satisfied.

## 10. Historical A1 result and unresolved items

The executable A1 dataflow proof remains useful and is not deleted.  It proves
the arithmetic and resource schedule, but its old external FIFO scenario has a
known admission failure:

```text
P2F A1 old FIFO: 32 groups, Strategy B
kernel result start: cycle 18
required starts: 0,16,32,48
cycle-32 free slots: 15 < 16
result: vector 2 rejected
```

That historical failure is intentionally resolved by moving external
backpressure to the Core memory layer; it is not resolved by claiming that a
32-group FIFO can sustain the old schedule.

Still unresolved for later phases:

- the concrete full-TU memory depth and banking;
- the exact admission calculation for all rectangular TU shapes;
- the RTL latency and physical implementation of the factorized kernel;
- 500 MHz post-route timing and PPA for the factorized architecture;
- LFNST 4/8-input masking and its eventual Core integration.

## 11. Evidence and scope boundary

This contract is based on the following read-only artifacts in the P2F working
directory:

- `V35_P2F_PRE_FACTOR_ARCHITECTURE.md`
- `V35_P2F_A1_P4_SCHEDULE.md`
- `V35_P2F_A1_DATAFLOW_PROOF.md`
- `p2f_a1_dataflow_results.json`

No V3.4 file, canonical matrix, ROM, golden, RTL, or Vivado result was modified
in Step 9.2.  No claim of RTL correctness or 500 MHz closure is made here.

## Final status

```text
P2F 1D kernel / Core buffer contract split: DEFINED
Old 32-group external FIFO as kernel gate: RETIRED (historical only)
Full-Core buffer implementation: NOT STARTED
RTL/Vivado: NOT RUN
```
