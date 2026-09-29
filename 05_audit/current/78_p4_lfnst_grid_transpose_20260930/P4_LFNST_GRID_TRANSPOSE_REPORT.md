# P4 LFNST grid transpose — functional and physical result

Date: 2026-09-30 (Asia/Shanghai)  
Source commit: `17496666f3192cd3e1f96ae4e590c2b3b77919f4`  
Branch: `sat10-functional-evidence`

## Decision

The vector-major LFNST grid transpose is **functionally qualified and physically effective**, but 500 MHz setup is **not closed**. Keep the candidate; do not call this signoff.

The full registered-neighbor implementation completed and is fully routed. Final setup is `WNS=-0.005 ns`, `TNS=-0.015 ns`, with 4 failing endpoints. Hold passes at `WHS=+0.010 ns`, `THS=0`, with no failing endpoints. The result is 5 ps short of setup closure.

Against the existing SAT10 CONTROL replay from the same implementation flow (`WNS=-0.034 ns`, `TNS=-2.026 ns`, 134 setup endpoints; hold `+0.007 ns`), this fresh candidate run improved WNS by 29 ps, reduced setup TNS magnitude by 2.011 ns, and reduced failing endpoints by 130. Because the candidate was freshly synthesized while CONTROL replayed its frozen common post-opt DCP, this is a strong engineering comparison, not an identical-netlist placement A/B.

## Functional gates

The full ModelSim runner passed in both normal and `SYNTHESIS` modes, with zero compile errors or warnings. A commit-bound rerun records `tested_source_commit=17496666f3192cd3e1f96ae4e590c2b3b77919f4`; its wrapper working-tree SHA-256 matches the source hash recorded for that commit. The run was bound to the SAT10 v2 profile (`contest_engineering_vtm10_sat10_v2`, canonical SHA-256 `FEA3ACB18C5C35EB0FD8A8DBF533C3A6BE7536BCC8EF5FDB87135DF512643746`).

- Gate-B: 156 numeric cases; 7 legacy II modes.
- Gate-F: 13 II modes.
- Gate-C: 369 tuples / 45,636 beats.
- LFNST engine: 1,088 cases; wrapper: 388 cases / 6,724 beats.
- SAT10 adapter: exhaustive 65,536 signed-16 values.
- SAT10 wrapper boundaries: 3 cases / 16 beats.
- Submission-top smoke: 2 TUs / 8 beats / 2 done pulses; 80 real pending-output stall cycles.
- The simulation-only row-major shadow assertion checked each accepted LFNST-to-P4 group; no mismatch occurred.

The authoritative commit-bound run manifest and all normal/SYNTHESIS logs, vector manifests, and vector files are in `77_p4_lfnst_transpose_20260930_090000_commitbound`. A preceding exploratory run recorded the pre-commit parent SHA; it is excluded from this evidence package and is not the authority for this checkpoint.

## RTL and mapping result

Only `02_rtl/rtl/unified_its_wrapper.sv` changed in the source commit. LFNST results are stored vector-major (`vector*8 + sample`) while logical row-major writeback coordinates and values are preserved. The simulation-only shadow asserts equivalence at every real P4 input-group acceptance. No arithmetic, handshake, latency, memory type, XDC, or SAT10 policy changed.

Unplaced post-opt targeted path from `lfnst_grid` to P4 ingress improved from 5 LUT levels / `1.373 ns` data (`0.560 ns` logic, `0.813 ns` route) to 4 LUT levels / `1.107 ns` (`0.393 ns` logic, `0.714 ns` route), a 266 ps improvement. This is a synthesis-level targeted result, not routed path signoff.

## Remaining routed setup tail

1. `kernel_ctx_output_size_q` → `kernel_feed_group_q/CE`: `-0.005 ns`, 7 levels, 58.4% route delay.
2. `kernel_stage_q` → P4 `ingress_data_q/D`: `-0.005 ns`, 5 levels, 63.6% route delay.
3. `slot_state` → `lfnst_grid/CE`: `-0.002 ns`, 3 levels, 76.1% route delay.
4. P4 `ready_rd_ptr_q` → `issue_desc_bundle_addr_q/D`: `-0.002 ns`, 5 levels, 76.5% route delay.

The LFNST grid read is no longer the global leader. The remaining failures are tiny, multi-family control/ingress tail paths; this run does not establish that the transpose alone caused the full global QoR change.

## Physical implementation

- Vivado 2025.2 build 6299465; `xcku5p-ffvb676-2-e`; `maxThreads=4`.
- Top: `step12f_registered_neighbor_harness`; SAT10 parameter `FINAL_SATURATE=1`.
- 2.000 ns clock; setup/hold user uncertainty 0; effective reported path uncertainty 0.035 ns from Vivado default system jitter.
- Flow: `synth_design -directive Default`; `opt_design -directive Default`; `place_design -directive ExtraNetDelay_high`; `phys_opt_design -directive AggressiveExplore`; `route_design -directive NoTimingRelaxation`.
- Boundary anti-pruning: 54/54 source FF and 44/44 sink FF found.
- Route status: 43,489/43,489 routable nets fully routed; 0 routing-error nets.
- Check timing: 0 unconstrained internal endpoints. Exceptions report: no valid timing exceptions.
- Post-route resources: 26,391 CLB LUTs (20,673 logic + 5,718 LUTRAM), 21,202 registers, 1,500 CARRY8, 320 DSP, 0 BRAM, 0 URAM.
- Vectorless power estimate: 1.502 W (1.044 W dynamic, 0.458 W static), medium confidence, no activity file.
- DRC errors: 0. Harness-only `NSTD-1`/`UCIO-1` critical warnings remain for `clk`/`rst_n` lacking package pin/IO-standard constraints; package-level signoff is not in scope. DSP pipelining warnings/advisories remain.

## Scope and evidence boundary

`official_equivalence=NOT_PROVEN`. Package-level FPGA timing is not evaluated. Historical LOW10 and prior R6 timing are reference-only. This is a registered-neighbor core result, not a package-level signoff. Full DCPs are retained in the local implementation output directory and are not committed; their SHA-256 values are in `P4_LFNST_GRID_TRANSPOSE_STATUS.json`.

The source diff contains line-ending normalization noise; `git diff --ignore-space-at-eol` against the physical CONTROL RTL shows the intended wrapper-only change (89 insertions, 8 deletions). Review with whitespace ignored when inspecting the raw diff.
