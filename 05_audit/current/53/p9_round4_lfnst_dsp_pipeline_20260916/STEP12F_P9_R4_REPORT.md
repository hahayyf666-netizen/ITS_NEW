# Step12F-P9 Round 4 — Bounded LFNST DSP Product Pipeline

## Decision

P9 Round 4 is a valid functional and synthesis-recovery checkpoint. The bounded LFNST engine now captures operands in synchronous data-only registers and forms products in a separate registered stage. Normal and `SYNTHESIS` ModelSim coverage passed, fresh Vivado synthesis completed, and full implementation reached a fully routed design. The 500 MHz setup/hold gate remains open, so no performance tag is authorized.

```text
RTL review                         PASS
ModelSim normal                    PASS
ModelSim SYNTHESIS                 PASS
Fresh Vivado synthesis             PASS_COMPLETED_BUT_TIMING_FAIL
Fresh implementation               FULLY_ROUTED_BUT_TIMING_FAIL
Step12F 500 MHz signoff            STOP / P1
New tag                            NOT AUTHORIZED
```

## Scope and frozen boundaries

Only `02_rtl/rtl/bounded_lfnst_engine.sv` changed. The change adds a synchronous operand/product boundary for the bounded LFNST datapath. Validity and transaction metadata remain asynchronously reset; arithmetic data registers are intentionally not asynchronously reset so DSP input/product registers can be inferred without making stale invalid data observable.

The unified P4 kernel, wrapper, input-cache bank, Gate-A Oracle, `contest_engineering_vtm10_v1` profile, XDC, frozen R4C, and annotated tag `v3.5-18` remain unchanged. Coefficients, term ordering, reduction, rounding, clipping, LOW10 behavior, and external protocol were not changed.

## Functional qualification

ModelSim SE-64 2020.4 ran both normal and `+define+SYNTHESIS` modes. The authoritative result is `STEP12F_COVERAGE_MODELSIM_RUN.json`.

| Check | Normal | Synthesis |
|---|---:|---:|
| Gate-B numeric | 156 | 156 |
| Legacy vector-II modes | 7 | 7 |
| Full 13-mode vector-II | PASS | PASS |
| Gate-C engineering tuples | 369 | 369 |
| Gate-C beats | 45,636 | 45,636 |
| LFNST engine specialty | 1,088 | 1,088 |
| LFNST wrapper specialty | 258 | 258 |
| P4 Stage-0 N=4 stream | 16 | 16 |
| Compile/errors | PASS / 0 | PASS / 0 |

The recorded contracts remain `group II=1`, `vector II=N/4`, sparse raster input, rectangles, LFNST, backpressure, two-TU behavior, and LOW10 output.

## Fresh synthesis

Vivado 2025.2 (Build 6299465), device `xcku5p-ffvb676-2-e`, and a 2.000 ns clock were used. Synthesis completed without elaboration/OOM failure.

| Metric | Post-synthesis |
|---|---:|
| WNS / TNS | -0.564 ns / -48.984 ns |
| Setup failing endpoints | 298 |
| WHS / THS | -0.076 ns / -4.741 ns |
| Hold failing endpoints | 73 |
| Unconstrained internal endpoints | 0 |
| DSP48E2 | 320 total; 64 in bounded LFNST hierarchy |
| CLB LUTs / registers | 27,997 / 23,340 |
| LUTRAM | 5,641 |
| BRAM / URAM | 0 / 0 |

The bounded LFNST hierarchy is synthesizable and consumes 2,392 LUTs, 2,182 FFs, and 64 DSP48E2. Postsynthesis DRC reports 32 DPIP-2 and 32 DPOP-3 advisory warnings; these are pipeline advisories, not DRC errors or waived timing constraints.

## Fresh implementation

The fresh postsynthesis checkpoint was implemented with the same device and 2.000 ns constraint. `report_drc_postroute.rpt` reports `Design State : Fully Routed` and zero DRC errors. Final post-route results are:

| Metric | Post-route |
|---|---:|
| Setup WNS / TNS | -0.113 ns / -8.032 ns |
| Setup failing endpoints | 259 |
| Hold WHS / THS | -0.080 ns / -4.911 ns |
| Hold failing endpoints | 76 |
| Unconstrained internal endpoints | 0 |
| Valid timing exceptions | 0 (`No valid timing exceptions found.`) |
| Route state | Fully Routed |
| Estimated total on-chip power | 1.864 W |

The routed WNS leader is no longer the bounded-LFNST product path. It is an H-read/temp-bank distributed-RAM path:

```text
kernel_h_rd_addr_q_reg[3][1]/C
  -> kernel_h_rd_data_tail_q_reg[48]/D
WNS       -0.113 ns
data      2.095 ns
logic     0.443 ns (21.145%)
routing  1.652 ns (78.855%)
levels    5 (LUT4, LUT6, MUXF7, MUXF8, RAMD64E)
```

The next representative paths are also H-read/temp-bank or kernel write-control routes (for example -0.096 ns and -0.094 ns). This is evidence that the DSP pipeline made the bounded LFNST structure synthesizable and moved the leading physical bottleneck; it is not 500 MHz signoff.

Post-route DRC contains 32 DPIP-2, 32 DPOP-4, and one RTSTAT-10 warning, with zero errors. The DPOP advisory means there is no blanket proof that every inferred bounded-LFNST product uses a DSP PREG; physical optimization did move internal registers for many products, but the report remains the authoritative boundary.

## Status and next action

```yaml
P9_R4_functional: PASS
P9_R4_synthesis: PASS_COMPLETED_BUT_TIMING_FAIL
P9_R4_full_route: FULLY_ROUTED_BUT_TIMING_FAIL
Step12F_setup: FAIL
Step12F_hold: FAIL
Step12F_500MHz: STOP / P1
tag: NOT_CREATED
```

The next repair should be selected from the new routed census. The current leading family is H-read/temp-bank distributed-RAM routing; do not immediately modify the LFNST arithmetic again. The full path reports, DCPs, logs, timing, DRC, utilization, power, and coverage JSON are retained beside this report.
