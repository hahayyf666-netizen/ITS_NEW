# Latest-source fixed-placement router A/B

## Decision

**Result: MIXED / INCONCLUSIVE.** `MoreGlobalIterations` reduced synchronous setup TNS and the number of failing endpoints, but worsened WNS by 41 ps, reduced hold margin by 8 ps, and introduced a small negative `async_default` max-path group. It is not promoted as the implementation baseline and does not close timing.

No RTL, profile, or XDC changed for this experiment. No functional regression was rerun because the tested source is frozen. No synthesis was rerun. The two route branches were launched from one shared post-phys-opt checkpoint, with the router directive as the only branch variable.

## Provenance and controlled-flow checks

- Tested source commit: `9d7510e75385c3b83cee7afd799c9e6db0b4d95e` (`Simplify accepted-input feed group counter`).
- Evidence checkout before this report: `b4fd5c32b05f89710c0c45dd0dfb55922e304cbf`.
- `git diff --quiet <tested-source> <evidence-checkout> -- 02_rtl 03_verification` returned `0`; the RTL, registered-neighbor harness, XDC, and profile were unchanged after the tested source commit.
- `SHA256SUMS.csv` records both execution-host working-tree SHA-256 and the Git clean-filtered blob object ID for each published text artifact. This avoids treating Windows line-ending conversion as a content discrepancy. The CSV does not hash itself; the evidence commit pins it.
- Device/tool: Vivado 2025.2 build `6299465`, `xcku5p-ffvb676-2-e`, `general.maxThreads=4`.
- Clock: 2.000 ns (500 MHz). XDC user setup/hold uncertainty is 0.000 ns. The timing report's total uncertainty is 0.035 ns because Vivado includes its 0.071 ns total-system-jitter term; this is not user-specified uncertainty.
- Profile: `contest_engineering_vtm10_sat10_v2`; official equivalence remains `NOT_PROVEN`.
- Input postsynth DCP SHA-256: `4813F4F6AB0977AAFDE383443E05CD70A14BDA7D7CD3BF10B52747B7FAD6D27C`.
- One shared preparation flow: `opt_design -directive Default`; `place_design -directive ExtraNetDelay_high`; `phys_opt_design -directive AggressiveExplore`.
- Shared common post-phys-opt DCP SHA-256: `D5D4651F6C1DCC886355D9BFF8394DB39A4FA5D3AB7AF4A9569EBCBD503A2462`.
- At route entry, both Vivado logs record identical `PlaceDB=28bd3f86`, `ShapeSum=3a6af66d`, and `RouteDB=93ad4449` checksums.
- CONTROL: `route_design -directive NoTimingRelaxation`.
- TREATMENT: `route_design -directive MoreGlobalIterations`.
- Each route ran in a separate Vivado process and isolated working directory. No seed/strategy sweep was performed.

## Routed QoR

| Metric | CONTROL: NoTimingRelaxation | TREATMENT: MoreGlobalIterations | Change |
|---|---:|---:|---:|
| Clock-group setup WNS | -0.110 ns | -0.151 ns | 41 ps worse |
| Clock-group setup TNS | -35.277 ns | -32.735 ns | 2.542 ns (7.2%) better |
| Clock-group setup failing endpoints | 929 | 810 | 119 (12.8%) fewer |
| Hold WHS | +0.011 ns | +0.003 ns | 8 ps less margin |
| Hold THS / failing endpoints | 0.000 ns / 0 | 0.000 ns / 0 | unchanged |
| Separate `async_default` max group | +0.046 ns / 0 fails | -0.001 ns / -0.004 ns / 4 fails | treatment regressed |
| Routable nets fully routed | 43,639 / 43,639 | 43,638 / 43,638 | both fully routed |
| Routing errors | 0 | 0 | both clean |
| Unconstrained internal endpoints | 0 | 0 | both clean |
| Valid timing exceptions | 0 | 0 | both clean |

The `async_default` row is reported separately from the synchronous clock-group WNS/TNS. It must not be hidden by the positive WHS. The treatment therefore is not a clean all-checks improvement.

