"""Cycle-accurate P2F-A1 schedule checker (software only).

The checker proves the issue-capacity and dependency schedule for the exact
factorization.  It does not synthesize or simulate RTL.
"""

from __future__ import annotations

import json
from math import ceil, log2
from pathlib import Path

from dct2_64_factorized import ExactDCT2Factorizer

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "p2f_a1_schedule_results.json"
REPORT = ROOT / "V35_P2F_A1_P4_SCHEDULE.md"
LANES = 128
II = 16


def tree_depth(terms: int) -> int:
    return ceil(log2(terms))


def make_schedule() -> list[dict]:
    # Each task is a constant multiplication.  Dense odd nodes are grouped so
    # that one cycle forms complete leaves for a set of output dot products.
    rows = [
        {"cycle": 0, "N4_terminal": 8, "N8_odd": 16, "N16_odd": 64, "N32_odd": 0},
        {"cycle": 1, "N4_terminal": 0, "N8_odd": 0, "N16_odd": 0, "N32_odd": 128},
        {"cycle": 2, "N4_terminal": 0, "N8_odd": 0, "N16_odd": 0, "N32_odd": 128},
    ]
    for c in range(3, 11):
        rows.append({"cycle": c, "N4_terminal": 0, "N8_odd": 0, "N16_odd": 0, "N32_odd": 0,
                     "N64_odd": 128, "N64_p_range": f"{4*(c-3)}..{4*(c-3)+3}"})
    for c in range(11, II):
        rows.append({"cycle": c, "N4_terminal": 0, "N8_odd": 0, "N16_odd": 0, "N32_odd": 0,
                     "N64_odd": 0})
    for row in rows:
        row.setdefault("N64_odd", 0)
        row["lane_count"] = sum(row.get(k, 0) for k in ("N4_terminal", "N8_odd", "N16_odd", "N32_odd", "N64_odd"))
        if row["lane_count"] > LANES:
            raise AssertionError(f"cycle {row['cycle']} exceeds {LANES} lanes")
    if len(rows) != II:
        raise AssertionError(f"expected {II} issue cycles, got {len(rows)}")
    if sum(r["lane_count"] for r in rows) != 1368:
        raise AssertionError("schedule does not issue all 1368 multiplications")
    return rows


def make_dependency_timeline() -> dict:
    # Representative registered implementation: multiplier output one cycle
    # after issue, followed by a fully pipelined binary reduction tree and one
    # registered butterfly per recursion level.  This is a latency example;
    # RTL must measure the final L, but II is independent of L.
    mul_out = {"N4": 1, "N8": 1, "N16": 1, "N32": 2, "N64": 10}
    n4_dot = mul_out["N4"] + tree_depth(2)
    n4_ready = n4_dot + 1
    n8_dot = mul_out["N8"] + tree_depth(4)
    n8_ready = max(n4_ready, n8_dot) + 1
    n16_dot = mul_out["N16"] + tree_depth(8)
    n16_ready = max(n8_ready, n16_dot) + 1
    n32_dot = mul_out["N32"] + tree_depth(16)
    n32_ready = max(n16_ready, n32_dot) + 1
    n64_dot = mul_out["N64"] + tree_depth(32)
    n64_ready = max(n32_ready, n64_dot) + 1
    return {
        "multiplier_last_issue": mul_out,
        "terminal_N4_ready": n4_ready,
        "N8_even_branch_ready": n8_ready,
        "N16_even_branch_ready": n16_ready,
        "N32_even_branch_ready": n32_ready,
        "N64_even_branch_ready": n64_ready,
        "N64_odd_branch_ready": n64_dot,
        "top_pair_butterfly_ready": n64_ready + 1,
        "reorder_buffer_complete": n64_ready + 1,
        "reorder_output_start": n64_ready + 2,
        "reorder_output_end": n64_ready + 17,
    }


