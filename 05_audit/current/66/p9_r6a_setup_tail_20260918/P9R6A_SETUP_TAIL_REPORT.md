# P9-R6A — R6 setup-tail classification

> Read-only census of the exact R6 registered-neighbor routed DCP. No RTL, XDC, synthesis, optimization, placement, phys_opt, routing, or checkpoint-writing command was used.

## Verdict

- **Status:** `CLOSED_READ_ONLY`; R6 remains retained/frozen and 500 MHz signoff is not achieved.
- **Routed DCP:** `6FCD3084E9166C0A114503D0C1A1062F9E9DAFCF79C549CD27C744C2B09F92FC` (expected hash matched).
- **Census:** `312` raw negative path objects, `312` unique endpoints, `0` duplicates, `0` unclassified.
- **Setup reconciliation:** WNS `-0.045 ns` (authority `-0.045 ns`), endpoint-sum TNS `-4.893 ns` vs summary authority `-4.882 ns`; delta `-0.011 ns` is rounded-property reconciliation, not a new run.
- **Root-cause classification:** `DISTRIBUTED_MULTI_FAMILY_ROUTING_TAIL`; top-1 absolute TNS share `18.7%`, top-5 share `41.7%`.

## Boundary buckets

| bucket | endpoints | reconstructed TNS (ns) | worst slack (ns) | median route fraction |
|---|---:|---:|---:|---:|
| DUT_INTERNAL | 303 | -4.835 | -0.045 | 0.741 |
| DUT_TO_SINK_BOUNDARY | 7 | -0.056 | -0.018 | 0.765 |
| SOURCE_BOUNDARY_TO_DUT | 2 | -0.002 | -0.001 | 0.664 |

## Mandatory focus families

| focus | endpoints | reconstructed TNS (ns) | worst slack (ns) | median route fraction |
|---|---:|---:|---:|---:|
| slot_state_to_lfnst_grid | 45 | -0.914 | -0.045 | 0.743295 |
| kernel_cut_h_to_any | 2 | -0.046 | -0.041 | 0.701485 |
| rd_cmd_addr_to_any | 28 | -0.505 | -0.04 | 0.743063 |
| historical_fill_command_to_input_cache | 0 | 0.000 | NA | NA |

## R6A top family population

| source family | endpoint family | endpoints | TNS (ns) | worst slack (ns) |
|---|---|---:|---:|---:|
| `u_dut/slot_state_reg` | `u_dut/lfnst_grid_reg` | 45 | -0.914 | -0.045 |
| `u_dut/u_unified_p4_kernel/slot_state_q_reg` | `u_dut/kernel_h_rd_data_q_reg` | 22 | -0.415 | -0.040 |
| `u_dut/u_unified_p4_kernel/slot_state_q_reg` | `u_dut/kernel_rd_raw_data_q_reg` | 15 | -0.259 | -0.031 |
| `u_dut/rd_cmd_addr_q_reg` | `u_dut/lfnst_mem_resp_data_q_reg` | 10 | -0.226 | -0.037 |
| `u_dut/rd_cmd_addr_q_reg` | `u_dut/kernel_rd_raw_data_q_reg` | 16 | -0.225 | -0.040 |
| `u_dut/u_unified_p4_kernel/fifo_rd_ptr_q_reg` | `u_dut/vwrite_cmd_data_q_reg` | 11 | -0.222 | -0.037 |
| `u_dut/lfnst_run_q_reg` | `u_dut/lfnst_grid_reg` | 9 | -0.179 | -0.024 |
| `u_dut/u_unified_p4_kernel/slot_state_q_reg` | `u_dut/kernel_h_rd_data_tail_q_reg` | 10 | -0.159 | -0.030 |
| `u_dut/u_unified_p4_kernel/issue_desc_active_size_q_reg` | `u_dut/u_unified_p4_kernel/s0_input_q_reg` | 11 | -0.138 | -0.025 |
| `u_dut/kernel_vector_q_reg_0` | `u_dut/u_unified_p4_kernel/ingress_data_q_reg` | 7 | -0.135 | -0.030 |
| `u_dut/lfnst_ntrs48_q_reg_3` | `u_dut/lfnst_grid_reg` | 7 | -0.131 | -0.031 |
| `u_dut/u_unified_p4_kernel/ingress_data_q_reg` | `u_dut/u_unified_p4_kernel/input_mem_reg` | 19 | -0.131 | -0.014 |
| `u_dut/u_unified_p4_kernel/slot_state_q_reg` | `u_dut/lfnst_tail_index_q_reg` | 4 | -0.126 | -0.032 |
| `u_dut/kernel_vector_q_reg` | `u_dut/kernel_rd_req_group_q_reg` | 5 | -0.119 | -0.039 |
| `u_dut/kernel_run_q_reg` | `u_dut/lfnst_grid_reg` | 12 | -0.112 | -0.024 |

## R5F → R6A comparison

R5F had `1808` negative endpoints (reconstructed TNS `-74.094 ns`); R6A has `312` (reconstructed TNS `-4.893 ns`). The comparison is canonical family-level evidence across different netlists/placements, not same-cell causality.

The former fill-command source family is absent from the R6A rows; the residual population is led by slot-state/LFNST-grid, P4 H-read, rd-command, FIFO/write, and ingress/control families. See `r5f_r6a_family_delta.csv` for all normalized families.

## Decision

`Do not authorize R7 from this census; use a bounded physical-convergence experiment or revisit only the highest-value family with a concrete intervention.`

R7 RTL remains **not authorized**. The census decides whether a later proposal is justified; it does not itself prove that any one RTL cone is causal or that 500 MHz is closed.

## Evidence boundary

Primitive-sequence extraction was disabled for this full 312-path pass after Vivado 2025.2 terminated on the all-path `report_timing -of_objects` loop. Cell references, endpoint/source families, logic levels, logic delay, routing delay, locations, and the exact routed DCP remain recorded; the skipped primitive field is explicitly non-authoritative.

Artifacts: `negative_endpoint_family_census.csv`, `coarse_primitive_signature_summary.csv`, `r6a_focus_summary.csv`, `r5f_r6a_family_delta.csv`, and `P9R6A_SETUP_TAIL_STATUS.json`.
