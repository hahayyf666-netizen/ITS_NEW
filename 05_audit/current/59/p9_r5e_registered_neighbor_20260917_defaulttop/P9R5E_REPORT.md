# Step12F P9-R5E — Registered-Neighbor Integration Qualification

## Verdict

`P9-R5E` is an accepted registered-neighbor physical qualification with a split result:

- normal-top synthesis: **PASS**;
- boundary anti-pruning: **PASS** (`54/54` source FF bits and `44/44` sink FF bits);
- implementation: **Fully Routed** with zero routing errors;
- hold at 2.000 ns: **PASS** (`WHS=+0.010 ns`, `THS=0`, `0` failing endpoints);
- setup at 2.000 ns: **STOP** (`WNS=-0.139 ns`, `TNS=-74.139 ns`, `1,808` failing endpoints);
- package-level FPGA timing: **not evaluated**.

This is not a 500 MHz signoff. The evidence supports only core timing in the explicit registered-neighbor integration context.

## What was run

The frozen R5 DUT was placed inside `step12f_registered_neighbor_harness`. All logical data/protocol inputs are driven by live internal source registers and all DUT outputs are captured by live internal sink registers. The harness has explicit `IBUF + BUFG` clocking, async-assert/sync-deassert reset conditioning, and no package pin/timing assumptions for the data ports.

The authoritative run used Vivado 2025.2 on `xcku5p-ffvb676-2-e`, four threads, a 2.000 ns clock, and nominal explicit setup/hold uncertainty of 0.000 ns:

```text
synth_design -top step12f_registered_neighbor_harness -part xcku5p-ffvb676-2-e -flatten_hierarchy none -directive Default
opt_design -directive Default
place_design -directive ExtraNetDelay_high
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation
```

The old Step12F OOC XDC was not loaded. The harness XDC has no data input/output delays, no false paths, and no multicycle paths. The only `check_timing` no-input-delay item is `rst_n`, intentionally handled as a reset/control input; unconstrained internal endpoints are zero and `report_exceptions` finds no valid timing exceptions.

## Directional timing evidence

The same routed DCP was audited in `postroute_audit4`:

| path class | representative slack | data delay | logic / route | representative endpoints |
|---|---:|---:|---:|---|
| source FF → DUT | +0.070 ns | 1.729 ns | 0.435 / 1.294 ns | `src_it_data_out_req_q_reg/C` → `u_dut/output_index_reg[3]_replica_4/D` |
| DUT internal | -0.139 ns | 2.080 ns | 0.520 / 1.560 ns | `u_dut/rd_cmd_addr_q_reg[1][0][2]/C` → `u_dut/lfnst_mem_resp_data_q_reg[7]/D` |
| DUT → sink FF | -0.130 ns | 1.927 ns | 0.433 / 1.494 ns | `u_dut/output_index_reg[1]_replica_4/C` → `sink_it_data_out_q_reg[25]/D` |

The remaining setup failure is therefore not an input-port hold artifact; it includes distributed internal and DUT-to-sink setup tails. No new RTL conclusion is authorized by this run.

## R5 structural gate

The read-only audit located `5,632` `RAMD64E` cells and `33,792` address pins in the routed DCP. Through-RAM queries show:

```text
pending → RAMD64E → H response       NO_PATH
run     → RAMD64E → H response       NO_PATH
stage   → RAMD64E → H response       NO_PATH
registered H address → RAMD64E → H response   PATH_EXISTS
```

The registered-address representative path is `-0.133 ns`, `2.017 ns` data delay, with `LUT4=1 LUT6=1 MUXF7=1 MUXF8=1 RAMD64E=1`. The direct pending query is intentionally not used as the structural gate because local response ownership logic is allowed; the through-RAM query is the authority.

## Resource and implementation notes

Post-route utilization is `320 DSP48E2`, `28,133` CLB LUTs (`5,632` distributed-RAM LUTs), `25,494` CLB registers, `1,487` CARRY8, `1,743` F7 muxes, `592` F8 muxes, zero block-RAM tiles and zero URAM. Estimated total on-chip power is `1.515 W` (`1.056 W` dynamic, `0.459 W` static).

Route status is fully routed (`324,052` logical nets; `48,232/48,232` routable nets fully routed; zero routing errors). DRC has no errors, but reports two expected top-pin critical warnings (`NSTD-1`, `UCIO-1`) because this is not a package-level top; DSP pipelining warnings are retained as diagnostics and are not silently waived.

## Attempt history and boundary

An earlier OOC attempt passed synthesis and anti-pruning but crashed during `ExtraNetDelay_high` place (access-violation exit `-1073741819`). The authoritative run corrected the implementation context by using the enclosing normal top with explicit clock I/O cells; this was a harness/methodology correction and did not alter the frozen DUT. A separate Explore-based recovery was diagnostic only.

The result is recorded as:

```yaml
P9-R5E: ACCEPTED_REGISTERED_NEIGHBOR_SETUP_STOP
registered-neighbor hold: PASS
registered-neighbor setup: FAIL
500 MHz core signoff: NOT ACHIEVED
package-level FPGA signoff: NOT EVALUATED
R5 DUT: RETAINED / FROZEN
R6 RTL: NOT AUTHORIZED
new tag: NO
```

The complete machine-readable record is in `P9R5E_MANIFEST.json`; raw DCPs and reports remain in the local evidence directory named there. A second independent run was not required because the first run did not meet setup signoff.

