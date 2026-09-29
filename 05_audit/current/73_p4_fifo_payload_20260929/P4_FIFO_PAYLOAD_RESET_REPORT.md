# P4 output FIFO payload reset removal

Date: 2026-09-29 (Asia/Shanghai)  
Repository: `hahayyf666-netizen/ITS_NEW`  
Source commit: `9e67d4aa2696255f8b527a614e872cb367e654ce`  
Parent: `03406a706471b53092d0e5e33e963ed72d0a583e`

## Decision

**Retain the change.** The FIFO payload is now inferred as distributed RAM instead of 4,096 asynchronously resettable payload FFs. FIFO pointers, count, `fifo_last_q`, and ownership/valid metadata remain asynchronously reset. The payload still has synchronous writes and asynchronous reads; no protocol-visible latency or throughput change was introduced.

Functional qualification passed in normal and `SYNTHESIS` modes. A fresh SAT10 registered-neighbor implementation completed and is fully routed. Setup improved substantially relative to the earlier fresh SAT10 baseline, and hold remains passing, but setup is still not closed at 500 MHz.

## Functional evidence

The post-commit run used ModelSim SE-64 2020.4 and records `tested_source_commit=9e67d4aa2696255f8b527a614e872cb367e654ce` in `functional/STEP12F_COVERAGE_MODELSIM_RUN.json`.

Both normal and `SYNTHESIS` runs passed:

- Gate-B numeric: 156 cases; Gate-B II: 7 modes; Gate-F II: 13 modes.
- Gate-C wrapper: 369 tuples / 45,636 beats.
- LFNST engine: 1,088 cases; LFNST wrapper: 388 cases.
- P4 N=4 stream: 16 consecutive vectors.
- SAT10 adapter exhaustive: all 65,536 signed-16 inputs.
- SAT10 wrapper boundary: 3 cases / 16 beats; submission-top smoke: 2 TUs / 8 beats / 2 done pulses, with 80 observed stall cycles.
- New FIFO reset test: reset while a result was in flight and while nonzero payload was queued; no stale output after reset.

Compile/test logs report zero errors and zero warnings. The complete manifests, vectors, and per-test logs are retained under `functional/`.

## Mapping and physical result

Vivado 2025.2, build `6299465`, part `xcku5p-ffvb676-2-e`, four threads, 2.000 ns clock, SAT10 registered-neighbor harness, same flow as the earlier baseline:

```text
synth_design -directive Default
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation
```

Synthesis identified `fifo_data_q_reg` as a 64×64 distributed memory (`RAM64M8 x10` before netlist optimization). The post-opt targeted query found 85 mapped cells for the FIFO payload: `RAM64M8 x9`, `RAM64X1D x1`, `RAMD64E x74`, and one `LUT4`. The DCPs are not included in this evidence commit; the post-synthesis and post-route DCP SHA-256 values are recorded in `P4_FIFO_PAYLOAD_RESET_STATUS.json`.

| Metric | Prior SAT10 baseline | Candidate | Change |
|---|---:|---:|---:|
| Setup WNS, all groups | -0.103 ns | -0.045 ns | +0.058 ns |
| Setup TNS, all groups | -30.143 ns | -3.537 ns | +26.606 ns |
| Setup failing endpoints | 937 | 177 | -760 |
| Hold WHS / THS | +0.008 / 0.000 ns | +0.003 / 0.000 ns | hold still passes |
| CLB LUTs (incl. LUTRAM) | 27,326 | 26,520 | -806 |
| LUTRAM | 5,644 | 5,718 | +74 |
| FF | 25,433 | 21,339 | -4,094 |
| CARRY8 / DSP | 1,500 / 320 | 1,494 / 320 | -6 / unchanged |
| Vectorless power estimate | 1.872 W | 1.498 W | -0.374 W |
| Dynamic / static estimate | 1.411 / 0.461 W | 1.040 / 0.458 W | -0.371 / -0.003 W |

The power result is a medium-confidence vectorless estimate without an activity file, not measured power. The prior baseline and candidate are independent fresh implementations, not same-placement A/B; therefore the resource/mapping change is directly attributable, while the full timing delta also includes placement/routing variation.

Candidate route status: all 43,864 routable nets fully routed, zero routing-error nets. Hold has zero failing endpoints. `check_timing` reports zero unconstrained internal endpoints; the sole no-input-delay port is `rst_n`. No valid timing exceptions were found. DRC has zero errors. The two DRC critical warnings (`NSTD-1`, `UCIO-1`) are the registered-neighbor harness `clk` and `rst_n` ports without package pin/IO-standard constraints; this run is not package-level signoff.

The new global leader is an H-read path:

```text
kernel_h_rd_addr_q_reg[1][0]/C
  → temporary-bank RAMD64E read and LUT6/MUXF7/MUXF8
  → kernel_h_rd_data_q_reg[20]/D

data delay 1.860 ns; logic 0.469 ns; routing 1.391 ns (74.8%); 5 logic levels
slack -0.045 ns
```

The async-default recovery group is now positive (`WNS +0.033 ns`, zero failing endpoints), versus `-0.038 ns / 140` on the earlier baseline. The design nevertheless remains **500 MHz setup FAIL** (`177` failing endpoints), so this is an effective optimization checkpoint, not timing signoff.

## Provenance and boundaries

- Profile: `contest_engineering_vtm10_sat10_v2`; canonical SHA-256 `FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746`; adapter SAT10 `[-512, 511]`.
- Functional and physical run commands, exit codes, per-test logs, source hashes, and report hashes are retained in this directory and the run manifests.
- `official_equivalence = NOT_PROVEN`.
- Package-level FPGA timing/signoff = `NOT_EVALUATED`.
- No LOW10 history was changed; no tag was created; no merge to `main` was performed.

## Next timing target

Keep this FIFO change. The immediate timing target is the H-read temporary-bank asynchronous read-to-response path above, not the P4 payload FIFO. Its slack is only -45 ps, but the remaining all-endpoint setup tail is not yet a single-family closure; any next change should be a narrowly scoped H-read response-boundary proposal with group-II and H recurrence preserved, then validated with the same full functional and physical flow.
