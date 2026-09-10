"""Deterministic P2F-Pre equivalence and complexity study."""
from __future__ import annotations

import json
import random
from pathlib import Path
from typing import Iterable

from dct2_64_factorized import ExactDCT2Factorizer, wrap_signed_16

ROOT = Path(__file__).resolve().parent
RESULTS = ROOT / "p2f_equivalence_results.json"
REPORT = ROOT / "V35_P2F_PRE_FACTOR_ARCHITECTURE.md"
WIDTH = 64
MAX16 = 32767
MIN16 = -32768


def alternating(a: int, b: int) -> list[int]:
    return [a if i % 2 == 0 else b for i in range(WIDTH)]


def sparse_vectors() -> list[tuple[str, list[int]]]:
    cases: list[tuple[str, list[int]]] = []
    x = [0] * WIDTH
    x[0], x[63] = MAX16, MIN16
    cases.append(("sparse_first_last_opposite", x))
    x = [0] * WIDTH
    x[1], x[62] = MIN16, MAX16
    cases.append(("sparse_second_penultimate_opposite", x))
    x = [0] * WIDTH
    for i in (0, 7, 16, 31, 32, 47, 63):
        x[i] = MAX16 if i % 2 == 0 else MIN16
    cases.append(("sparse_mixed_extreme", x))
    x = [0] * WIDTH
    for i in range(0, WIDTH, 8):
        x[i] = MIN16
    cases.append(("sparse_negative_every8", x))
    x = [0] * WIDTH
    for i in range(3, WIDTH, 8):
        x[i] = MAX16
    cases.append(("sparse_positive_every8", x))
    return cases


def deterministic_cases() -> list[tuple[str, list[int]]]:
    cases: list[tuple[str, list[int]]] = [("zero", [0] * WIDTH)]
    cases += [("all_positive_max", [MAX16] * WIDTH), ("all_negative_min", [MIN16] * WIDTH)]
    cases += [("alternating_positive_negative", alternating(MAX16, MIN16))]
    cases += [("alternating_negative_positive", alternating(MIN16, MAX16))]
    for k in range(WIDTH):
        x = [0] * WIDTH
        x[k] = MAX16
        cases.append((f"single_max_{k}", x))
        x = [0] * WIDTH
        x[k] = MIN16
        cases.append((f"single_min_{k}", x))
    cases.extend(sparse_vectors())
    for k in range(WIDTH):
        x = [0] * WIDTH
        x[k] = 1
        cases.append((f"one_hot_{k}", x))
    return cases


def random_cases(seed: int, count: int) -> Iterable[tuple[str, list[int]]]:
    rng = random.Random(seed)
    for i in range(count):
        yield f"random_seed{seed}_{i:03d}", [rng.randint(MIN16, MAX16) for _ in range(WIDTH)]


def check_case(f: ExactDCT2Factorizer, name: str, x: list[int]) -> dict:
    factor = f.factorized_details(x)
    direct = f.direct_details(x)
    raw_match = factor.raw == direct.raw
    matches = {
        "raw_match": raw_match,
        "biased_match": factor.biased == direct.biased,
        "shifted_match": factor.shifted == direct.shifted,
        "stage16_match": factor.stage16 == direct.stage16,
    }
    if not raw_match or not all(matches.values()):
        for i, (a, b) in enumerate(zip(factor.raw, direct.raw)):
            if a != b:
                raise AssertionError(f"{name}: raw mismatch at output {i}: {a} != {b}")
        raise AssertionError(f"{name}: fixed-point mismatch")
    return {
        "name": name,
        **matches,
        "positive_wrap_outputs": sum(v > MAX16 for v in factor.shifted),
        "negative_wrap_outputs": sum(v < MIN16 for v in factor.shifted),
    }


