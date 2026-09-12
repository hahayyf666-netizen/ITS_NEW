# V3.5-17.2 STOP — Same-Edge Model Reconciliation

## What passed

The verification-only Python model now separates the two memory contracts:

```text
input-cache/intermediate: request == lane capture, delta=0
ResultMemory: request C → response C+1
```

The model-side gate passes zero/sparse/alternating/random, backpressure, two-TU,
vector-ID wrap, per-episode epoch scrub, lane-level capture, owner/bank/address
checks, request IDs, and 26 fail-closed model mutations. The frozen RTL and R4C
were not modified.

The retained normal timing probe also agrees for the vertical staging path under
one global anchor: request-to-capture is 0 and first request-to-stage-full is 15.

## Why this round stops

The same single-anchor comparison does not close the horizontal path. The first
horizontal/intermediate read request in the frozen RTL probe is one edge later
than the Python model after the vertical stream has already aligned. The public
wrapper trace also fails at `vector_start` under the same no-offset rule. These
are real phase-boundary/monitor evidence differences, not a reason to add a
per-event offset.

```text
validate_step12b_memory_timing.py:
  model/RTL staging read-request lane trace mismatch

validate_step12b_rtl_trace.py:
  vector_start cycle mismatch
```

## Gate decision

```text
v3.5-17.2 = STOP / NOT PASS
```

No `v3.5-17.2` tag is created and Step12C/Vivado is not started. The next
decision must explain the V/H phase-boundary transaction semantics and repair
the verification monitor or contract with evidence; the model must not be
silently shifted to make the comparison green.
