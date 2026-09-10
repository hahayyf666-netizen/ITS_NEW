# V35 P2F-A2 Kernel Contract Re-Gate

Status: **PASS (software cycle/dataflow proof; no RTL/Vivado)**

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
| v0 `one_hot_0` | 0 | 18 | 16 | 1 |
| v1 `all_positive_max` | 16 | 34 | 16 | 1 |
| v2 `all_negative_min` | 32 | 50 | 16 | 1 |
| v3 `alternating_positive_negative` | 48 | 66 | 16 | 1 |

The requested vector starts are exactly `[0, 16, 32, 48]` and the vector
interval is `16` cycles.  Output beats are globally contiguous
from cycle `18` through `81`; each beat carries
four complete postprocessed results.

## Mathematical and fixed-point checks

- One invocation expands to **1368** exact constant multiplications.
- The shared farm has **128** physical lanes; the maximum scheduled issue is
  `128` operations/cycle.
- Every tested raw vector equals canonical `A*x`; no RTL output or existing
  golden is used as expected data.
- The fixed path is `raw -> +32 -> arithmetic >>>6 -> signed16 wrap -> low10`.
- Full deterministic suite: **1226/1226** raw/factorized/fixed
  checks passed; observed positive/negative wrap outputs are
  `29455`/`29152`.

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
valid beats generated  = 64
beats accepted         = 64
all valid beats accept = True
groups per vector      = 16 for every vector
group sequence         = 0..15 for every vector
first/last tags        = checked
vector/group/data tags = checked
```

No result FIFO capacity, reservation, or external `req/ready` state is part of
this kernel re-gate.  Those checks belong to the full Core result-memory layer.

## Capacity checker hardening

```text
max operation_count > 128              PASS
physical lane assignment               PASS
reduction peak <= capacity             PASS
butterfly peak <= capacity             PASS
storage conflicts == 0                 PASS
negative capacity self-test            PASS (forced failure detected, normal values restored)
```

The negative self-test uses reduction stage
`0`: capacity
`64` is temporarily changed to
`63`, below the observed peak.  The
checker detects the failure and then confirms the normal capacity set passes.

## Gate result

```text
128 multiplier lanes within capacity     PASS
max operation_count <= 128               PASS
reduction peaks within capacity          PASS
butterfly peaks within capacity          PASS
storage conflicts == 0                   PASS
vector interval = 16                     PASS
16 groups per vector                     PASS
4 complete results per valid beat        PASS
group interval = 1                       PASS
raw == A*x                               PASS
fixed-point bit-exact                    PASS
guaranteed-accept sink                   PASS
historical reserved+occupied<=32 gate    NOT CHECKED (retired)
```

## Failures

- None

## Boundary

This is a software cycle/dataflow re-gate only.  It does not prove RTL
implementation, Core-level TU memory admission, or 500 MHz post-route timing.
The next Core phase must provide a concrete full-TU memory capacity/bank proof
and guarantee acceptance before launching any non-stalling kernel burst.
