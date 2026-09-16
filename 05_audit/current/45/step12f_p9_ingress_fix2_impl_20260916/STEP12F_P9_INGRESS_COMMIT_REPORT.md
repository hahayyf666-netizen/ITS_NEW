# Step12F-P9 — P4 ingress accept/commit isolation

## Result

P9 is functionally passing and the intended structural timing target was removed from the routed worst-100 population. The fresh unified-wrapper implementation is fully routed, but 500 MHz setup and hold are still failing; therefore the phase remains STOP and no tag is created.

## What changed

- Added a one-entry elastic ingress in `unified_p4_kernel`.
- Kept `input_group_fire` as the same-edge wrapper-facing transaction event.
- Captured payload and slot/group/last metadata at accept, then wrote `input_mem` only at the following commit event.
- Made `input_vector_done`, `SLOT_READY`, and ready-FIFO enqueue commit-qualified.
- Added a horizontal read handoff guard so the extra final-input commit cycle cannot prefetch and lose the next row response.
- Kept arithmetic, coefficient storage, LFNST arithmetic, Oracle/profile, XDC, R4C, and `v3.5-18` unchanged.

## Functional evidence

ModelSim normal and `SYNTHESIS` runs pass: 156 Gate-B numeric cases, 13 vector-II modes, 369 Gate-C tuples / 45,636 beats per mode, 1,088 LFNST engine cases, 258 LFNST wrapper cases, P3/P4 contracts, N=4 continuous-vector coverage, ownership/order/backpressure checks.

Evidence: `05_audit/current/43/step12f_p9_ingress_fix2_20260916/STEP12F_COVERAGE_MODELSIM_RUN.json`.

## Physical evidence

Fresh synthesis completed on Vivado 2025.2, `xcku5p-ffvb676-2-e`, 2.000 ns clock:

| Stage | WNS | TNS | Failing endpoints | WHS | THS |
|---|---:|---:|---:|---:|---:|
| Post-synthesis | -0.547 ns | -525.240 ns | 4,033 | -0.076 ns | -3.358 ns |
| Post-route | -0.720 ns | -5,894.764 ns | 30,908 | -0.080 ns | -3.420 ns |

Route status is `Fully Routed` with 0 unrouted and 0 partially routed nets. `check_timing` reports 0 unconstrained internal endpoints, and `report_exceptions` reports no valid timing exceptions.

The former wrapper live-select → `input_mem` family is absent from the post-synthesis/post-route worst-100 reports. This confirms the P9 target was effective as a structural cut, but it does not imply global timing closure.

The new routed leader is the shared input-cache distributed-RAM read → LFNST response family:

`compute_slot_q_reg_replica_2/C → lfnst_mem_resp_data_q_reg[0]/D`, WNS `-0.720 ns`, data delay `2.700 ns` (logic `0.767 ns`, routing `1.933 ns`, 8 levels).

## Decision

`P9 functional = PASS`; `P9 target = EFFECTIVE_STRUCTURALLY`; `fresh synthesis = PASS_COMPLETED_BUT_TIMING_FAIL`; `implementation = FULLY_ROUTED_BUT_TIMING_FAIL`; `500 MHz = STOP`; `v3.5-18 = unchanged`; no new tag.

The next RTL decision must use this new routed worst-family evidence. P9 does not authorize an automatic cache or LFNST modification.