The treatment's vectorless post-route power estimate was 1.477 W versus 1.492 W for CONTROL (medium confidence). Since switching activity was not workload-derived and the result is a routing-only comparison, this is informational and not accepted as a power improvement claim. Utilization was identical: 26,376 LUTs, 21,378 FFs, 320 DSPs, and 5,706 LUTRAM cells.

## Critical paths and family movement

- CONTROL WNS path: `src_it_data_end_q_reg/C → u_dut/slot_state_reg[0][0]/CE`, 1.863 ns data delay; 0.402 ns logic and 1.461 ns routing (78.4% routing), 3 LUT levels.
- TREATMENT WNS path: `u_dut/rd_cmd_addr_q_reg[0][0][0]/C → u_dut/lfnst_mem_resp_data_q_reg[3]/D`, 2.066 ns data delay; 0.529 ns logic and 1.537 ns routing (74.4% routing), 6 levels including `RAMD64E`, `MUXF7`, and `MUXF8`.
- Full negative-endpoint census found 929 unique negative endpoints for CONTROL and 814 for TREATMENT; duplicates and unclassified endpoints were zero in each census. CSV TNS reconstruction differs from Vivado summary by 0.022 ns and 0.006 ns respectively due to three-decimal path-property reporting.
- DUT-internal paths remain dominant: CONTROL 897 endpoints / 95.22% of reconstructed negative TNS; TREATMENT 784 / 96.26%. Median internal routing fraction was 77.46% and 80.85%, respectively.
- The largest aggregated endpoint family, `lfnst_grid_reg`, improved from 221 endpoints / -8.282 ns to 171 / -5.525 ns. But TREATMENT exposed a `temp_bank` endpoint family at 156 / -4.836 ns; `kernel_rd_raw_data_q` worsened from -2.634 ns to -3.152 ns, and H-read data endpoints from -3.166 ns to -3.304 ns. This is a mixed redistribution, not global closure.

The raw endpoint and source/endpoint-family census files are retained under `control/census/` and `treatment/census/`; the compact top-family view is `P9_ROUTER_AB_ENDPOINT_FAMILIES.csv`.

## Structural and constraint gates

Both routed DCPs were queried read-only after routing:

- Source boundary: 54/54 source FFs found.
- Sink boundary: 44/44 sink FFs found.
- `kernel_h_rd_pending_q`, `kernel_run_q`, and `kernel_stage_q` through `RAMD64E` to H-response D: **no paths found** in both implementations.
- Registered `kernel_h_rd_addr_q` through `RAMD64E` to H-response D: path exists in both (CONTROL worst queried path -0.109 ns; TREATMENT -0.146 ns).
- `check_timing`: zero unconstrained internal endpoints; one port is reported without input delay under the existing reset contract.
- No valid timing exceptions found.
- DRC: zero routing errors; OOC harness retains expected package-pin `NSTD-1` and `UCIO-1` critical warnings because no package pin/IOSTANDARD contract is supplied. These runs are not package-level FPGA signoff.

## Conclusion and next action

Keep CONTROL as the reference for this fixed-placement router experiment; do not promote TREATMENT as a superior baseline. Do not repeat router-directive or seed searches. The experiment confirms that routing choices trade off endpoint populations: reducing aggregate TNS is insufficient when WNS worsens and the separate async-default group becomes negative.

The next useful engineering step is a narrow RTL/control-cone proposal grounded in the two observed leaders and persistent family census, followed by explicit authorization before modifying RTL. The present evidence alone does not justify claiming 500 MHz closure or authorizing a broad timing rewrite.

```yaml
registered_neighbor_setup: FAIL
registered_neighbor_hold: PASS (clock-group min-delay only)
async_default_max_group: CONTROL_PASS / TREATMENT_FAIL
500_MHz_signoff: NOT_ACHIEVED
package_level_timing: NOT_EVALUATED
official_equivalence: NOT_PROVEN
fresh_synthesis: NOT_RUN
```
