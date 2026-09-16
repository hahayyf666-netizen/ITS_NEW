# Step12F-P9 — Atomic Elastic Bank-Local Physical Read Command Boundary

## Decision

The second P9 read-command boundary is functionally passing and structurally effective, but it does not close the 500 MHz physical gate.

```text
P9 second round functional          PASS
P9 atomic command contract          PASS
fresh synthesis                     PASS_COMPLETED_BUT_TIMING_FAIL
fresh implementation                FULLY_ROUTED_BUT_TIMING_FAIL
500 MHz setup/hold                  STOP
new tag                             NOT CREATED
```

The implementation change is intentionally limited to `unified_its_wrapper.sv`. The frozen P4 arithmetic, input-cache memory type, bounded LFNST arithmetic, Oracle/profile, XDC, R4C, and `v3.5-18` remain unchanged.

## What was changed

The shared cache read path now uses one atomic elastic command bundle. Primary-V commands carry a four-bank mask; LFNST commands carry one bank. The bundle owns the physical per-slot/per-bank addresses and all response metadata.

```text
logical request
  -> atomic command valid/ready/fire
  -> registered physical bank addresses
  -> existing asynchronous LUTRAM
  -> owner-qualified response capture
```

The RAM address ports are unconditional connections from `rd_cmd_addr_q`. Invalidity is represented by command-valid/owner metadata, not by a valid/owner address mux. Response capture uses command slot/group/vector/LFNST metadata rather than live request counters. Request counters advance only on logical request acceptance, and retire/refill is allowed on the same edge.

## Functional evidence

ModelSim SE-64 2020.4 completed both normal and `SYNTHESIS` runs:

| Check | Result |
|---|---:|
| Gate-B numeric | 156 cases PASS |
| Gate-C engineering tuples | 369 |
| Gate-C beats per mode | 45,636 |
| LFNST engine specialty | 1,088 PASS |
| LFNST wrapper specialty | 258 PASS |
| 1-D vector-II modes | 13 PASS |
| group II | 1 |
| continuous N=4 stream | 16 vectors PASS |
| ownership/order/done/backpressure | PASS |

Evidence: `05_audit/current/46/p9_second_round_coverage_20260916/STEP12F_COVERAGE_MODELSIM_RUN.json`.

## Fresh synthesis

Vivado 2025.2, `xcku5p-ffvb676-2-e`, 2.000 ns clock, completed without elaboration failure:

| Stage | WNS | TNS | Failing endpoints |
|---|---:|---:|---:|
| Post-synthesis setup | -0.588 ns | -558.568 ns | 4,135 |

The synthesis checkpoint and reports are under `05_audit/current/47/p9_second_round_synth_20260916/`. The representative synthesis leader is `kernel_ctx_output_size_q_reg[3]/C -> lfnst_tail_index_q_reg[0]/CE`, with 2.483 ns data delay (0.531 ns logic, 1.952 ns estimated route, 9 levels).

Resource snapshot after synthesis is 30,128 CLB LUTs, 5,632 LUTRAM, 25,405 FF, 320 DSP48E2, 0 BRAM and 0 URAM. `check_timing` reports zero unconstrained internal endpoints and `report_exceptions` reports no valid timing exceptions.

## Fresh implementation

The design was independently implemented and fully routed using the existing Explore flow:

```text
opt_design Explore
place_design Explore
phys_opt_design Explore
route_design Explore
```

Final routed timing:

| Metric | Result |
|---|---:|
| Setup WNS | -0.560 ns |
| Setup TNS | -3,706.888 ns |
| Setup failing endpoints | 22,781 |
| Hold WHS | -0.080 ns |
| Hold THS | -3.426 ns |
| Hold failing endpoints | 46 |
| Clock period | 2.000 ns / 500 MHz |
| Route state | Fully Routed |
| Unconstrained internal endpoints | 0 |
| Valid timing exceptions | 0 |

