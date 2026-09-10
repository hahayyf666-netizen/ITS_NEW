# V35 P2F-Pre Exact DCT2-64 Factorization Study

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
| Total vectors | 1226 |
| Raw factorized vs A*x | 1226/1226 |
| Biased raw+32 | 1226/1226 |
| Arithmetic >>6 | 1226/1226 |
| Signed16 wrap stage | 1226/1226 |
| Failures | 0 |
| Fixed random seeds | 20260904, 20260905, 20260906, 20260907 |
| Random vectors per seed | 256 |
| Positive wrap cases observed | 1158 |
| Negative wrap cases observed | 1156 |

The deterministic suite includes all 64 one-hot vectors, zero, all positive and
negative extremes, both alternating extremes, every single max/min input, and
sparse mixed extremes. The orientation anchor x=[1,0,...] produces [64]*64
for DCT2-64 (and [64,64,64,64] for DCT2-4), preventing an accidental return
to C*x.

## Complexity

| Metric (whole vector) | Direct 64x64 | Exact factorized model |
|---|---:|---:|
| Constant multiplications | 4096 | 1368 |
| Add/sub nodes | 4032 | 1428 |
| Multiplier reduction | 1.00x | 2.994x |
| Add/sub reduction | 1.00x | 2.824x |
| Unique signed constants used | — | 106 |
| Unique absolute constants used | — | 54 |

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
