# Step12F P9-R5F - Registered-neighbor setup root-cause census

**Status: CLOSED / ACCEPTED / READ-ONLY.** The fixed R5E routed checkpoint was queried without changing RTL, XDC, synthesis, optimization, placement, routing, or timing exceptions. R6 RTL remains **not authorized**.

## Scope and provenance

- Baseline remote main: 55e88cf401407c23cc5881bf331acafb78c3a533
- Routed DCP: 05_audit/current/59/p9_r5e_registered_neighbor_20260917_defaulttop/step12f_registered_neighbor_postroute.dcp
- DCP SHA-256: D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C
- Top: step12f_registered_neighbor_harness; state: Fully Routed
- Vivado 2025.2, general.maxThreads=4, clock period 2.000 ns
- The old OOC XDC was not loaded; the query script issued only open_checkpoint and read-only timing/netlist queries.

## Canonical census

- Raw negative path objects: **1808**
- Unique negative endpoints: **1808**; duplicates: **0**
- Reconstructed rounded-report TNS: **-74.094 ns**; authoritative R5E TNS: **-74.139 ns**. The **0.045 ns** difference is expected three-decimal Vivado rounding, not a new timing result.
- Buckets: **3**; normalized family groups: **234**; structural signatures: **138**

### Boundary bucket census

| bucket                 | endpoints | TNS (ns) | TNS share | worst viol. | median route frac. |
| ---------------------- | --------- | -------- | --------- | ----------- | ------------------ |
| DUT_INTERNAL           | 1777      | -72.297  | 0.9757    | 0.139       | 0.867              |
| DUT_TO_SINK_BOUNDARY   | 22        | -1.576   | 0.0213    | 0.130       | 0.750              |
| SOURCE_BOUNDARY_TO_DUT | 9         | -0.221   | 0.0030    | 0.058       | 0.698              |

The negative setup tail is overwhelmingly DUT_INTERNAL (1,777/1,808 endpoints; 97.6% of rounded TNS), with 22 DUT-to-sink endpoints and 9 source-to-DUT endpoints. This is a distributed tail, not a single proven dominant cone.

### Top normalized source families

| source family                                      | endpoints | TNS (ns) | worst viol. |
| -------------------------------------------------- | --------- | -------- | ----------- |
| u_dut/u_unified_p4_kernel/ingress_group_q_reg      | 276       | -9.695   | 0.113       |
| u_dut/u_unified_p4_kernel/ingress_data_q_reg       | 201       | -7.990   | 0.133       |
| u_dut/kernel_run_q_reg                             | 125       | -5.253   | 0.128       |
| u_dut/fill_wr_cmd_addr_q_reg                       | 144       | -4.764   | 0.086       |
| u_dut/u_unified_p4_kernel/fifo_rd_ptr_q_reg_rep    | 47        | -3.493   | 0.125       |
| u_dut/kernel_vector_q_reg_rep                      | 40        | -3.243   | 0.135       |
| u_dut/rd_cmd_addr_q_reg                            | 36        | -2.605   | 0.139       |
| u_dut/result_cmd_valid_q_reg                       | 110       | -2.301   | 0.059       |
| u_dut/result_cmd_slot_q_reg                        | 70        | -2.084   | 0.077       |
| u_dut/u_unified_p4_kernel/slot_state_q_reg_replica | 49        | -2.017   | 0.087       |

### Top normalized endpoint families

| endpoint family                                 | endpoints | TNS (ns) | worst viol. |
| ----------------------------------------------- | --------- | -------- | ----------- |
| u_dut/u_unified_p4_kernel/input_mem_reg         | 480       | -17.691  | 0.133       |
| u_dut/input_cache_bank                          | 271       | -9.078   | 0.086       |
| u_dut/lfnst_grid_reg                            | 157       | -5.876   | 0.112       |
| u_dut/u_unified_p4_kernel/ingress_data_q_reg    | 58        | -4.796   | 0.136       |
| u_dut/result_bank                               | 193       | -4.776   | 0.077       |
| u_dut/vwrite_cmd_data_q_reg                     | 48        | -3.779   | 0.133       |
| u_dut/kernel_rd_raw_data_q_reg                  | 48        | -3.199   | 0.137       |
| u_dut/temp_bank                                 | 43        | -2.245   | 0.088       |
| u_dut/u_unified_p4_kernel/product_q_reg_i_psdsp | 54        | -1.964   | 0.103       |
| u_dut/kernel_h_rd_data_q_reg                    | 35        | -1.925   | 0.133       |

### Top source-to-endpoint family pairs

