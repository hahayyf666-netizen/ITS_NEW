# V35 P2F-A1 Executable Cycle/Dataflow Proof

Status: **FAIL (software cycle/dataflow proof; no RTL/Vivado)**

## Scope and expected-value independence

This model expands every operation in one DCT2-64 invocation and evaluates the
actual signed products, full-precision reduction trees, E/O butterflies,
reorder buffer and result FIFO. Expected raw values are independently computed
as `A*x` from the frozen canonical `inverse_operator`; no RTL output or golden
file is used as an expected value.

The four full cycle-level vectors are launched at cycles `0, 16, 32, 48`:
`one_hot_0`, `all_positive_max`, `all_negative_min`, and
`alternating_positive_negative`. The same executable graph is also run against
all 1226 vectors from the existing P2F deterministic suite.

## Operation expansion

Each operation record contains `op_id`, `vector_id`, `level`, `output_p`,
`input_m`, source `x` index, coefficient, absolute issue cycle, physical lane,
and the computed product. One vector has exactly:

| level | multiplication instances |
|---|---:|
| N4 terminal | 8 |
| N8 odd | 16 |
| N16 odd | 64 |
| N32 odd | 256 |
| N64 odd | 1024 |
| **total** | **1368** |

## 16-cycle issue schedule

| cycle | multiplication instances | levels | lane range |
|---:|---:|---|---|
| 0 | 88 | N4=8, N8=16, N16=64 | 0..87 |
| 1 | 128 | N32=128 | 0..127 |
| 2 | 128 | N32=128 | 0..127 |
| 3 | 128 | N64=128 | 0..127 |
| 4 | 128 | N64=128 | 0..127 |
| 5 | 128 | N64=128 | 0..127 |
| 6 | 128 | N64=128 | 0..127 |
| 7 | 128 | N64=128 | 0..127 |
| 8 | 128 | N64=128 | 0..127 |
| 9 | 128 | N64=128 | 0..127 |
| 10 | 128 | N64=128 | 0..127 |
| 11 | 0 | idle | —..— |
| 12 | 0 | idle | —..— |
| 13 | 0 | idle | —..— |
| 14 | 0 | idle | —..— |
| 15 | 0 | idle | —..— |

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
reduction peak = {0: 64, 1: 32, 2: 16, 3: 8, 4: 4}
butterfly peak = {64: 8, 32: 16, 16: 16, 8: 8, 4: 4}
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

The first contiguous output beat starts at cycle offset 18; groups
0..15 occupy offsets 18..33. Every beat contains
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
| ready every cycle | [(0, 0, True), (1, 16, True), (2, 32, False), (3, 48, True)] | [(0, 0), (1, 16), (3, 48)] | 48 | 32 | FAIL |
| ready=0 until cycle 80, then recovery | [(0, 0, True), (1, 16, True), (2, 32, False), (3, 48, False)] | [(0, 0), (1, 16)] | 32 | 32 | PASS |

The long-stall run stops launching when the 32-group capacity is reserved and
then drains after recovery without loss, duplication or reorder. The steady
run is a hard gate: with the existing output start at cycle 18, cycle 32 has
only 15 free slots, so vector2 is rejected instead of being silently delayed.

## STOP issues

- Strategy-B rejected a required vector start: expected [0, 1, 2, 3] at cycles [0,16,32,48], accepted [0, 1, 3]; cycle-32 free_slots=15
- steady no-backpressure consumed 48 groups, expected 64

## Existing P2F vector sweep

```text
vectors checked = 1226
raw/fixed dataflow matches = 1226/1226
positive wrap outputs observed = 29455
negative wrap outputs observed = 29152
```

## Final gate

```text
128 multiplier lanes <= capacity              PASS
vector starts 0/16/32/48                     FAIL
all 1368 operations expanded and evaluated   PASS
reduction/butterfly/storage conflicts        PASS (0)
raw == factorized graph == A*x               PASS
raw+32 >>>6 wrap16                           PASS
4 complete outputs/cycle                     PASS
group interval = 1                            PASS
FIFO depth = 32                               PASS
reserved + occupied <= 32                    PASS
backpressure stop/recovery                   PASS
```

This is an executable software architecture proof. It is not a timing claim;
the next RTL implementation must still prove the same contracts and 2.000 ns
post-route timing. Because Strategy-B cannot admit all four required starts
under the current schedule, the overall A1.1 gate is **FAIL**.