def main() -> None:
    f = ExactDCT2Factorizer()
    cases = deterministic_cases()
    seeds = [20260904, 20260905, 20260906, 20260907]
    for seed in seeds:
        cases.extend(random_cases(seed, 256))
    records = [check_case(f, name, x) for name, x in cases]
    counts = f.operation_counts()
    wrap_positive = [r["name"] for r in records if r["positive_wrap_outputs"]]
    wrap_negative = [r["name"] for r in records if r["negative_wrap_outputs"]]

    anchor_dct2 = f.factorized_raw([1] + [0] * 63)
    assert anchor_dct2 == [64] * 64, anchor_dct2[:8]
    anchor_dct2_4 = f.factorized_raw_size(4, [1, 0, 0, 0])
    assert anchor_dct2_4 == [64, 64, 64, 64], anchor_dct2_4
    fp_anchor = f.factorized_details([64] + [0] * 63)
    assert fp_anchor.raw == [64 * 64] * 64
    assert fp_anchor.shifted == [64] * 64
    assert all(wrap_signed_16(v) == v for v in fp_anchor.shifted)

    summary = {
        "status": "PASS",
        "case_count": len(records),
        "raw_equivalence_pass": sum(r["raw_match"] for r in records),
        "fixed_point_equivalence_pass": sum(
            r["biased_match"] and r["shifted_match"] and r["stage16_match"] for r in records
        ),
        "fail_count": 0,
        "random": {"seeds": seeds, "vectors_per_seed": 256},
        "orientation_anchors": {
            "dct2_4_one_hot_raw": [64, 64, 64, 64],
            "dct2_64_x0_one_hot_raw_first8": anchor_dct2[:8],
            "x0_64_fixedpoint_raw_first4": fp_anchor.raw[:4],
        },
        "wrap_evidence": {
            "positive_case_count": len(wrap_positive),
            "negative_case_count": len(wrap_negative),
            "positive_examples": wrap_positive[:10],
            "negative_examples": wrap_negative[:10],
        },
        "operation_counts": counts,
        "records": records,
    }
    RESULTS.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    report = f"""# V35 P2F-Pre Exact DCT2-64 Factorization Study

Status: **PASS** (software-only; no RTL or Vivado was run)

## Frozen mathematical contract

- Canonical source matrix is `C`; the consumed inverse operator is the frozen
  `inverse_operator A=C^T`.
- The direct reference computes `raw=A*x` without transposing the JSON value.
- The factorized model uses exact canonical source rows and never inserts
  rounding, shift, clipping, or wrap in the raw path.
- Fixed point remains `raw -> +32 -> arithmetic >>6 -> signed16 wrap`.

## Exact matrix structure used

For every `N` in 4, 8, 16, 32, 64, the canonical matrix was checked for exact
even/odd mirror identities and, for N>4, the even-row recursion:

```text
C_N[2m][p] = C_(N/2)[m][p]                 (p < N/2)
C_N[2m][N-1-p] = C_(N/2)[m][p]
C_N[2m+1][N-1-p] = -C_N[2m+1][p]
```

The recursive exact node is:

```text
E[p] = sum_m C_N[2m][p]   * x[2m]
O[p] = sum_m C_N[2m+1][p] * x[2m+1]
y[p]       = E[p] + O[p]
y[N-1-p]   = E[p] - O[p]
```

For N>4, E is recursively evaluated by canonical DCT2-(N/2). The odd branch
is retained as an exact dense odd-frequency submatrix; no approximate textbook
coefficients are substituted. N=4 is the terminal pair node.

## Equivalence results

| Check | Result |
|---|---:|
| Total vectors | {len(records)} |
| Raw factorized vs A*x | {sum(r['raw_match'] for r in records)}/{len(records)} |
| Biased raw+32 | {sum(r['biased_match'] for r in records)}/{len(records)} |
| Arithmetic >>6 | {sum(r['shifted_match'] for r in records)}/{len(records)} |
| Signed16 wrap stage | {sum(r['stage16_match'] for r in records)}/{len(records)} |
| Failures | 0 |
| Fixed random seeds | {', '.join(str(s) for s in seeds)} |
| Random vectors per seed | 256 |
| Positive wrap cases observed | {len(wrap_positive)} |
| Negative wrap cases observed | {len(wrap_negative)} |

The deterministic suite includes all 64 one-hot vectors, zero, all positive and
negative extremes, both alternating extremes, every single max/min input, and
sparse mixed extremes. The orientation anchor x=[1,0,...] produces [64]*64
for DCT2-64 (and [64,64,64,64] for DCT2-4), preventing an accidental return
to C*x.

## Complexity

| Metric (whole vector) | Direct 64x64 | Exact factorized model |
|---|---:|---:|
| Constant multiplications | 4096 | {counts['factorized_constant_multiplications']} |
| Add/sub nodes | 4032 | {counts['factorized_total_add_sub_nodes']} |
| Multiplier reduction | 1.00x | {counts['factorized_mult_reduction_ratio']:.3f}x |
| Add/sub reduction | 1.00x | {counts['factorized_add_reduction_ratio']:.3f}x |
| Unique signed constants used | — | {counts['unique_signed_constants_used']} |
| Unique absolute constants used | — | {counts['unique_absolute_constants_used']} |

The direct P2A baseline is 256 multiplication lanes and 252 reduction add
nodes per four-output issue. The exact model reduces whole-vector constant
products by about 2.99x and add/sub nodes by about 2.82x. These are operation
counts, not a placed FPGA result.

## P4 architecture candidate

The top-level pair node can evaluate four p positions per cycle. It writes
`low[p]=E[p]+O[p]` and `high[p]=E[p]-O[p]` into two ping-pong reorder buffers.
The reorder unit emits contiguous `y[0..63]` as sixteen four-value groups:
eight low-half groups followed by eight reversed high-half groups. A fully
pipelined odd branch for four p positions uses 128 constant multiplier lanes
(`4*32`); the recursively factored even branch is a separate II=1 subengine.
With two reorder buffers and a four-p position issue rate, the design has an
architectural path to four complete outputs per cycle after fill while a second
vector is evaluated in the other buffer. Exact latency, FIFO accounting and
500 MHz timing remain RTL gates; this report does not claim them as proven.

Any implementation must preserve group issue interval 1, vector interval <=16,
tag alignment, the frozen 32-group result FIFO contract, and backpressure
correctness. Intermediate rounding, clipping, wrap, or approximate constants
would invalidate equivalence.

## Future sharing scope

Signed constant multipliers, add/sub butterflies, pair/reorder buffers, and a
parameterized odd-frequency submatrix interface can be shared by other DCT2
sizes. DCT8/DST7 are not factored here; their canonical matrices must be
separately proven before reuse.

## Artifacts

- `dct2_64_factorized.py` — exact recursive model and complexity counter.
- `run_p2f_equivalence.py` — deterministic equivalence runner.
- `p2f_equivalence_results.json` — generated results and per-case records.

No V3.4 file, ROM, golden vector, RTL, or Vivado result was modified or used
as expected output.
"""
    REPORT.write_text(report, encoding="utf-8")
    print(f"P2F_PASS {len(records)} vectors; positive_wrap={len(wrap_positive)} negative_wrap={len(wrap_negative)}")


if __name__ == "__main__":
    main()