| pair                                                                                       | endpoints | TNS (ns) | worst viol. |
| ------------------------------------------------------------------------------------------ | --------- | -------- | ----------- |
| u_dut/u_unified_p4_kernel/ingress_group_q_reg -> u_dut/u_unified_p4_kernel/input_mem_reg   | 276       | -9.695   | 0.113       |
| u_dut/u_unified_p4_kernel/ingress_data_q_reg -> u_dut/u_unified_p4_kernel/input_mem_reg    | 201       | -7.990   | 0.133       |
| u_dut/fill_wr_cmd_addr_q_reg -> u_dut/input_cache_bank                                     | 144       | -4.764   | 0.086       |
| u_dut/kernel_run_q_reg -> u_dut/lfnst_grid_reg                                             | 93        | -3.720   | 0.112       |
| u_dut/result_cmd_valid_q_reg -> u_dut/result_bank                                          | 110       | -2.301   | 0.059       |
| u_dut/result_cmd_slot_q_reg -> u_dut/result_bank                                           | 70        | -2.084   | 0.077       |
| u_dut/scrub_slot_reg -> u_dut/input_cache_bank                                             | 40        | -1.920   | 0.085       |
| u_dut/rd_cmd_addr_q_reg -> u_dut/kernel_rd_raw_data_q_reg                                  | 26        | -1.901   | 0.137       |
| u_dut/kernel_h_rd_addr_q_reg -> u_dut/kernel_h_rd_data_q_reg                               | 34        | -1.886   | 0.133       |
| u_dut/u_unified_p4_kernel/pipe_out_data_q_reg -> u_dut/u_unified_p4_kernel/fifo_data_q_reg | 41        | -1.327   | 0.089       |
| u_dut/vwrite_cmd_valid_q_reg -> u_dut/temp_bank                                            | 20        | -1.324   | 0.084       |
| u_dut/u_unified_p4_kernel/reduce_l4_q_reg -> u_dut/u_unified_p4_kernel/reduce_l5_q_reg     | 24        | -1.307   | 0.117       |
| u_dut/kernel_vector_q_reg_rep__2 -> u_dut/u_unified_p4_kernel/ingress_data_q_reg           | 12        | -1.089   | 0.132       |
| u_dut/fill_wr_cmd_data_q_reg -> u_dut/input_cache_bank                                     | 39        | -1.002   | 0.074       |
| u_dut/kernel_stage_q_reg -> u_dut/u_unified_p4_kernel/ingress_data_q_reg                   | 11        | -0.949   | 0.123       |

### Structural signatures

The signature list preserves report-derived primitive sequences. It is a topology census, not extra numerical timing precision.

| normalized primitive signature                                     | count | TNS (ns) | worst viol. |
| ------------------------------------------------------------------ | ----- | -------- | ----------- |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>LUT5>LUT5|FDRE                     | 250   | -8.798   | 0.113       |
| FDRE|INBUF>IBUFCTRL>BUFGCE>FDRE|FDRE                               | 201   | -7.990   | 0.133       |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>LUT5|RAMD64E                       | 104   | -3.876   | 0.086       |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>LUT2>LUT5|RAMD64E                  | 108   | -3.712   | 0.084       |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>RAMD64E>LUT6>MUXF7>MUXF8>LUT4|FDCE | 57    | -3.501   | 0.133       |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>RAMD64E>LUT6>MUXF7>MUXF8>LUT3|FDCE | 47    | -3.188   | 0.137       |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>LUT4>LUT5>LUT3>LUT3>LUT6|FDCE      | 51    | -2.301   | 0.112       |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>LUT6>MUXF7>LUT3>LUT6>LUT6|FDRE     | 29    | -2.279   | 0.132       |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>LUT6>LUT3|RAMD64E                  | 48    | -2.088   | 0.085       |
| FDCE|INBUF>IBUFCTRL>BUFGCE>FDCE>LUT3>LUT5|RAMD64E                  | 64    | -2.052   | 0.077       |

The routed DCP did not expose usable CLOCK_REGION properties in this query; the physical-region CSV therefore has one blank/unknown pair containing all 1,808 endpoints. No same-region conclusion is drawn.

## Independent reset audit

report_timing -check_type is unsupported in Vivado 2025.2, so explicit directional queries were used (clock-to-async control for recovery, async control-to-clock for removal), with no blanket waiver:
- Recovery: **9386 paths**, worst slack **0.03 ns**, negative TNS **0.000000000 ns**.
- Removal: **0 paths**, negative TNS **0.000000000 ns**.
- Async-control pins queried: **9506**.

Reset paths remain separate from setup TNS. R5E registered-neighbor hold remains a separate result: WHS +0.010 ns, THS 0, zero failing endpoints; package-level timing is not evaluated.

## Decision

Setup root cause is classified as DISTRIBUTED_MULTI_FAMILY_TIMING_TAIL: the negative endpoints span P4 slot/input control, cache/read-command paths, FIFO controls, wrapper vector controls, LFNST controls, and H-read/kernel controls. The census does not justify a narrow R6 pipeline change or an XDC change. R5 RTL is retained/frozen; P9-R6 remains NOT_AUTHORIZED.

This closes the read-only responsibility/census step without claiming 500 MHz signoff, package-level FPGA signoff, or historical hidden-golden equivalence.
