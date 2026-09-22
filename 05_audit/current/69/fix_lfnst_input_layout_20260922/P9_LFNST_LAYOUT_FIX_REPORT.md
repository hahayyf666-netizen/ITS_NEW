# LFNST fixed-layout correction — qualification report

## Scope

This checkpoint corrects the `nTrs=48` output scatter order on top of
`504630694abcd4376ac27c209ad1275080f3c9fc`.  It does not merge to `main` and
does not run synthesis or place/route.

The fixed contract is:

- input: the source-backed low-frequency 4x4 order
  `00,10,01,20,11,02,30,21,12,03,31,22,13,32,23,33`;
- `nTrs=16`: top-left 4x4 row-major;
- `nTrs=48`: top 4x8 row-major (`0..31`), then bottom-left 4x4 row-major
  (`32..47`); bottom-right 4x4 is zero/invalid;
- 8x8 `nTrs=48`: `nonZeroSize=8`.

## Directed contract checks

`test_lfnst_layout_contract.py` checks both independent Python models against
literal expected coordinates, including output indices `0, 4, 7, 8, 15, 16,
31, 32, 47`.  It also injects nonzero values at `(4,4)` and `(7,7)` and
requires the 8x8 LFNST result to equal the clean zero-tail result.

Result:

```text
PASS_LFNST_LAYOUT_CONTRACT scatter=16/48 boundaries=9 tail_poison=PASS
```

## ModelSim qualification

The existing Step12F coverage runner completed in both modes:

| mode | Gate-B | Gate-F | Gate-C | LFNST engine | LFNST wrapper |
|---|---:|---:|---:|---:|---:|
| normal | 156 | 13 modes | 369 / 45,636 beats | 1,088 | 388 |
| SYNTHESIS | 156 | 13 modes | 369 / 45,636 beats | 1,088 | 388 |

P3 vwrite, P4 stage-0 issue, wrapper smoke, ownership/order/backpressure
checks also passed.  The wrapper specialty count is 388 because this
checkpoint adds one explicit tail-poison vector to the prior 387 cases.

## Boundary

Fresh Vivado synthesis, placement, routing, PPA, and 500 MHz timing are not
run in this checkpoint.  The prior R6 timing baseline is not inherited after
this functional RTL/layout correction.
