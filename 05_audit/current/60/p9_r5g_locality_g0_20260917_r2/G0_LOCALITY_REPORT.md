# Step12F-P9-R5G G0 — Physical Locality Qualification

Status: `CLOSED_READ_ONLY`; no RTL/XDC/implementation command was executed.

- Fixed routed DCP SHA-256: `D18A6213468C4EE270D03AF924BE53BE7298DD71A70C5B2651ED0DDB8767552C`
- Vivado 2025.2, xcku5p-ffvb676-2-e, maxThreads=4
- G0 decision: **A_OR_B_CANDIDATE_REQUIRES_GEOMETRY_SELECTION**

## Complete-cell inventory

| Family | Cells | Sites | Tiles | Tile bbox | Clock regions |
|---|---:|---:|---:|---|---|
| `fill_wr_cmd_addr_q_reg` | 10 | 8 | 8 | `{'x_min': 222, 'x_max': 246, 'y_min': 104, 'y_max': 119, 'coordinate_count': 10}` | `{'X2Y2': 10}` |
| `ingress_data_q_reg` | 64 | 35 | 35 | `{'x_min': 234, 'x_max': 255, 'y_min': 95, 'y_max': 114, 'coordinate_count': 64}` | `{'X2Y2': 64}` |
| `ingress_group_q_reg` | 5 | 5 | 5 | `{'x_min': 251, 'x_max': 255, 'y_min': 123, 'y_max': 134, 'coordinate_count': 5}` | `{'X2Y1': 3, 'X2Y2': 2}` |
| `input_cache_bank` | 104 | 47 | 47 | `{'x_min': 241, 'x_max': 297, 'y_min': 81, 'y_max': 113, 'coordinate_count': 104}` | `{'X2Y2': 104}` |
| `input_mem_reg` | 4032 | 974 | 974 | `{'x_min': 186, 'x_max': 329, 'y_min': 120, 'y_max': 174, 'coordinate_count': 4032}` | `{'X1Y1': 461, 'X1Y2': 50, 'X2Y1': 2256, 'X2Y2': 23, 'X3Y1': 1242}` |
| `kernel_h_rd_addr_q_reg` | 50 | 24 | 24 | `{'x_min': 222, 'x_max': 264, 'y_min': 105, 'y_max': 137, 'coordinate_count': 50}` | `{'X2Y1': 45, 'X2Y2': 5}` |
| `kernel_h_rd_data_q_reg` | 64 | 22 | 22 | `{'x_min': 232, 'x_max': 251, 'y_min': 115, 'y_max': 122, 'coordinate_count': 64}` | `{'X2Y2': 64}` |
| `kernel_rd_raw_data_q_reg` | 64 | 53 | 53 | `{'x_min': 262, 'x_max': 293, 'y_min': 100, 'y_max': 128, 'coordinate_count': 64}` | `{'X2Y1': 3, 'X2Y2': 61}` |
| `kernel_run_q_reg` | 1 | 1 | 1 | `{'x_min': 244, 'x_max': 244, 'y_min': 92, 'y_max': 92, 'coordinate_count': 1}` | `{'X2Y2': 1}` |
| `lfnst_grid_reg` | 1024 | 313 | 313 | `{'x_min': 198, 'x_max': 244, 'y_min': 70, 'y_max': 99, 'coordinate_count': 1024}` | `{'X1Y2': 188, 'X2Y2': 836}` |
| `rd_cmd_addr_q_reg` | 174 | 87 | 87 | `{'x_min': 244, 'x_max': 297, 'y_min': 94, 'y_max': 128, 'coordinate_count': 174}` | `{'X2Y1': 2, 'X2Y2': 172}` |
| `result_bank` | 110 | 53 | 53 | `{'x_min': 207, 'x_max': 251, 'y_min': 68, 'y_max': 158, 'coordinate_count': 110}` | `{'X1Y2': 1, 'X2Y1': 3, 'X2Y2': 106}` |
| `result_cmd_slot_q_reg` | 1 | 1 | 1 | `{'x_min': 231, 'x_max': 231, 'y_min': 99, 'y_max': 99, 'coordinate_count': 1}` | `{'X2Y2': 1}` |
| `result_cmd_valid_q_reg` | 1 | 1 | 1 | `{'x_min': 231, 'x_max': 231, 'y_min': 100, 'y_max': 100, 'coordinate_count': 1}` | `{'X2Y2': 1}` |
| `vwrite_cmd_data_q_reg` | 64 | 35 | 35 | `{'x_min': 243, 'x_max': 255, 'y_min': 65, 'y_max': 76, 'coordinate_count': 64}` | `{'X2Y2': 64}` |

## Failing-versus-passing path population

Distances are tile-grid Manhattan proxies; they are not timing guarantees. Clock-region labels are reported as physical context only.

| Source family | Population | Paths | Negative TNS | Median distance | P90 distance | End clock regions |
|---|---|---:|---:|---:|---:|---|
| `ingress_data_q_reg` | failing | 201 | -7.990 | 103.0 | 122.0 | `{'X1Y1': 3, 'X2Y1': 92, 'X3Y1': 106}` |
| `ingress_data_q_reg` | passing/zero | 3831 | 0.000 | 85.0 | 115.0 | `{'X1Y1': 458, 'X1Y2': 50, 'X2Y1': 2164, 'X2Y2': 23, 'X3Y1': 1136}` |
| `ingress_group_q_reg` | failing | 276 | -9.695 | 97.0 | 109.0 | `{'X1Y1': 10, 'X2Y1': 98, 'X3Y1': 168}` |
| `ingress_group_q_reg` | passing/zero | 3756 | 0.000 | 66.0 | 93.0 | `{'X1Y1': 451, 'X1Y2': 50, 'X2Y1': 2158, 'X2Y2': 23, 'X3Y1': 1074}` |

## Decision

Failing ingress->input_mem paths are materially farther in tile coordinates than passing paths for both control and data source families.

G0 obtained CLOCK_REGION labels from the placed cell/site inventory. `input_mem_reg` spans multiple regions while ingress producers are concentrated more narrowly; this supports a locality hypothesis but is not itself a timing proof.

This read-only result does not choose pblock coordinates. If G1 is run, it must use one common postsynth DCP and matched CONTROL/TREATMENT flows with exactly one locality constraint in TREATMENT.
