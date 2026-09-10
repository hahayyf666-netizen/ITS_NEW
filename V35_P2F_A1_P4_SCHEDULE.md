# V35 P2F-A1 P4 Cycle Schedule — Exact DCT2-64

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
| 0 | N4_terminal=8; N8_odd=16; N16_odd=64 | 88 | 40 |
| 1 | N32_odd=128 | 128 | 0 |
| 2 | N32_odd=128 | 128 | 0 |
| 3 | N64_odd=128; N64 p=0..3 | 128 | 0 |
| 4 | N64_odd=128; N64 p=4..7 | 128 | 0 |
| 5 | N64_odd=128; N64 p=8..11 | 128 | 0 |
| 6 | N64_odd=128; N64 p=12..15 | 128 | 0 |
| 7 | N64_odd=128; N64 p=16..19 | 128 | 0 |
| 8 | N64_odd=128; N64 p=20..23 | 128 | 0 |
| 9 | N64_odd=128; N64 p=24..27 | 128 | 0 |
| 10 | N64_odd=128; N64 p=28..31 | 128 | 0 |
| 11 | idle | 0 | 128 |
| 12 | idle | 0 | 128 |
| 13 | idle | 0 | 128 |
| 14 | idle | 0 | 128 |
| 15 | idle | 0 | 128 |

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
| 18 | 0 | y[0..3] | yes | no |
| 19 | 1 | y[4..7] | no | no |
| 20 | 2 | y[8..11] | no | no |
| 21 | 3 | y[12..15] | no | no |
| 22 | 4 | y[16..19] | no | no |
| 23 | 5 | y[20..23] | no | no |
| 24 | 6 | y[24..27] | no | no |
| 25 | 7 | y[28..31] | no | no |
| 26 | 8 | y[32..35] = high[31..28] (reversed pair bank) | no | no |
| 27 | 9 | y[36..39] = high[27..24] (reversed pair bank) | no | no |
| 28 | 10 | y[40..43] = high[23..20] (reversed pair bank) | no | no |
| 29 | 11 | y[44..47] = high[19..16] (reversed pair bank) | no | no |
| 30 | 12 | y[48..51] = high[15..12] (reversed pair bank) | no | no |
| 31 | 13 | y[52..55] = high[11..8] (reversed pair bank) | no | no |
| 32 | 14 | y[56..59] = high[7..4] (reversed pair bank) | no | no |
| 33 | 15 | y[60..63] = high[3..0] (reversed pair bank) | no | yes |

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