The current global leader is an input-cache write/control path:

```text
slot_width_reg[1][5]_replica/C
  -> input-cache data_mem RAMD64E WE
```

It has 2.360 ns data delay (0.648 ns logic, 1.712 ns routing, 6 levels) and WNS `-0.560 ns`. Current routed resources are 30,128 CLB LUTs, 5,632 LUTRAM, 26,890 FF, 320 DSP48E2, 0 BRAM, 0 URAM; estimated total on-chip power is 1.948 W.

Evidence: `05_audit/current/48/p9_second_round_impl_20260916/`.

## Read-command qualification

The read-only qualification opened the new post-route DCP without modifying it. The old live-control paths are no longer found in the targeted sample:

```text
kernel read control -> LFNST response       NO_TIMING_PATHS
kernel vector -> P4 input_mem               NO_TIMING_PATHS
fire -> phase/state/forbidden group/drain   NO_TIMING_PATHS
fire -> allowed feed bookkeeping            5 paths (allowed)
```

The intended replacement path is visible and independently measurable:

```text
rd_cmd_addr_q_reg[0][0][1]_replica_1/C
  -> RAMD64E + LUT6/MUXF7/MUXF8
  -> lfnst_mem_resp_data_q_reg[2]/D
```

This path has WNS `-0.457 ns`, data delay 2.437 ns (0.548 ns logic, 1.889 ns routing, 6 levels). It is the registered-command-to-response path, and remains a local setup violation; it is not the global WNS leader.

The dedicated command-boundary query finds 125 command address Q/D objects. Live control reaches the command D only through the pre-boundary candidate logic (representative routed slacks `-0.115 ns` from `compute_slot_q` and `-0.032 ns` from `lfnst_case_q`); the old live-control-to-LFNST-response query and the live-control-through-RAMD64E-to-response query return no timing paths. The raw command-to-response path is retained in `path_reports/lfnst_through_ramd_top20.rpt`, which is the authoritative full-path report for the RAM/read-mux segment.

The worst-500 census contains 500 negative-slack paths. The prior A and B labels both have zero sampled paths. The new window is dominated by the classifier's cache/read/write family (466 paths, sampled negative-slack sum `-228.080 ns`, worst `-0.560 ns`); this representative family includes the current input-cache write WE leader and is not asserted to be one identical cone. The remaining sampled families are 6 cache/kernel/write paths (`-2.821 ns` sampled sum), 1 control path (`-0.477 ns`), and 27 other paths (`-12.857 ns`). These sums are a sampled worst-500 window, not full-design TNS.

The read-command high-fanout report shows replicated command-address nets at fanout up to 288, materially below the earlier 1,152-fanout physical address network. This supports the structural isolation result, but does not by itself prove timing closure.

Evidence: `05_audit/current/49/p9_second_round_qualification_20260916/`, especially `P9_A_ROUTED_READ_QUALIFICATION.json`, `p9_a_worst500.csv`, `path_reports/lfnst_through_ramd_top20.rpt`, and `P9_A_TARGETED_TIMING.rpt`.

## Comparison with P9 first round

| Metric | P9 first route | P9 second route |
|---|---:|---:|
| WNS | -0.720 ns | -0.560 ns |
| TNS | -5,894.764 ns | -3,706.888 ns |

The second round improves WNS by 0.160 ns and reduces the absolute TNS by 2,187.876 ns. The former live wrapper/kernel read family is displaced, but the design remains setup- and hold-failing. No claim is made that the command boundary alone closes 500 MHz.

## Frozen boundaries and next decision

This checkpoint does not authorize a tag or claim Step12F closure. Do not reopen the command boundary, Oracle/profile, XDC, R4C, or `v3.5-18` from this evidence alone. The next RTL repair must be chosen from the new routed families, most notably the input-cache write/control family and the residual bounded-LFNST product family, with setup and hold treated as separate signoff axes.