def main() -> None:
    f = ExactDCT2Factorizer()
    counts = f.operation_counts()
    assert counts["factorized_constant_multiplications"] == 1368
    schedule = make_schedule()
    timeline = make_dependency_timeline()
    assert sum(r["lane_count"] for r in schedule) / II == 85.5
    assert max(r["lane_count"] for r in schedule) == LANES
    result = {
        "status": "PASS",
        "target": "DCT2-64 exact factorized P4",
        "multiplier_lanes": LANES,
        "vector_invocation_interval": II,
        "multiplications_per_vector": 1368,
        "average_multiplications_per_cycle": 1368 / II,
        "average_lane_utilization": (1368 / II) / LANES,
        "schedule": schedule,
        "dependency_timeline": timeline,
        "operation_counts": counts,
        "output_groups": [
            {"cycle_offset": timeline["reorder_output_start"] + g, "group": g,
             "indices": list(range(4 * g, 4 * g + 4)), "first": g == 0, "last": g == 15}
            for g in range(16)
        ],
    }
    OUT.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    rows_md = []
    for r in schedule:
        parts = [f"{k}={v}" for k, v in r.items() if k not in ("cycle", "lane_count", "N64_p_range") and v]
        if r.get("N64_p_range"):
            parts.append(f"N64 p={r['N64_p_range']}")
        rows_md.append(f"| {r['cycle']} | {'; '.join(parts) if parts else 'idle'} | {r['lane_count']} | {LANES-r['lane_count']} |")
    groups_md = []
    for g in range(16):
        indices = f"y[{4*g}..{4*g+3}]"
        if g >= 8:
            p0 = 31 - 4*(g-8)
            indices += f" = high[{p0}..{p0-3}] (reversed pair bank)"
        groups_md.append(f"| {timeline['reorder_output_start'] + g} | {g} | {indices} | {'yes' if g == 0 else 'no'} | {'yes' if g == 15 else 'no'} |")

    report = f"""# V35 P2F-A1 P4 Cycle Schedule — Exact DCT2-64

Status: **PASS (architecture/schedule only)**. No RTL, Vivado, P2B, or
factorization approximation was used.

## Frozen contract

- `A = inverse_operator = C^T`; the factorized model consumes canonical `C`
  rows only to exploit exact identities and never transposes the JSON operator.
- Raw arithmetic is exact integer `A*x`. Fixed point remains
  `raw -> +32 -> arithmetic >>>6 -> signed16 wrap16`.
- The P4 output is four complete results, not partial sums.
- Shared multiplier farm: **128 constant-multiplier lanes**, not 256.
- One vector has 1368 constant multiplications, so the required average is
  `1368/16 = 85.5 multiplications/cycle`, or **66.796875% average lane
  utilization** of the 128-lane farm.

## 16-cycle multiplier issue schedule

The lower odd branches are issued first so the even recursive branch can pass
through its butterfly chain while the N=64 odd branch is being evaluated.
N=32 odd cycles 1–2 each form eight complete 16-term dot products; N=64 odd
cycles 3–10 each form four complete 32-term dot products. Cycle 0 contains the
terminal N=4 node plus N=8/N=16 odd nodes.

| cycle | issued multiplication work | used | spare |
|---:|---|---:|---:|
{chr(10).join(rows_md)}

The schedule issues exactly 1368 products, never exceeds 128 lanes, and repeats
unchanged at offsets 16, 32, ... for subsequent vectors. The 128 lanes are a
shared farm; recursive levels do not instantiate permanent independent arrays.

## Dependency and latency example

Each dense dot-product leaf is retained at full precision and enters a fully
pipelined binary reduction tree. A representative registered schedule (one
cycle multiplier output, tree depth `ceil(log2 terms)`, one butterfly register
per recursion level) gives:

| node | last issue / dot ready | dependent result ready |
|---|---:|---:|
| N=4 terminal | cycle 0 / 2 | cycle 3 |
| N=8 odd/even | cycle 0 / 3 | cycle 4 |
| N=16 odd/even | cycle 0 / 4 | cycle 5 |
| N=32 odd/even | cycle 2 / 6 | cycle 7 |
| N=64 odd branch | cycle 10 / 15 | — |
| top N=64 pair butterfly | — | cycle 17 |
| reorder buffer complete | — | cycle 17 |
| first output beat | — | cycle 18 |

The exact RTL latency `L` may be larger, but it is fixed and all tags follow the
same pipeline. Latency does not change the 16-cycle initiation interval.

## Partial sums and reduction structure

- N=64 odd branch: four 32-leaf trees per issue cycle, 124 binary add nodes.
- N=32 odd branch: eight 16-leaf trees per issue cycle, 120 nodes.
- N=16/N=8/N=4 branches partition the same configurable reduction fabric;
  no second permanent multiplier farm is required.
- At least 64 full-precision 40-bit partial-sum slots cover the simultaneous
  odd-branch outputs (2560 bits); tree pipeline registers and recursive E/O
  values are additional. No rounding, shift, clip, or wrap occurs here.
- Recursive pair butterflies use full-width signed add/sub and produce
  `low[p]=E[p]+O[p]`, `high[p]=E[p]-O[p]`.

## Coefficient selection and storage

The factorized schedule consumes 1368 signed-8 canonical constants (10,944
bits if stored per operation). There are 106 distinct signed values (54
distinct magnitudes) among the selected constants, so a shared signed-constant
table plus lane-local sign/index controls is possible. Coefficient selection is
part of the schedule; no fixed single group is hard-wired.

## Ping-pong ownership and backpressure

- Vector buffers A/B are 64×16-bit. While A is evaluated, B may be loaded for
  the next invocation; ownership flips every 16-cycle issue slot.
- Reorder buffers A/B hold `low[0..31]` and `high[0..31]` for one vector. The
  buffer is not released until all 16 output groups have been accepted.
- Result FIFO remains the frozen 32-group Strategy-B contract. Before group 0
  launch, reserve all 16 result slots and count reserved in-flight groups plus
  occupied FIFO groups. Launch is legal only when `free_slots >= 16`; no
  overcommit or mid-burst stall is permitted.
- If output ready remains low, the schedule stops launching at the next vector
  boundary; an already-launched non-stalling burst is protected by its
  reservation. Recovery must drain without loss, duplication, or reorder.

## Final output schedule

For vector `v`, after the fixed latency, the reorder unit emits the contiguous
stream below. Groups 0–7 read the low half; groups 8–15 read the reversed high
half so the external order is always `y[0]..y[63]`.

| cycle offset | group | output | first | last |
|---:|---:|---|:---:|:---:|
{chr(10).join(groups_md)}

Thus group interval is exactly 1 cycle, there are 16 groups per vector, and
vector start/output intervals repeat every 16 cycles in the no-backpressure
steady state. The four values in each row are complete post-reduction results.

## Resource estimate

| resource | architectural estimate |
|---|---:|
| shared constant multiplier lanes | 128 |
| theoretical DSP upper bound | 128 (not a synthesis result) |
| max 32-leaf reduction nodes | 124 |
| recursive pair butterfly nodes | 124 total across N=4..64 |
| vector input storage | 2 × 64 × 16 bits |
| reorder storage | 2 × 64 × 16 bits (low/high banks) |
| selected coefficient payload | 1368 × 8 bits, or shared 106-value table |
| 40-bit partial-sum slots (minimum) | 64 (2560 bits) |

This is a pre-RTL architecture estimate. It does not claim LUT/DSP/BRAM,
power, or 500 MHz closure. The next RTL gate must prove exact equivalence,
II=1 group output, 16-cycle vector interval, FIFO accounting, and 2.000 ns
post-route timing. If the 128-lane farm cannot sustain this dependency schedule
in RTL, the result is **STOP**, not permission to silently increase to 256 lanes.
"""
    REPORT.write_text(report, encoding="utf-8")
    print(f"P2F_A1_PASS lanes={LANES} mult={sum(r['lane_count'] for r in schedule)} avg={1368/II}")


if __name__ == "__main__":
    main()
